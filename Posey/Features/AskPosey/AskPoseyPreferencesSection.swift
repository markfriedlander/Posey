import SwiftUI

// ========== BLOCK 01: ASK POSEY PREFERENCES SECTION - START ==========

/// The "Ask Posey" section of the Reader-preferences sheet. Hal's
/// settings convention: a compact section that shows the active model and
/// links out to a dedicated **Model Library** screen, rather than
/// embedding the catalog inline.
///
/// The full catalog (model accordion + search-breadth + embedder picker +
/// gated download + hardware disclosure + license) lives on
/// `AskPoseyModelLibraryView`, pushed from the "Browse Model Library" row.
/// Pushing it onto its own navigation screen — instead of nesting it in
/// this `.sheet` — is what lets the disclosure/license sheets present
/// correctly (see `AskPoseyModelLibraryView`).
///
/// 2026-05-23 — introduced (Step 8e). 2026-05-29 — reduced to the
/// section + link as part of the preferences reorganization; the catalog
/// moved to `AskPoseyModelLibraryView`.
struct AskPoseyPreferencesSection: View {

    @AppStorage(ModelCatalog.defaultsKey)
    private var selectedModelID: String = ModelCatalog.appleFoundation.id

    /// Tapped (or antenna-driven) "Browse Model Library". The navigation
    /// state + `.navigationDestination` live on the host
    /// (`ReaderPreferencesSheet`), not here: this section can be below the
    /// fold and SwiftUI lazily instantiates Form rows, so a
    /// `navigationDestination`/`onReceive` attached here would not be
    /// registered until the row scrolls into view (the antenna push missed
    /// for exactly that reason). Hoisting to the always-rendered host
    /// makes both the user tap and the `OPEN_MODEL_LIBRARY` verb robust.
    let onBrowseModelLibrary: () -> Void

    private var activeModelName: String {
        (ModelCatalog.model(id: selectedModelID) ?? ModelCatalog.appleFoundation).displayName
    }

    var body: some View {
        Section {
            // Active-model row (Hal's "current model" line).
            HStack {
                Text("Model")
                Spacer()
                Text(activeModelName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minHeight: 28)

            // Browse Model Library row — Hal's exact row + icon.
            Button {
                onBrowseModelLibrary()
            } label: {
                HStack {
                    Image(systemName: "square.grid.2x2")
                    Text("Browse Model Library")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("preferences.askPosey.browseModelLibrary")
        } header: {
            Label("Ask Posey", systemImage: "sparkles")
        } footer: {
            Text("Choose which on-device model writes Ask Posey's answers, how widely it searches, and which embedder powers retrieval.")
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
