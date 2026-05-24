import SwiftUI

// ========== BLOCK 01: ASK POSEY PREFERENCES SECTION - START ==========

/// Form section for Ask Posey settings — embedding backend picker
/// and LLM picker. Drops into any `Form { … }` that wants to
/// expose model selection.
///
/// **Embedding backend picker.** Lists every `EmbeddingBackend`.
/// NLContextual is the default and always shows as "Active."
/// Selecting Nomic triggers `EmbedderMigrationCoordinator.beginSwitch`,
/// which downloads the model (8h), wipes stale embeddings, and
/// re-embeds the chunk store under the new backend. The
/// coordinator's `Phase` enum drives the inline progress label.
///
/// **LLM picker.** Lists every `ModelConfiguration` in
/// `ModelCatalog.all`. AFM is available today; MLX entries
/// (Gemma / Qwen / Llama / Dolphin) show "Coming soon" until
/// Step 8g brings them live. Selection writes
/// `ModelCatalog.defaultsKey`; the next Ask Posey turn picks up
/// the change.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8e).
struct AskPoseyPreferencesSection: View {

    @ObservedObject var migrationCoordinator: EmbedderMigrationCoordinator
    let databaseManager: DatabaseManager?

    @AppStorage(EmbeddingBackend.defaultsKey)
    private var selectedBackendRaw: String = EmbeddingBackend.nlContextual.rawValue

    @AppStorage(ModelCatalog.defaultsKey)
    private var selectedModelID: String = ModelCatalog.appleFoundation.id

    var body: some View {
        Group {
            embedderSection
            llmSection
        }
    }

    // MARK: - Embedder section

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
            }
        case .switching:
            HStack {
                ProgressView()
                Text("Switching backend…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .migrating(let processed, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(processed),
                             total: max(Double(total), 1))
                Text("Re-embedding chunks: \(processed) / \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Button {
                    if ModelCatalog.isAvailable(model) {
                        selectedModelID = model.id
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: model.id == selectedModelID
                              ? "checkmark.circle.fill"
                              : "circle")
                            .foregroundStyle(model.id == selectedModelID
                                             ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(model.displayName)
                                    .font(.body)
                                Spacer()
                                if !ModelCatalog.isAvailable(model) {
                                    Text("Coming soon")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.18),
                                                    in: Capsule())
                                } else if model.sizeGB > 0 {
                                    Text(String(format: "%.1f GB", model.sizeGB))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(modelDetailLine(model))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!ModelCatalog.isAvailable(model))
            }
        } header: {
            Text("Ask Posey · Language Model")
        } footer: {
            Text("The language model writes the answers. Apple Intelligence runs on-device and is always available. Additional MLX models come online in a future build.")
        }
    }

    private func modelDetailLine(_ model: ModelConfiguration) -> String {
        switch model.source {
        case .appleFoundation:
            return "Apple Foundation Models · on-device · \(model.contextWindow / 1024)K context"
        case .mlx:
            return "MLX · on-device · \(model.contextWindow / 1024)K context"
        }
    }
}

// MARK: - EmbedderMigrationCoordinator convenience

extension EmbedderMigrationCoordinator {
    /// True while a switch is in progress — used by the picker to
    /// disable backend rows so the user can't queue a second swap
    /// over an in-flight one.
    var isBusy: Bool {
        switch currentPhase {
        case .idle, .done, .cancelled, .error: return false
        case .downloading, .switching, .migrating: return true
        }
    }
}

// ========== BLOCK 01: ASK POSEY PREFERENCES SECTION - END ==========
