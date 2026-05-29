import Foundation
import SwiftUI
import Combine

// ========== BLOCK 01: HUGGING FACE DTOs - START ==========

/// HuggingFace `/api/models` list entry. Subset of fields Posey needs.
struct HFModelListResponse: Codable, Sendable {
    let id: String
    let modelId: String?
    let author: String?
    let downloads: Int?
    let likes: Int?
    let tags: [String]?
    let siblings: [HFFileInfo]?
    let cardData: HFCardData?

    var repoID: String { modelId ?? id }
}

struct HFFileInfo: Codable, Sendable {
    let rfilename: String
    let size: Int64?
}

struct HFCardData: Codable, Sendable {
    let license: String?
    let tags: [String]?
}

/// `config.json` context-window fields, checked in order of prevalence.
/// Different architectures store the window under different keys.
struct HFModelConfig: Codable, Sendable {
    let max_position_embeddings: Int?
    let n_positions: Int?
    let seq_len: Int?
    let seq_length: Int?
    let n_ctx: Int?
    let sliding_window: Int?
}

// ========== BLOCK 01: HUGGING FACE DTOs - END ==========

// ========== BLOCK 02: MODEL CATALOG SERVICE - START ==========

/// The UI-facing catalog singleton. Ported faithfully from Hal Universal's
/// `ModelCatalogService` (per Mark's "one codebase" directive,
/// 2026-05-28). Holds the `@Published availableModels` array, fetches the
/// HuggingFace `mlx-community` org catalog, runs three-tier context-window
/// detection, manages license acceptance, and reconciles download state.
///
/// **Approved-only UI, full machinery underneath.** `availableModels` is
/// seeded with `ModelConfiguration.allApproved` (AFM + curated) so the
/// picker has content from launch. `fetchMLXCommunityModels()` pulls the
/// full ~1000-model community catalog into `availableModels` — that
/// machinery is present so that adding a model is a UI-visibility change,
/// not an architectural one. The reader-facing picker renders only
/// approved models (see `approvedModels`); the community tier is fetched
/// but not shown unless Mark approves a model.
///
/// **Why a three-tier context detector for a curated catalog?** Every
/// approved model's context window is hardcoded (and config.json-verified)
/// in the seed, so detection isn't strictly needed for the approved set.
/// It's ported because it's load-bearing the moment any community model is
/// approved — at that point its window is unknown and the detector fills
/// it. Keeping it now means promotion is a one-line change.
///
/// 2026-05-28 — introduced as part of the faithful Hal model-management
/// port (task #1).
@MainActor
final class ModelCatalogService: ObservableObject {
    static let shared = ModelCatalogService()

    /// Seeded with the approved set so the picker shows content from
    /// launch, before (or without) an HF fetch. `init()` reconciles
    /// download state against disk so already-downloaded models report
    /// correctly on first read.
    @Published var availableModels: [ModelConfiguration] = ModelConfiguration.allApproved
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // HF API configuration
    private let huggingFaceAPIBase = "https://huggingface.co/api"
    private let mlxCommunityOrg = "mlx-community"

