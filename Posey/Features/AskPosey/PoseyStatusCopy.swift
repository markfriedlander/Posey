import Foundation

// ========== BLOCK 01: POSEY STATUS COPY - START ==========

/// In-character status copy for Ask Posey's background-work states (Parker-
/// Posey-sharp: self-assured, a little imperious, warm underneath). Kept in ONE
/// place, decoupled from view logic, so the VOICE can be rewritten without
/// touching any control flow.
///
/// Each state holds an ARRAY of variants — they ALL get used (Mark, 2026-06-17),
/// rotated the same way `ThinkingIndicatorBubble` cycles its ~30 thinking
/// phrases: persistent surfaces (the RAPTOR "re-reading" notice, the Preferences
/// Status section) crossfade through them on a timer via `RotatingStatusText`;
/// the transient tap popover (reader sparkle) shows a random pick each time it's
/// opened (a system `Menu` can't host a live timer). `%PCT%` is the progress
/// placeholder, filled by `filled(_:pct:)`.
///
/// The four states map to the readiness model the reader sparkle + the
/// Preferences Status section render:
///   - `readingAhead`  — embedding in flight (gate closed; chat won't open yet)
///   - `ready`         — embeddings done (chat opens)
///   - `reReading`     — RAPTOR building (post-ready, non-blocking deepening)
///   - `upgrading`     — embedder swap in flight (Ask Posey globally locked)
enum PoseyStatusCopy {

    /// Embedding in progress — "reading ahead", gate closed. `%PCT%` → percent.
    static let readingAhead: [String] = [
        "Reading ahead so I'll know everything — %PCT%",
        "Doing my homework — %PCT%. I'll be insufferable when I'm done.",
        "Devouring this one — %PCT%. Don't rush genius.",
        "Getting through it so you don't have to — %PCT%",
        "%PCT% in. Give me a minute, I'm getting to the good part.",
        "Cramming. %PCT% deep. I'll be unbearable soon.",
    ]

    /// SHORT "reading ahead" variants for the bottom status PILL, which sits in
    /// a narrow slot next to the time-left label and must fit ONE line at full
    /// size (the long `readingAhead` variants are for the roomy sparkle popover).
    /// Keep these terse — roughly time-left length (Mark, 2026-06-17).
    static let readingAheadShort: [String] = [
        "Reading ahead — %PCT%",
        "Catching up — %PCT%",
        "Doing my homework — %PCT%",
        "Skimming ahead — %PCT%",
        "Cramming — %PCT%",
        "Studying up — %PCT%",
    ]

    /// Embeddings complete — chat opens. No percent.
    static let ready: [String] = [
        "Read it. Ask me anything.",
        "Finished. I have opinions.",
        "All caught up. Test me.",
        "Done. Try me.",
        "Read, marked, and ready. Go on.",
    ]

    /// RAPTOR summary tree building — post-ready, non-blocking deepening. No pct.
    static let reReading: [String] = [
        "Loved it — going back for a second read. Big-picture answers keep getting sharper.",
        "Already? Fine, reading it again — properly this time.",
        "Second pass in progress. I'm connecting the dots.",
        "Re-reading the good parts. The big-picture stuff is coming together.",
        "Going back for the deep cuts. I only get smarter from here.",
    ]

    /// Embedder swap in flight — Ask Posey globally locked, "upgrading".
    /// `%PCT%` → percent, or use `upgradingIndeterminate` when no percent.
    static let upgrading: [String] = [
        "Upgrading how I read your whole library — %PCT%. Worth the wait.",
        "Rewiring my brain — %PCT%. Back in a sec.",
        "Reorganizing everything I know — %PCT%. Almost there.",
        "Making myself smarter about your library — %PCT%.",
    ]

    /// Upgrading copy for the indeterminate phase (model loading, no percent).
    static let upgradingIndeterminate: [String] = [
        "Upgrading how I read your whole library. Worth the wait.",
        "Rewiring my brain. Back in a sec.",
        "Reorganizing everything I know. Almost there.",
    ]

    // MARK: - Helpers

    /// Replace the `%PCT%` placeholder with a formatted percent.
    static func filled(_ template: String, pct: Int) -> String {
        template.replacingOccurrences(of: "%PCT%", with: "\(pct)%")
    }

    /// A DETERMINISTIC variant chosen by `seed` (so it's stable across a view's
    /// re-renders — never call `randomElement()` in a SwiftUI `body`, which
    /// churns re-evaluation and destabilizes the subtree). Callers hold a
    /// `@State` random seed set once per appearance to get variety without the
    /// churn. `%PCT%` filled if `pct` is given.
    static func variant(_ variants: [String], seed: Int, pct: Int? = nil) -> String {
        guard !variants.isEmpty else { return "" }
        let pick = variants[abs(seed) % variants.count]
        return pct.map { filled(pick, pct: $0) } ?? pick
    }
}

// ========== BLOCK 01: POSEY STATUS COPY - END ==========
