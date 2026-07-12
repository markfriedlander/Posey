import SwiftUI

// ========== BLOCK 01: ASK POSEY MODEL LIBRARY VIEW - START ==========

/// The Ask Posey **Model Library** — its own pushed screen, reached from a
/// `NavigationLink` in the Reader-preferences "Ask Posey" section. This is
/// Hal Universal's structure: settings link to a dedicated Model Library
/// screen rather than embedding the catalog inline.
///
/// Hosting the catalog on its own pushed screen (instead of nested inside
/// the Reader-preferences `.sheet`) is also the structural fix for the
/// gated-download flow: the one-time hardware-disclosure sheet and the
/// license-acceptance sheet now present over a navigation stack rather
/// than from within an already-presented sheet, so they no longer dismiss
/// the outer sheet (the limitation documented in commit `9e51ecd`).
///
/// Two sections, top to bottom:
///   1. **Language Model** — the approved-model accordion catalog
///      (`AskPoseyModelRow`): voice tag → description → performance grid →
///      reading scorecard → license, with a single status-dot language, an
///      explicit gated Download button, and Select/Delete.
///   2. **Embedding Model** — the embedding-backend picker + migration
///      progress.
///
/// (The former "Search breadth" retrieval-strictness picker was removed
/// 2026-06-17 — it was a placebo the retrieval gate never read. Per-document
/// retrieval tuning will return as a doc-type-driven default; see NEXT.md.)
///
/// Only the approved set (`ModelCatalog.all`) is surfaced; the HuggingFace
/// community catalog machinery in `ModelCatalogService` exists but is not
/// shown — adding a model is a UI change, not an architectural one.
///
/// 2026-05-29 — extracted from `AskPoseyPreferencesSection` as part of the
/// preferences reorganization (Sound / Reading / Ask Posey).
struct AskPoseyModelLibraryView: View {

    @ObservedObject var migrationCoordinator: EmbedderMigrationCoordinator
    let databaseManager: DatabaseManager?

    @AppStorage(EmbeddingBackend.defaultsKey)
    private var selectedBackendRaw: String = EmbeddingBackend.nlContextual.rawValue

    @AppStorage(ModelCatalog.defaultsKey)
    private var selectedModelID: String = ModelCatalog.appleFoundation.id

    @ObservedObject private var mlxDownloader = MLXModelDownloader.shared

    /// One-time hardware-disclosure gate (Hal's `hasSeenHardwareDisclosure`).
    @AppStorage("askPosey.hasSeenHardwareDisclosure")
    private var hasSeenHardwareDisclosure: Bool = false

    @State private var modelPendingDelete: ModelConfiguration?
    @State private var modelForLicense: ModelConfiguration?
    @State private var showingHardwareDisclosure = false
    @State private var pendingModelAfterDisclosure: ModelConfiguration?

    /// Single-open accordion: the id of the model whose detail card is
    /// expanded (nil = all collapsed). Driven by user taps and by the
    /// `remoteExpandAskPoseyModel` antenna notification.
    @State private var expandedModelID: String?

    /// Single-open accordion for the Embedding Model section (the backend
    /// rawValue whose card is expanded, nil = all collapsed).
    @State private var expandedEmbedderRaw: String?

    /// The embedder pending a delete confirmation (nil = no dialog).
    @State private var backendPendingDelete: EmbeddingBackend?