    // License acceptance tracking (survives app deletion via @AppStorage).
    @AppStorage("askPosey.acceptedModelLicenses") private var acceptedLicensesData: Data = Data()
    private var acceptedLicenses: [String: Bool] {
        get { (try? JSONDecoder().decode([String: Bool].self, from: acceptedLicensesData)) ?? [:] }
        set { acceptedLicensesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    // Context-window cache: [modelID: contextWindow]. Survives app deletion.
    @AppStorage("askPosey.cachedContextWindows") private var cachedContextData: Data = Data()
    private var cachedContextWindows: [String: Int] {
        get { (try? JSONDecoder().decode([String: Int].self, from: cachedContextData)) ?? [:] }
        set { cachedContextData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    private init() {
        // Reconcile the seed against disk before anyone reads
        // availableModels — without this, a downloaded model reports
        // isDownloaded:false until the user opens the picker.
        refreshDownloadStates()
        dbgLog("POSEY-CATALOG: initialized with %d approved models; refreshed download states.", availableModels.count)
    }

    // MARK: - Approved set (the only models shown in the UI)

    /// IDs Mark has approved for the reader-facing picker.
    private static var approvedIDs: Set<String> {
        Set(ModelConfiguration.allApproved.map(\.id))
    }

    /// The models the picker renders, in approved order, with live
    /// download state. Community models in `availableModels` are excluded.
    var approvedModels: [ModelConfiguration] {
        // Preserve the curated display order; pull live (download-state-
        // reconciled) instances out of availableModels where present.
        ModelConfiguration.allApproved.map { seed in
            availableModels.first(where: { $0.id == seed.id }) ?? seed
        }
    }

    // MARK: - HuggingFace catalog fetch (community machinery)

    /// Fetch all models from the mlx-community org into `availableModels`.
    /// Approved models keep their rich seed metadata; community models are
    /// added with HF-derived metadata. The reader-facing UI shows only
    /// `approvedModels`, but the full set is available for diagnostics and
    /// for the moment Mark approves a community model.
    func fetchMLXCommunityModels() async {
        isLoading = true
        errorMessage = nil
        dbgLog("POSEY-CATALOG: fetching mlx-community catalog…")

        do {
            guard let url = URL(string: "\(huggingFaceAPIBase)/models?author=\(mlxCommunityOrg)") else {
                throw CatalogError.invalidURL
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
            guard http.statusCode == 200 else { throw CatalogError.httpError(http.statusCode) }

            let hfModels = try JSONDecoder().decode([HFModelListResponse].self, from: data)
            dbgLog("POSEY-CATALOG: received %d models from HF", hfModels.count)

            var community: [ModelConfiguration] = []
            for hf in hfModels {
                // Approved models keep their seed; don't overwrite rich
                // metadata with the thin HF-derived version.
                if Self.approvedIDs.contains(hf.repoID) { continue }
                if let model = await convertHFModelToConfiguration(hf) {
                    community.append(model)
                }
            }

            // Approved seeds (with live download state) first, then community.
            self.availableModels = ModelConfiguration.allApproved + community
            self.refreshDownloadStates()
            self.isLoading = false
            dbgLog("POSEY-CATALOG: catalog updated — %d approved + %d community", ModelConfiguration.allApproved.count, community.count)
        } catch {
            self.errorMessage = "Failed to load models: \(error.localizedDescription)"
            self.isLoading = false
            // Keep the approved set visible offline / on failure.
            self.availableModels = ModelConfiguration.allApproved
            self.refreshDownloadStates()
            dbgLog("POSEY-CATALOG: fetch error — %@", error.localizedDescription)
        }
    }

    private func convertHFModelToConfiguration(_ hf: HFModelListResponse) async -> ModelConfiguration? {
        let repoID = hf.repoID
        let displayName = repoID
            .replacingOccurrences(of: "mlx-community/", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized

        let totalBytes = hf.siblings?.reduce(Int64(0)) { $0 + ($1.size ?? 0) } ?? 0
        let sizeGB = totalBytes > 0 ? Double(totalBytes) / 1_073_741_824.0 : nil

        // Three-tier context-window detection (cache → config.json → name → 4K).
        let contextWindow: Int
        if let cached = cachedContextWindows[repoID] {
            contextWindow = cached
        } else {
            if let fetched = await fetchConfigContextWindow(for: repoID) {
                contextWindow = fetched
            } else {
                contextWindow = inferContextFromName(repoID)
            }
            cacheContextWindow(contextWindow, for: repoID)
        }

        let downloader = MLXModelDownloader.shared
        return ModelConfiguration(
            id: repoID,
            displayName: displayName,
            source: .mlx,
            sizeGB: sizeGB,
            contextWindow: contextWindow,
            license: hf.cardData?.license,
            description: nil,
            isDownloaded: downloader.isModelDownloaded(repoID),
            localPath: downloader.getModelPath(repoID)
        )
    }

    // MARK: - Context-window detection

    private func cacheContextWindow(_ window: Int, for modelID: String) {
        var cache = cachedContextWindows
        cache[modelID] = window
        cachedContextWindows = cache
    }

    /// TIER 1: fetch from the model's config.json (most accurate).
    /// Returns nil on any failure so the caller falls back to Tier 2.
    private func fetchConfigContextWindow(for repoID: String) async -> Int? {
        guard let url = URL(string: "https://huggingface.co/\(repoID)/raw/main/config.json") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let config = try JSONDecoder().decode(HFModelConfig.self, from: data)
            return config.max_position_embeddings
                ?? config.sliding_window
                ?? config.n_positions
                ?? config.n_ctx
                ?? config.seq_len
                ?? config.seq_length
        } catch {
            return nil
        }
    }

    /// TIER 2: infer from name patterns. TIER 3: 4_096 safe default.
    private func inferContextFromName(_ repoID: String) -> Int {
        let id = repoID.lowercased()
        if id.contains("128k") { return 128_000 }
        if id.contains("32k")  { return 32_000 }
        if id.contains("8k")   { return 8_000 }
        return 4_096
    }

    // MARK: - License management

    func acceptLicense(for modelID: String) {
        var licenses = acceptedLicenses
        licenses[modelID] = true
        acceptedLicenses = licenses
        dbgLog("POSEY-CATALOG: license accepted for %@", modelID)
    }

    func hasAcceptedLicense(for modelID: String) -> Bool {
        acceptedLicenses[modelID] ?? false
    }

    func revokeLicense(for modelID: String) {
        var licenses = acceptedLicenses
        licenses[modelID] = nil
        acceptedLicenses = licenses
        dbgLog("POSEY-CATALOG: license revoked for %@", modelID)
    }

    /// Fetch the full model-card README for license display.
    func fetchLicenseText(for modelID: String) async throws -> String {
        guard let url = URL(string: "https://huggingface.co/\(modelID)/raw/main/README.md") else {
            throw CatalogError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CatalogError.licenseNotFound
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CatalogError.invalidLicenseFormat
        }
        return text
    }

    // MARK: - Lookup + download-state reconciliation

    /// Models usable right now: AFM + downloaded MLX. Approved order.
    var downloadedModels: [ModelConfiguration] {
        approvedModels.filter { $0.source == .appleFoundation || ($0.source == .mlx && $0.isDownloaded) }
    }

    func getModel(byID modelID: String) -> ModelConfiguration? {
        availableModels.first(where: { $0.id == modelID })
    }

    /// Register a minimal config if its id isn't already present (used when
    /// a selection references a model whose HF metadata hasn't been fetched).
    func addModelIfAbsent(_ model: ModelConfiguration) {
        if !availableModels.contains(where: { $0.id == model.id }) {
            availableModels.append(model)
            dbgLog("POSEY-CATALOG: registered fallback model %@", model.id)
        }
    }

    /// Reconcile every MLX model's `isDownloaded` / `localPath` against
    /// disk via `MLXModelDownloader`. AFM keeps its system-managed
    /// `isDownloaded: true`.
    func refreshDownloadStates() {
        let downloader = MLXModelDownloader.shared
        availableModels = availableModels.map { model in
            guard model.source == .mlx else { return model }
            var updated = model
            updated.isDownloaded = downloader.isModelDownloaded(model.id)
            updated.localPath = downloader.getModelPath(model.id)
            return updated
        }
    }
}

// ========== BLOCK 02: MODEL CATALOG SERVICE - END ==========

// ========== BLOCK 03: CATALOG ERROR - START ==========

enum CatalogError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case licenseNotFound
    case invalidLicenseFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Invalid Hugging Face API URL"
        case .invalidResponse:      return "Invalid response from Hugging Face"
        case .httpError(let code):  return "HTTP error \(code) from Hugging Face API"
        case .licenseNotFound:      return "Model license not found"
        case .invalidLicenseFormat: return "License text could not be decoded"
        }
    }
}

// ========== BLOCK 03: CATALOG ERROR - END ==========
