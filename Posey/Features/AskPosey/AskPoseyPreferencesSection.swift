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

    // 2026-06-17 — live state for the "Ask Posey — Ready / Upgrading / Reading
    // ahead" status row. The app-wide view of readiness when you're NOT in a
    // reader (the slim remnant of the Status-section idea).
    @ObservedObject private var migration = EmbedderMigrationCoordinator.shared
    @ObservedObject private var indexingTracker = IndexingTracker.sharedForChat

    /// Tapped (or antenna-driven) "Browse Model Library". The navigation
    /// state + `.navigationDestination` live on the host
    /// (`ReaderPreferencesSheet`), not here: this section can be below the
    /// fold and SwiftUI lazily instantiates Form rows, so a
    /// `navigationDestination`/`onReceive` attached here would not be
    /// registered until the row scrolls into view (the antenna push missed
    /// for exactly that reason). Hoisting to the always-rendered host
    /// makes both the user tap and the `OPEN_MODEL_LIBRARY` verb robust.
    let onBrowseModelLibrary: () -> Void

    /// 2026-05-31 — tapped on the **locked** invitation row. The host
    /// presents `AskPoseyOnboardingView`, which then flows into the Model
    /// Library. Always-visible on-ramp: this section is how the reader
    /// discovers + downloads what Ask Posey needs, so it shows even when the
    /// feature is locked (only the *reader* surfaces hide until unlocked).
    let onGetStarted: () -> Void

    private var activeModelName: String {
        (ModelCatalog.model(id: selectedModelID) ?? ModelCatalog.appleFoundation).displayName
    }

    var body: some View {
        Section {
            // Key on isSetUp (has models), NOT isUnlocked — so a doc indexing
            // or an embedder swap (both make isUnlocked false) shows the live
            // status + settings, not the "Set Up" invitation.
            if AskPoseyAvailability.isSetUp {
                statusRow
                unlockedRows
            } else {
                invitationRow
            }
        } header: {
            Label("Ask Posey", systemImage: "sparkles")
        } footer: {
            if AskPoseyAvailability.isSetUp {
                Text("Choose which on-device model writes Ask Posey's answers, how widely it searches, and which embedder powers retrieval.")
            } else {
                Text("A private, fully offline reading companion. Free — it just needs a one-time download to set up.")
            }
        }
    }

    // MARK: - Status row (app-wide readiness)

    /// One honest line: is Ask Posey ready right now, and if not, what's it
    /// doing? A colored dot + short status — reader-serving, not a dashboard.
    private var statusRow: some View {
        let s = status
        return HStack(spacing: 10) {
            Circle()
                .fill(s.tint)
                .frame(width: 8, height: 8)
            Text(s.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ask Posey status: \(s.text)")
        .accessibilityIdentifier("preferences.askPosey.status")
    }

    /// Derived readiness: swap in flight → upgrading; any document embedding →
    /// reading ahead; RAPTOR building → deepening; otherwise ready. Green when
    /// usable now, orange while it's working toward ready.
    private var status: (text: String, tint: Color) {
        switch migration.currentPhase {
        case .migrating(let processed, let total):
            let pct = total > 0 ? Int((Double(processed) / Double(total) * 100).rounded()) : 0
            return ("Upgrading — \(pct)%", .orange)
        case .switching, .downloading:
            return ("Upgrading…", .orange)
        case .idle, .done, .cancelled, .error:
            break
        }
        if let p = indexingTracker.indexingProgress.values.first(where: { $0.total > 0 }) {
            return ("Reading ahead — \(Int((p.fraction * 100).rounded()))%", .orange)
        }
        if !indexingTracker.reReadingDocumentIDs.isEmpty {
            return ("Ready — still deepening in the background", .green)
        }
        return ("Ready", .green)
    }

    // MARK: - Locked: the invitation on-ramp

    @ViewBuilder
    private var invitationRow: some View {
        Button(action: onGetStarted) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Set Up Ask Posey")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        freeBadge
                    }
                    Text("Ask questions about your book — private and offline.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
        }
        .accessibilityIdentifier("preferences.askPosey.getStarted")
        .accessibilityLabel("Set Up Ask Posey, Free")
    }

    /// "Free" capsule so users never think Ask Posey costs money.
    private var freeBadge: some View {
        Text("FREE")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.15))
            )
            .accessibilityHidden(true)
    }

    // MARK: - Unlocked: live settings

    @ViewBuilder
    private var unlockedRows: some View {
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
