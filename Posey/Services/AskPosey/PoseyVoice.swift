// PoseyVoice.swift
//
// 2026-06-19 (Mark) — the ONE home for Posey's voice, so we stop scattering
// hardcoded phrase lists (ThinkingIndicatorBubble, the spoiler popover, the
// status label) across the app. Two doors, one character:
//
//   • Door A — CURATED (this file, now): pre-written phrase sets for fast,
//     glanceable, high-frequency surfaces (library statuses, the thinking
//     indicator). Instant, controlled, testable, and the %/#k are never at the
//     LLM's mercy — they're appended verbatim. An on-device LLM call per status
//     update would be too slow/costly AND would add heat during the exact
//     indexing phase the status describes, so curated is the right tool here.
//
//   • Door B — GENERATIVE (later): an LLM voice-transform for SUBSTANTIAL text
//     (the chat answer "polish pass") where latency is acceptable and variety
//     pays off. It will share THIS character definition. Not built yet.
//
// The character: Party Girl's Mary — the witty, warm, sharp librarian who has
// read everything. Bookish, a little wry, genuinely on your side. The status
// phrases telegraph WHERE she is in the process (settling in → first read →
// reading ahead → studying/rereading/taking notes → ready), not just random
// flavor — so the voice is also information.

import Foundation

nonisolated enum PoseyVoice {

    /// A document's current indexing stage, as the user should hear it.
    nonisolated enum Stage: Equatable, Sendable {
        case notAvailable            // Ask Posey isn't set up at all
        case settlingIn              // imported, no work started yet
        case firstRead               // PDF enhancement / OCR — her first read-through
        case readingAhead(Int)       // embedding; Int = percent (HARD-KEPT)
        case studyingUp(Int?)        // RAPTOR deepening; percent if known (HARD-KEPT)
        case queued(Int)             // waiting in the embed lane; Int = place (HARD-KEPT)
        case catchingBreath          // device CRITICALLY paused (true stop), not mere throttle
        case ready                   // answerable
    }

    /// The status line for a stage. Picked stably per (document, stage) so it
    /// doesn't flicker on redraw, varies across documents, and refreshes
    /// pleasantly across launches. The percent / queue place are appended
    /// verbatim so information is never lost to the voice.
    static func status(_ stage: Stage, documentID: UUID) -> String {
        switch stage {
        case .notAvailable:
            return "Ask Posey not yet available"
        case .settlingIn:
            return pick(settling, documentID, 1)
        case .firstRead:
            return pick(firstRead, documentID, 2)
        case .readingAhead(let pct):
            return pick(readingPrefix, documentID, 3) + " — \(pct)%"
        case .studyingUp(let pct):
            let prefix = pick(studyingPrefix, documentID, 4)
            return pct.map { "\(prefix) — \($0)%" } ?? "\(prefix)…"
        case .queued(let place):
            return pick(queuedPrefix, documentID, 5) + " — #\(place)"
        case .catchingBreath:
            return pick(catchingBreath, documentID, 6)
        case .ready:
            return pick(ready, documentID, 7)
        }
    }

    /// Stable-per-(doc,stage) pick. `Hasher` is per-run seeded, so the choice is
    /// fixed within a session (no flicker) and varies across docs + launches.
    /// The salt keeps different stages of the SAME doc from all landing on the
    /// same index.
    private static func pick(_ options: [String], _ documentID: UUID, _ salt: Int) -> String {
        guard !options.isEmpty else { return "" }
        var hasher = Hasher()
        hasher.combine(documentID)
        hasher.combine(salt)
        let h = hasher.finalize()
        let idx = ((h % options.count) + options.count) % options.count
        return options[idx]
    }

    // MARK: - Phrase sets (Party-Girl-librarian voice)

    private static let settling: [String] = [
        "Settling in…",
        "Cracking the spine…",
        "Finding a comfy chair…",
        "Just got my hands on this…",
        "Pouring a coffee, sitting down…",
        "Clearing the desk for this one…"
    ]

    private static let firstRead: [String] = [
        "Reading it through for the first time…",
        "Getting acquainted…",
        "Making out the faded print…",
        "Turning the pages…",
        "First pass — taking it in…",
        "Squinting at the small print…"
    ]

    /// Prefixes; "— N%" is appended. Keep them short — the percent follows.
    private static let readingPrefix: [String] = [
        "Reading ahead",
        "Making my way through",
        "Getting the lay of it",
        "Working through it",
        "Deep in it"
    ]

    private static let studyingPrefix: [String] = [
        "Studying up",
        "Rereading the tricky bits",
        "Taking notes",
        "Connecting the threads",
        "Marking my favorite parts"
    ]

    private static let queuedPrefix: [String] = [
        "Next in line",
        "Waiting my turn",
        "Holding your place",
        "On deck",
        "Right behind the others"
    ]

    private static let catchingBreath: [String] = [
        "Catching my breath…",
        "Letting things cool a sec…",
        "Taking a quick breather…",
        "Fanning myself a moment…",
        "Pausing so we don't overheat…"
    ]

    private static let ready: [String] = [
        "Ready when you are",
        "All caught up",
        "Ready",
        "Let's talk",
        "I've read it — ask away"
    ]
}
