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

    // 2026-05-28 — Observe MLX downloader so download badges and
    // progress reactively re-render in the picker. Fills three real
    // UX gaps from the honest accounting: no downloaded-state
    // indicator, no progress while downloading, no way to delete a
    // downloaded model.
    @ObservedObject private var mlxDownloader = MLXModelDownloader.shared

    /// Confirmation alert state for "Delete model" — `nil` when no
    /// confirmation in flight; otherwise the model the user tapped
    /// delete on.
    @State private var modelPendingDelete: ModelConfiguration? = nil

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
            // 2026-05-28 — Stop button surfaces the cancel that the
            // EmbedderMigrationCoordinator already exposes. Without
            // this, a user who switched and changed their mind had
            // to wait the full migration time (10+ min on a real
            // library) before they could switch back. Matches the
            // CANCEL_EMBEDDING_MIGRATION antenna verb.
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
                ProgressView(value: Double(processed),
                             total: max(Double(total), 1))
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
                modelRow(model)
            }
        } header: {
            Text("Ask Posey · Language Model")
        } footer: {
            Text("The language model writes the answers. Apple Intelligence runs on-device and is always available. MLX models download from Hugging Face on first use; you can delete them later if you change your mind.")
        }
        .alert(
            "Delete \(modelPendingDelete?.displayName ?? "model")?",
            isPresented: Binding(
                get: { modelPendingDelete != nil },
                set: { if !$0 { modelPendingDelete = nil } }
            ),
            presenting: modelPendingDelete
        ) { model in
            Button("Delete", role: .destructive) {
                Task {
                    await mlxDownloader.deleteModel(modelID: model.id)
                    // If the user was on the model they just deleted,
                    // fall back to Apple Intelligence so the next /ask
                    // doesn't try to re-download mid-conversation.
                    if selectedModelID == model.id {
                        selectedModelID = ModelCatalog.appleFoundation.id
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            let size = String(format: "%.1f GB", model.sizeGB)
            Text("Deleting frees ~\(size). You can re-download it later by selecting it again.")
        }
    }

    /// One row in the LLM picker. Pulled out of `llmSection` so the
    /// downloaded badge / progress / delete affordances can grow
    /// independently of the section wrapper.
    @ViewBuilder
    private func modelRow(_ model: ModelConfiguration) -> some View {
        let isMLX = (model.source == .mlx)
        let isDownloaded = isMLX && mlxDownloader.isModelDownloaded(model.id)
        let dlState = mlxDownloader.downloadStates[model.id]
        let isDownloading = dlState?.isDownloading == true
        let progress = dlState?.progress ?? 0.0

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
                        rightBadge(
                            model: model,
                            isMLX: isMLX,
                            isDownloaded: isDownloaded,
                            isDownloading: isDownloading
                        )
                    }
                    Text(model.personality)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(modelDetailLine(model))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // P.S.3 (2026-05-28) — richer card per Mark.
                    // Surface honest "good at / struggles with" so the
                    // user can pick a model on what it does in practice
                    // rather than spec numbers. Only render the
                    // sections when the catalog actually has content
                    // (defensive — Equatable + diffability stay safe).
                    if !model.goodAt.isEmpty || !model.strugglesWith.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            if !model.goodAt.isEmpty {
                                bulletSection(
                                    title: "Good at",
                                    icon: "checkmark",
                                    tint: .green,
                                    items: model.goodAt
                                )
                            }
                            if !model.strugglesWith.isEmpty {
                                bulletSection(
                                    title: "Struggles with",
                                    icon: "exclamationmark",
                                    tint: .orange,
                                    items: model.strugglesWith
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                    // Progress bar while downloading — non-zero only
                    // when MLXModelDownloader publishes
                    // isDownloading=true for this id.
                    if isDownloading {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .padding(.top, 4)
                        if let msg = dlState?.message, !msg.isEmpty {
                            Text(msg)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let err = dlState?.error, !err.isEmpty {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!ModelCatalog.isAvailable(model))
        // 2026-05-28 (P.S.3 verification) — per-model scroll anchor
        // so the antenna can land on a specific card via
        // SCROLL_PREFS_TO_LLM:<model-id>. Without this, the section-
        // level anchor only reveals the first model and there's no
        // way to drive the picker below the fold on physical hardware.
        .id("preferences.askPosey.model.\(model.id)")
        // Swipe-to-delete only enabled for downloaded MLX models.
        // AFM has no on-disk footprint to free; never-downloaded
        // MLX models have nothing to delete.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isDownloaded {
                Button(role: .destructive) {
                    modelPendingDelete = model
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// Right-side badge for the model row. Priority:
    ///   1. "Coming soon" — model marked unavailable in this build
    ///   2. progress percent — currently downloading
    ///   3. "Downloaded" — present on disk, not currently downloading
    ///   4. size — MLX model with on-disk footprint not yet downloaded
    ///   5. nothing — AFM (sizeGB == 0)
    @ViewBuilder
    private func rightBadge(
        model: ModelConfiguration,
        isMLX: Bool,
        isDownloaded: Bool,
        isDownloading: Bool
    ) -> some View {
        if !ModelCatalog.isAvailable(model) {
            Text("Coming soon")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.18), in: Capsule())
        } else if isDownloading {
            let pct = Int((mlxDownloader.downloadStates[model.id]?.progress ?? 0) * 100)
            Text("\(pct)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if isDownloaded {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        } else if model.sizeGB > 0 {
            Text(String(format: "%.1f GB", model.sizeGB))
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// One section of the richer model card — a labeled title +
    /// tinted icon followed by a small bullet list. Used for both
    /// "Good at" (green check) and "Struggles with" (orange bang).
    /// Caption-sized typography to stay deferential to the
    /// displayName + personality line above.
    @ViewBuilder
    private func bulletSection(
        title: String,
        icon: String,
        tint: Color,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 12, alignment: .center)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, alignment: .center)
                    Text(item)
                        .font(.caption2)
                        .foregroundStyle(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
