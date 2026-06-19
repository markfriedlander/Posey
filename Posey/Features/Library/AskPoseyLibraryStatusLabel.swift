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
    private func resolveText() -> String {
        if !AskPoseyAvailability.isSetUp {
            return "Ask Posey not yet available"
        }
        // Cooling-down outranks "Reading ahead": when the device is hot the
        // in-flight doc's indexing is deliberately paced, so say so rather than
        // letting a frozen percentage read as broken.
        if tracker.isCoolingDown(documentID) {
            return "Cooling down"
        }
        if tracker.isIndexing(documentID) {
            let pct = Int(((tracker.unifiedProgress(for: documentID) ?? 0) * 100).rounded())
            return "Reading ahead — \(pct)%"
        }
        // Waiting in the embed lane behind another document — show its place in
        // line so a slow-to-start card reads as queued, not stuck.
        if let position = tracker.queuePosition(documentID) {
            return "Queued #\(position)"
        }
        if tracker.isReReading(documentID) {
            // Per-step % so "Studying up" reads as progress, not an indefinite
            // spinner (Mark, 2026-06-18) — mirrors "Reading ahead — N%".
            if let frac = tracker.reReadingFraction(documentID) {
                return "Studying up — \(Int((frac * 100).rounded()))%"
            }
            return "Studying up…"
        }
        if isAnswerable {
            return "Ready"
        }
        return "Preparing…"
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
        .accessibilityLabel("Ask Posey: \(text)")
        .task(id: documentID) { refreshAnswerable() }
        // Re-check "answerable" whenever indexing state changes — e.g. the
        // moment a doc's embedding completes, it flips grey "Reading ahead" →
        // green "Ready".
        .onReceive(tracker.objectWillChange) { _ in refreshAnswerable() }
    }
}

// ========== BLOCK 01: ASK POSEY LIBRARY STATUS LABEL - END ==========
