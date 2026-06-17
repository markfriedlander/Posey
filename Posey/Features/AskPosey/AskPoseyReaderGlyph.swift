import SwiftUI

// ========== BLOCK 01: ASK POSEY READER GLYPH - START ==========

/// The Ask Posey sparkle in the reader chrome. Replaces the old four-template
/// `Menu` (an AFM-only affordance — removed now that the release answer path is
/// MLX-only and free-form). One control, three behaviors driven by readiness:
///
///   • **Upgrading** (embedder swap in flight → Ask Posey globally locked):
///     the sparkle stays put (it must NOT vanish — that was the "where did Ask
///     Posey go?" gap) and shows an in-character "upgrading…" hint on tap. Ring
///     tracks swap progress. Can't open the chat.
///   • **Reading ahead** (this document still embedding → not ready): tap shows
///     the "reading ahead — N%" hint; ring tracks embedding. Can't open yet
///     (Option B gate: open only after embeddings are 100%).
///   • **Ready** (embeddings done): a plain button — tap opens the free-form
///     chat directly, no menu. If RAPTOR is still re-reading in the background,
///     that status surfaces inside the chat sheet + the Preferences Status
///     section (non-blocking), not here.
///
/// "Hint on tap, no action" reuses SwiftUI's `Menu` with a single
/// non-interactive `Text` — exactly the affordance Mark asked for.
///
/// 2026-06-17 — built with the readiness affordance (Option B). Voice copy lives
/// in `PoseyStatusCopy` so it can be rewritten without touching this logic.
struct AskPoseyReaderGlyph: View {

    let documentID: UUID
    let tint: Color
    /// Opens the free-form Ask Posey chat (the reader's `askSpecificAction`).
    let onOpen: () -> Void

    @ObservedObject var indexingTracker: IndexingTracker
    @ObservedObject private var migration = EmbedderMigrationCoordinator.shared

    /// Random seed for variant selection, set once per view appearance (NOT in
    /// `body`). Gives a fresh in-character line each time the glyph appears
    /// without calling `randomElement()` during render.
    @State private var variantSeed = Int.random(in: 0..<10_000)

    // MARK: - Derived readiness

    /// Swap display derived from the migration coordinator's published phase
    /// (reactive). Active during switching / downloading / migrating — exactly
    /// the window Ask Posey is locked. `fraction`/`pct` are nil when the phase
    /// is indeterminate (model loading) so the ring renders blank, not 0%.
    private var swap: (active: Bool, fraction: Double?, pct: Int?) {
        switch migration.currentPhase {
        case .migrating(let processed, let total):
            let f = total > 0 ? Double(processed) / Double(total) : nil
            return (true, f, f.map { Int(($0 * 100).rounded()) })
        case .switching, .downloading:
            return (true, nil, nil)
        case .idle, .done, .cancelled, .error:
            return (false, nil, nil)
        }
    }

    var body: some View {
        // Stable container so the test-hook registration's onAppear/onDisappear
        // ride a view whose identity doesn't change when the inner readiness
        // branch swaps (Menu↔Button). Chaining .remoteRegister directly on the
        // swapping Group dropped the registration. Release builds no-op this.
        content
            .accessibilityLabel("Ask Posey")
            // Register the test hooks on a CONCRETE view (Color.clear), not the
            // transparent `content` Group — onAppear on a conditional Group fires
            // unreliably, which dropped the registration. Release builds no-op
            // `remoteRegister` entirely.
            .background(
                Color.clear
                    .remoteRegister("reader.askPosey") { onOpen() }
                    .remoteRegister("reader.askPosey.askSpecific") { onOpen() }
            )
            // Advance the variant seed on the same slow cadence as the pill so
            // the popover hint CYCLES through all the variants over time rather
            // than freezing on the one it first rolled (a system Menu can't host
            // its own timer; this drives it from the glyph instead). Runs while
            // the glyph is mounted; cancels when the reader closes.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    if Task.isCancelled { return }
                    variantSeed &+= 1
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        let swap = swap
        // nil ⇒ this document is NOT currently embedding (done, or never needed
        // indexing) ⇒ ready to open. Non-nil ⇒ embedding in flight ⇒ gate closed.
        let embedding = indexingTracker.unifiedProgress(for: documentID)

        Group {
            if swap.active {
                // Stable variant per appearance (seed-based, not body-random).
                let variants = swap.pct != nil
                    ? PoseyStatusCopy.upgrading : PoseyStatusCopy.upgradingIndeterminate
                hintGlyph(text: PoseyStatusCopy.variant(variants, seed: variantSeed, pct: swap.pct),
                          progress: swap.fraction)
            } else if let p = embedding {
                hintGlyph(text: PoseyStatusCopy.variant(PoseyStatusCopy.readingAhead,
                                                        seed: variantSeed,
                                                        pct: Int((p * 100).rounded())),
                          progress: p)
            } else {
                // Ready (possibly re-reading in the background — non-blocking).
                Button(action: onOpen) {
                    SparkleWithProgressRing(tint: tint, progress: nil)
                }
            }
        }
    }

    /// A sparkle whose tap shows an informational hint and drives no action —
    /// a `Menu` with a single non-interactive line. Used for the not-ready
    /// (swap / embedding) states.
    @ViewBuilder
    private func hintGlyph(text: String, progress: Double?) -> some View {
        Menu {
            Section { Text(text) }
        } label: {
            SparkleWithProgressRing(tint: tint, progress: progress)
        }
    }
}

// ========== BLOCK 01: ASK POSEY READER GLYPH - END ==========