    var body: some View {
        Form {
            llmSection
            embedderSection
        }
        .navigationTitle("Model Library")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Reconcile download state against disk so downloaded models
            // report correctly the moment the screen opens (Hal parity).
            ModelCatalogService.shared.refreshDownloadStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteExpandAskPoseyModel)) { note in
            if let id = note.userInfo?["modelID"] as? String {
                withAnimation(.easeInOut(duration: 0.18)) { expandedModelID = id }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteExpandAskPoseyEmbedder)) { note in
            if let raw = note.userInfo?["backend"] as? String {
                withAnimation(.easeInOut(duration: 0.18)) { expandedEmbedderRaw = raw }
            }
        }
        .sheet(item: $modelForLicense) { model in
            AskPoseyModelLicenseSheet(
                model: model,
                onAccept: {
                    ModelCatalogService.shared.acceptLicense(for: model.id)
                    modelForLicense = nil
                    Task {
                        await mlxDownloader.startDownload(
                            modelID: model.id, repoID: model.id, sizeGB: model.sizeGB
                        )
                    }
                },
                onCancel: { modelForLicense = nil }
            )
        }
        .sheet(isPresented: $showingHardwareDisclosure) {
            AskPoseyHardwareDisclosureSheet(
                onContinue: { resumeAfterDisclosure() },
                onCancel: {
                    pendingModelAfterDisclosure = nil
                    showingHardwareDisclosure = false
                }
            )
        }
        .alert(
            "Delete \(modelPendingDelete?.displayName ?? "model")?",
            isPresented: Binding(
                get: { modelPendingDelete != nil },
                set: { if !$0 { modelPendingDelete = nil } }
            ),
            presenting: modelPendingDelete
        ) { model in
            Button("Delete", role: .destructive) { deleteModel(model) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            let size = model.sizeGB.map { String(format: "%.1f GB", $0) } ?? "space"
            Text("Deleting frees ~\(size). You can re-download it later.")
        }
        .alert(
            "Delete \(backendPendingDelete?.displayName ?? "embedder")?",
            isPresented: Binding(
                get: { backendPendingDelete != nil },
                set: { if !$0 { backendPendingDelete = nil } }
            ),
            presenting: backendPendingDelete
        ) { backend in
            Button("Delete", role: .destructive) { deleteEmbedder(backend) }
            Button("Cancel", role: .cancel) {}
        } message: { backend in
            Text("Deleting frees ~\(backend.sizeBlurb ?? "space"). Your library's existing vectors are kept, so re-downloading restores it with no re-embedding.")
        }
    }

    // MARK: - Language Model section (accordion catalog)

    private var llmSection: some View {
        Section {
            // 2026-05-31 — AFM is hidden as an answer engine: it's no longer
            // selectable to write Ask Posey answers (only downloaded MLX
            // models answer; AFM stays for background @Generable tasks).
            // Show only the MLX catalog here.
            ForEach(ModelCatalog.all.filter { $0.source == .mlx }) { model in
                AskPoseyModelRow(
                    model: model,
                    isActive: model.id == selectedModelID,
                    downloader: mlxDownloader,
                    isExpanded: expandedModelID == model.id,
                    onToggleExpand: {
                        expandedModelID = (expandedModelID == model.id) ? nil : model.id
                    },
                    onSelect: { selectModel(model) },
                    onDownload: { downloadModel(model) },
                    onCancel: { mlxDownloader.cancelDownload(modelID: model.id) },
                    onDelete: { modelPendingDelete = model }
                )
                // Per-model scroll anchor for SCROLL_PREFS_TO_LLM:<id>.
                .id("preferences.askPosey.model.\(model.id)")
            }
        } header: {
            Label("Language Model", systemImage: "cpu")
        } footer: {
            Text("The language model writes the answers. Apple Intelligence runs on-device and is always available. The on-device models download from Hugging Face; tap a model to see its character, performance, and size before downloading.")
        }
    }

    // 2026-06-17 — "Search breadth" (RetrievalStrictness picker) REMOVED here.
    // It was a placebo: the weak-retrieval gate (`isWeakRetrieval`) reads a
    // hardcoded RRF floor and never consulted `retrievalStrictness`; the
    // broad/balanced/precise cosine thresholds were abandoned in May when the
    // gate moved to RRF cross-retriever agreement. Per-document retrieval tuning
    // will be REBUILT as a doc-type-driven default (see NEXT.md). The
    // `RetrievalStrictness` enum + pref stay dormant (no storage migration).

    // MARK: - Embedding Model section

    private var embedderSection: some View {
        Section {
            // Same universal flow as the Language Model rows: a status dot plus an
            // accordion whose action row is Download / Select / Delete. Apple
            // NLContextual is the exception — built in, no download/delete, Select
            // only (see AskPoseyEmbedderRow).
            ForEach(EmbeddingBackend.allCases, id: \.rawValue) { backend in
                AskPoseyEmbedderRow(
                    backend: backend,
                    isActive: backend.rawValue == selectedBackendRaw,
                    isBusy: migrationCoordinator.isBusy,
                    isExpanded: expandedEmbedderRaw == backend.rawValue,
                    onToggleExpand: {
                        expandedEmbedderRaw = (expandedEmbedderRaw == backend.rawValue)
                            ? nil : backend.rawValue
                    },
                    onSelect: { handleBackendSelection(backend) },
                    onDownload: { downloadEmbedder(backend) },
                    onCancel: { cancelEmbedderDownload(backend) },
                    onDelete: { backendPendingDelete = backend }
                )
                // Per-backend scroll anchor (parity with the LLM rows).
                .id("preferences.askPosey.embedder.\(backend.rawValue)")
            }
            migrationStatusFooter
        } header: {
            Label("Embedding Model", systemImage: "brain")
        } footer: {
            Text("The embedder turns text into vectors Ask Posey searches. Apple NLContextual is built in and always available — it sharpens search but isn't enough for Ask Posey. Download Nomic or mxbai and Select it to switch (re-embeds your library once, in the background). Delete keeps the vectors it already made, so re-downloading needs no re-embed.")
        }
    }

    @ViewBuilder
    private var migrationStatusFooter: some View {
        switch migrationCoordinator.currentPhase {
        case .idle:
            EmptyView()
        case .downloading(let modelID, let progress):
            HStack {
                ProgressView(value: progress)
                Text("Downloading \(modelID)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop", role: .destructive) { migrationCoordinator.cancel() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        case .switching:
            HStack {
                ProgressView()
                Text("Switching backend…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop", role: .destructive) { migrationCoordinator.cancel() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        case .migrating(let processed, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(processed), total: max(Double(total), 1))
                HStack {
                    Text("Re-embedding chunks: \(processed) / \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop", role: .destructive) { migrationCoordinator.cancel() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        case .done(let reEmbedded):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Re-embedded \(reEmbedded) chunks.")
                    .font(.caption)
                Spacer()
                Button("OK") { migrationCoordinator.acknowledge() }
                    .font(.caption)
            }
        case .cancelled:
            HStack {
                Text("Switch cancelled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("OK") { migrationCoordinator.acknowledge() }
                    .font(.caption)
            }
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("OK") { migrationCoordinator.acknowledge() }
                    .font(.caption)
            }
        }
    }

    private func handleBackendSelection(_ backend: EmbeddingBackend) {
        guard backend.rawValue != selectedBackendRaw else { return }
        guard let db = databaseManager else { return }
        migrationCoordinator.beginSwitch(to: backend, database: db)
    }

    // MARK: - Embedder download / delete (Download → Select → Delete parity)

    /// Fetch a downloadable embedder's model bundle through the same pipeline as
    /// the answer models. Separate from Select on purpose: downloading costs
    /// storage, selecting costs the one-time library re-embed. No-op for the
    /// built-in NLContextual (`modelID == nil`), whose asset iOS manages.
    private func downloadEmbedder(_ backend: EmbeddingBackend) {
        guard let repo = backend.modelID else { return }
        Task { await mlxDownloader.startDownload(modelID: repo, repoID: repo, sizeGB: nil) }
    }

    private func cancelEmbedderDownload(_ backend: EmbeddingBackend) {
        guard let repo = backend.modelID else { return }
        mlxDownloader.cancelDownload(modelID: repo)
    }

    /// Delete a downloadable embedder's model files. Keeps the vectors it already
    /// produced (they belong to the documents; deleting a document reclaims
    /// them). If the deleted embedder was ACTIVE, revert retrieval to the
    /// built-in NLContextual floor — which also drops
    /// `AskPoseyAvailability.embedderProvisioned`, re-locking Ask Posey when no
    /// advanced embedder is active (the present-based gate).
    private func deleteEmbedder(_ backend: EmbeddingBackend) {
        guard let repo = backend.modelID else { return }
        let wasActive = (backend.rawValue == selectedBackendRaw)
        Task {
            await mlxDownloader.deleteModel(modelID: repo)
            await MainActor.run {
                ModelCatalogService.shared.refreshDownloadStates()
                if wasActive {
                    selectedBackendRaw = EmbeddingBackend.nlContextual.rawValue
                }
            }
        }
    }

    // MARK: - Actions (Hal's ModelLibraryView flow)

    private func selectModel(_ model: ModelConfiguration) {
        // Can't select an undownloaded MLX model — Download first.
        guard model.source == .appleFoundation || mlxDownloader.isModelDownloaded(model.id) else {
            return
        }
        selectedModelID = model.id
    }

    private func downloadModel(_ model: ModelConfiguration) {
        // First MLX download is gated by the one-time hardware disclosure.
        if !hasSeenHardwareDisclosure {
            pendingModelAfterDisclosure = model
            showingHardwareDisclosure = true
            return
        }
        beginDownloadOrLicense(model)
    }

    private func resumeAfterDisclosure() {
        hasSeenHardwareDisclosure = true
        showingHardwareDisclosure = false
        guard let model = pendingModelAfterDisclosure else { return }
        pendingModelAfterDisclosure = nil
        beginDownloadOrLicense(model)
    }

    private func beginDownloadOrLicense(_ model: ModelConfiguration) {
        if ModelCatalogService.shared.hasAcceptedLicense(for: model.id) {
            Task {
                await mlxDownloader.startDownload(
                    modelID: model.id, repoID: model.id, sizeGB: model.sizeGB
                )
            }
        } else {
            modelForLicense = model
        }
    }

    private func deleteModel(_ model: ModelConfiguration) {
        Task {
            await mlxDownloader.deleteModel(modelID: model.id)
            ModelCatalogService.shared.revokeLicense(for: model.id)
            await MainActor.run {
                ModelCatalogService.shared.refreshDownloadStates()
                // If the deleted model was active, fall back to another
                // downloaded MLX model (AFM is not an answer engine). If none
                // remain, the unlock gate re-locks Ask Posey; `answerModel()`
                // coerces safely in the meantime.
                if selectedModelID == model.id {
                    if let next = ModelCatalog.all.first(where: {
                        $0.source == .mlx && $0.id != model.id && mlxDownloader.isModelDownloaded($0.id)
                    }) {
                        selectedModelID = next.id
                    }
                }
            }
        }
    }
}

// ========== BLOCK 01: ASK POSEY MODEL LIBRARY VIEW - END ==========
