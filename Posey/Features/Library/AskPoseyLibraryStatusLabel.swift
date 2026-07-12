import SwiftUI
import Combine

// ========== BLOCK 01: ASK POSEY LIBRARY STATUS LABEL - START ==========

/// Per-document Ask Posey readiness, shown on the library card opposite the
/// reading-time label (Mark's design, 2026-06-18): a small dot + short
/// in-character text so a reader knows, at a glance, how ready Posey is to talk
/// about each book.
///
/// **Dot** (reuses the model-picker's green-dot language the user already
/// knows): the dot color tracks ONE thing — answerability. **Grey** while the
/// book is not yet answerable (importing / embedding / queued / cooling before
/// its first embed completes); **green** the moment Ask Posey can actually
/// answer about it (its leaves are embedded), and it STAYS green through every
/// later phase (deepening, cooling-down) because answering still works. The
/// **text** is independent — it explains the current activity. (Decoupling the
/// two fixed a bug where "Cooling down" forced a grey dot on an already-
/// answerable book, misreading as "not ready"; Mark, 2026-06-18.)
///
/// **Layout:** text leads, dot TRAILS (flush-right), so the eye always lands on
/// one fixed point at the end of the row (Mark, 2026-06-18).
///
/// **States:**
///   - not set up  → grey · "Ask Posey not yet available"
///   - cooling down → grey · "Cooling down" (in-flight doc, device thermally paced)
///   - embedding   → grey · "Reading ahead — N%"
///   - queued      → grey · "Queued #k" (waiting in the embed lane; Pillar 4b)
///   - deepening   → green · "Studying up…" (answerable now; RAPTOR building)
///   - ready       → green · "Ready"
///   - preparing   → grey · "Preparing…"   (imported but not yet indexed)
/// Pillar 4b (2026-06-18) added the precise "Queued #k" position (from the
/// queue's published embed lane) and "Cooling down" (from the thermal governor
/// scoped to the current in-flight doc), both via `IndexingTracker`.
struct AskPoseyLibraryStatusLabel: View {

    let documentID: UUID
    let databaseManager: DatabaseManager

    @ObservedObject private var tracker = IndexingTracker.sharedForChat
    /// Whether this document has embedded leaves (→ Ask Posey can answer about
    /// it). Persisted across sessions, so re-checked from the DB rather than a
    /// session-only set; refreshed when indexing state changes.
    @State private var isAnswerable = false

    /// The status TEXT for the current phase. Dot color is computed separately
    /// from `isAnswerable` (see `body`) — text and color are intentionally
    /// decoupled.
    /// 2026-06-19 — text now routes through `PoseyVoice` (curated, in-character,
    /// stable-per-doc) instead of fixed strings. The %/#k are hard-kept by
    /// `PoseyVoice` (appended verbatim). Two accuracy changes Mark caught:
    /// (1) the ENHANCEMENT/OCR phase is now surfaced ("first read") instead of
    /// being lumped into the old catch-all "Preparing…"; (2) "Catching my
    /// breath…" fires ONLY on a true `.critical` pause — a `.serious` stretch is
    /// still embedding (just slower), so it shows progress, not a stall.
    private func resolveStage() -> PoseyVoice.Stage {
        #if POSEY_ENABLE_ASK_POSEY
        // Ask Posey builds: a book not yet set up for Ask Posey reads as "not
        // available". In a v1.0 reader (Ask Posey compiled out) there is no Ask
        // Posey to be un-set-up — this label is a pure SEARCH-readiness signal,
        // so we skip this state and fall through to embedding progress → "Ready"
        // (green the moment the book's leaves are embedded and search is good).
        if !AskPoseyAvailability.isSetUp {
            return .notAvailable
        }
        #endif
        // True pause (critical) outranks everything — she's genuinely stopped.
        if tracker.isCriticallyPaused(documentID) {
            return .catchingBreath
        }
        // Embedding in flight → "Reading ahead — N%" (the percentage is the
        // useful signal). 2026-06-19 (Mark caught it on the phone): a PRIOR
        // `isEnhancing` branch sat AHEAD of this one and returned `.firstRead`
        // ("First pass — taking it in…", no %). But `IndexingTracker.isEnhancing`
        // and `isIndexing` are the SAME predicate (`indexingProgress != nil` —
        // metadata enhancement was torn out in 8f), so that branch shadowed this
        // one for EVERY embedding doc: it never showed the percentage, and it
        // never correctly fired for real PDF OCR (OCR posts no UnitEmbedding
        // progress). Removed it; embedding now honestly shows "Reading ahead —
        // N%". (`firstRead` stays in PoseyVoice for when a real OCR-phase signal
        // is wired to the tracker.)
        if tracker.isIndexing(documentID) {
            let pct = Int(((tracker.unifiedProgress(for: documentID) ?? 0) * 100).rounded())
            return .readingAhead(pct)
        }
        if let position = tracker.queuePosition(documentID) {
            return .queued(position)
        }
        if tracker.isReReading(documentID) {
            if let frac = tracker.reReadingFraction(documentID) {
                return .studyingUp(Int((frac * 100).rounded()))
            }
            return .studyingUp(nil)
        }
        if isAnswerable {
            return .ready
        }
        return .settlingIn
    }

    private func resolveText() -> String {
        PoseyVoice.status(resolveStage(), documentID: documentID)
    }

    private func refreshAnswerable() {
        let count = (try? databaseManager.embeddedLeafChunkCount(for: documentID)) ?? 0
        isAnswerable = count > 0
    }

    var body: some View {
        let text = resolveText()
        // Dot color = answerability ONLY. Text leads, dot trails (flush-right)
        // so the eye lands on one fixed point at the row's end.
        HStack(spacing: 5) {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Circle()
                .fill(isAnswerable ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 7, height: 7)
        }
        .accessibilityElement(children: .combine)
        #if POSEY_ENABLE_ASK_POSEY
        .accessibilityLabel("Ask Posey: \(text)")
        #else
        .accessibilityLabel("Search readiness: \(text)")
        #endif
        .task(id: documentID) { refreshAnswerable() }
        // Re-check "answerable" whenever indexing state changes — e.g. the
        // moment a doc's embedding completes, it flips grey "Reading ahead" →
        // green "Ready".
        .onReceive(tracker.objectWillChange) { _ in refreshAnswerable() }
    }
}

// ========== BLOCK 01: ASK POSEY LIBRARY STATUS LABEL - END ==========
