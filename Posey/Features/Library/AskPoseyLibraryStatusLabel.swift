import SwiftUI
import Combine

// ========== BLOCK 01: ASK POSEY LIBRARY STATUS LABEL - START ==========

/// Per-document Ask Posey readiness, shown on the library card opposite the
/// reading-time label (Mark's design, 2026-06-18): a small dot + short
/// in-character text so a reader knows, at a glance, how ready Posey is to talk
/// about each book.
///
/// **Dot** (reuses the model-picker's green-dot language the user already
/// knows): **grey** once imported but not yet answerable; **green** the moment
/// Ask Posey can actually answer about this book (its leaves are embedded). The
/// **text** keeps explaining "how ready she is" past that point (e.g. green +
/// "Studying up…" while RAPTOR deepens in the background).
///
/// **States (V1):**
///   - not set up → grey · "Ask Posey not yet available"
///   - embedding  → grey · "Reading ahead — N%"
///   - preparing  → grey · "Preparing…"   (imported, queued, or never indexed)
///   - deepening  → green · "Studying up…" (answerable now; RAPTOR building)
///   - ready      → green · "Ready"
/// Refinements deferred (Pillar 4b): precise "Queued #k" position (needs the
/// queue's published state) and "Cooling down" (needs the thermal governor +
/// current-doc identity).
struct AskPoseyLibraryStatusLabel: View {

    let documentID: UUID
    let databaseManager: DatabaseManager

    @ObservedObject private var tracker = IndexingTracker.sharedForChat
    /// Whether this document has embedded leaves (→ Ask Posey can answer about
    /// it). Persisted across sessions, so re-checked from the DB rather than a
    /// session-only set; refreshed when indexing state changes.
    @State private var isAnswerable = false

    private struct Status {
        let text: String
        let isGreen: Bool
    }

    private func resolve() -> Status {
        if !AskPoseyAvailability.isSetUp {
            return Status(text: "Ask Posey not yet available", isGreen: false)
        }
        if tracker.isIndexing(documentID) {
            let pct = Int(((tracker.unifiedProgress(for: documentID) ?? 0) * 100).rounded())
            return Status(text: "Reading ahead — \(pct)%", isGreen: false)
        }
        if tracker.isReReading(documentID) {
            return Status(text: "Studying up…", isGreen: true)
        }
        if isAnswerable {
            return Status(text: "Ready", isGreen: true)
        }
        return Status(text: "Preparing…", isGreen: false)
    }

    private func refreshAnswerable() {
        let count = (try? databaseManager.embeddedLeafChunkCount(for: documentID)) ?? 0
        isAnswerable = count > 0
    }

    var body: some View {
        let status = resolve()
        HStack(spacing: 5) {
            Circle()
                .fill(status.isGreen ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 7, height: 7)
            Text(status.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ask Posey: \(status.text)")
        .task(id: documentID) { refreshAnswerable() }
        // Re-check "answerable" whenever indexing state changes — e.g. the
        // moment a doc's embedding completes, it flips grey "Reading ahead" →
        // green "Ready".
        .onReceive(tracker.objectWillChange) { _ in refreshAnswerable() }
    }
}

// ========== BLOCK 01: ASK POSEY LIBRARY STATUS LABEL - END ==========
