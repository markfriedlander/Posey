import SwiftUI

// ========== BLOCK 01: ASK POSEY PREFERENCES SECTION - START ==========

/// Form section for Ask Posey settings — embedding backend picker and
/// LLM picker. Drops into any `Form { … }`.
///
/// **Embedding backend picker.** Lists every `EmbeddingBackend`.
/// NLContextual is the default; selecting Nomic triggers
/// `EmbedderMigrationCoordinator.beginSwitch`. Unchanged from the prior
/// implementation.
///
/// **LLM picker.** Rebuilt 2026-05-28 on Hal's model-library skeleton
/// (task #1, replacing commit `985cd55`'s invented goodAt/strugglesWith
/// cards). Accordion-expand-in-place rows (`AskPoseyModelRow`) with a
/// single status-dot language, a full detail card (voice tag →
/// description → performance grid → reading scorecard → license), an
/// explicit gated Download button, a one-time hardware-disclosure sheet,
/// and a license-acceptance sheet. Only approved models
/// (`ModelCatalog.all`) appear; the community catalog machinery lives in
/// `ModelCatalogService` but is not surfaced here.
///
/// 2026-05-23 — introduced (Step 8e). 2026-05-28 — LLM picker rebuilt
/// on the faithful Hal port.
struct AskPoseyPreferencesSection: View {

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

    var body: some View {
        Group {
            embedderSection
            llmSection
        }
        .task {
            // Reconcile download state against disk so downloaded models
            // report correctly the moment the picker opens (Hal parity).
            ModelCatalogService.shared.refreshDownloadStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteExpandAskPoseyModel)) { note in
            if let id = note.userInfo?["modelID"] as? String {
                withAnimation(.easeInOut(duration: 0.18)) { expandedModelID = id }
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
    }

    // MARK: - Embedder section (unchanged)

    private var embedderSection: some View {
        Section {
            ForEach(EmbeddingBackend.allCases, id: \.rawValue) { backend in
                Button {
                    handleBackendSelection(backend)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: backend.rawValue == selectedBackendRaw
                              ? "checkmark.circle.fill"
                              : "circle")
                            .foregroundStyle(backend.rawValue == selectedBackendRaw
                                             ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(backend.displayName)
                                    .font(.body)
                                Spacer()
                                if let size = backend.sizeBlurb {
                                    Text(size)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(backend.blurb)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(migrationCoordinator.isBusy)
            }
            migrationStatusFooter
        } header: {
            Text("Ask Posey · Embedding Model")
        } footer: {
            Text("The embedder converts text into vectors that Ask Posey searches against. Changing it re-embeds every chunk in your library — a one-time cost paid in the background.")
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

    // MARK: - LLM section

    private var llmSection: some View {
        Section {
            ForEach(ModelCatalog.all) { model in
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
            Text("Ask Posey · Language Model")
        } footer: {
            Text("The language model writes the answers. Apple Intelligence runs on-device and is always available. The on-device models download from Hugging Face; tap a model to see its character, performance, and size before downloading.")
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
                // If the deleted model was active, fall back to AFM so the
                // next /ask doesn't try to re-download mid-conversation.
                if selectedModelID == model.id {
                    selectedModelID = ModelCatalog.appleFoundation.id
                }
            }
        }
    }
}

// MARK: - EmbedderMigrationCoordinator convenience

extension EmbedderMigrationCoordinator {
    /// True while a switch is in progress — used to disable backend rows.
    var isBusy: Bool {
        switch currentPhase {
        case .idle, .done, .cancelled, .error: return false
        case .downloading, .switching, .migrating: return true
        }
    }
}

// ========== BLOCK 01: ASK POSEY PREFERENCES SECTION - END ==========
