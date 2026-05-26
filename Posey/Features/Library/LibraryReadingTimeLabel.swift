import SwiftUI
import AVFoundation

// ========== BLOCK 01: READING TIME ESTIMATE - START ==========

/// Phase 2.2 Step 8 — library-card reading-time math.
///
/// Mirrors the `ReaderProgressEstimate` calculation used by the
/// in-reader progress meter (155 wpm baseline at rate=100%; words
/// estimated as `characters / 5`; Best Available mode treated as
/// rate=100). The library variant exposes three states:
///
///   - **Unstarted** — reading position absent or at offset 0 →
///     "~N min" / "~Nh Mm" — total reading time for the whole doc
///   - **In progress** — partial offset → "~N min left" / "~Nh Mm left"
///   - **Completed** — offset at or past `contentEndOffset` (or
///     `characterCount` when no content-end was detected) → "Completed"
struct LibraryReadingTimeEstimate: Equatable {

    enum State: Equatable {
        case unstarted(totalMinutes: Int)
        case inProgress(minutesRemaining: Int)
        case completed
    }

    let state: State

    var label: String {
        switch state {
        case .unstarted(let total):
            return Self.formatTotal(minutes: total)
        case .inProgress(let mins):
            return Self.formatRemaining(minutes: mins)
        case .completed:
            return "Completed"
        }
    }

    /// Compute the estimate from inputs.
    /// - `characterCount`: document total
    /// - `currentOffset`: reading-position character offset (0 if unstarted / nil position)
    /// - `contentEndOffset`: 0 means use characterCount as the end
    /// - `ratePercentage`: TTS rate as a percentage (75–150 typical;
    ///   100 for Best Available)
    static func compute(
        characterCount: Int,
        currentOffset: Int,
        contentEndOffset: Int,
        ratePercentage: Float
    ) -> LibraryReadingTimeEstimate {
        let endOffset = contentEndOffset > 0 ? contentEndOffset : characterCount
        guard characterCount > 0, endOffset > 0 else {
            return LibraryReadingTimeEstimate(state: .unstarted(totalMinutes: 0))
        }

        let baseWPM: Double = 155.0
        let pct = max(50.0, min(200.0, Double(ratePercentage > 0 ? ratePercentage : 100)))
        let effectiveWPM = baseWPM * (pct / 100.0)

        // Completed: at or past end (with a small buffer for sentence-
        // boundary rounding).
        if currentOffset >= max(0, endOffset - 1) {
            return LibraryReadingTimeEstimate(state: .completed)
        }

        // Unstarted: zero offset → total reading time.
        if currentOffset <= 0 {
            let words = Double(endOffset) / 5.0
            let minutes = max(1, Int((words / effectiveWPM).rounded()))
            return LibraryReadingTimeEstimate(state: .unstarted(totalMinutes: minutes))
        }

        // In progress: minutes remaining from current position to end.
        let charsRemaining = max(0, endOffset - currentOffset)
        let words = Double(charsRemaining) / 5.0
        let minutes = max(1, Int((words / effectiveWPM).rounded()))
        return LibraryReadingTimeEstimate(state: .inProgress(minutesRemaining: minutes))
    }

    // MARK: Formatting

    // Mark's spec (2026-05-26): single-letter abbreviations, no "~".
    // 661 → "11h 1m"; 45 → "45m"; 1 → "1m"; 60 → "1h".
    private static func formatTotal(minutes: Int) -> String {
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private static func formatRemaining(minutes: Int) -> String {
        if minutes < 1 { return "Almost done" }
        if minutes < 60 { return "\(minutes)m left" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h left" : "\(h)h \(m)m left"
    }
}

// ========== BLOCK 01: READING TIME ESTIMATE - END ==========


// ========== BLOCK 02: LIBRARY READING TIME LABEL VIEW - START ==========

/// Library card subtitle — replaces the previous "N characters"
/// display with a reading-time / time-remaining / completed label.
///
/// Re-reads the document's reading position from the DB whenever the
/// document set changes (which it does when the enhancement service
/// posts `enhancementDidComplete` per Step 7). The TTS rate is read
/// from `PlaybackPreferences.shared.voiceMode`; rate changes posted
/// via `UserDefaults.didChangeNotification` trigger a recompute so
/// the label tracks the user's slider in real time.
struct LibraryReadingTimeLabel: View {
    let document: Document
    let databaseManager: DatabaseManager

    @State private var ratePercentage: Float = 100
    @State private var positionOffset: Int = 0

    var body: some View {
        Text(estimate.label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .onAppear {
                refreshRate()
                refreshPosition()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UserDefaults.didChangeNotification
            )) { _ in
                refreshRate()
            }
            // Reading position can change while the user is reading or
            // when enhancement completes (the embedding-index handoff
            // doesn't change the position, but a re-import does).
            .onChange(of: document.id) { _, _ in
                refreshPosition()
            }
            .onChange(of: document.characterCount) { _, _ in
                refreshPosition()
            }
    }

    private var estimate: LibraryReadingTimeEstimate {
        LibraryReadingTimeEstimate.compute(
            characterCount: document.characterCount,
            currentOffset: positionOffset,
            contentEndOffset: document.contentEndOffset,
            ratePercentage: ratePercentage
        )
    }

    private func refreshRate() {
        let mode = PlaybackPreferences.shared.voiceMode
        if case .custom(_, let rate) = mode {
            ratePercentage = (rate / AVSpeechUtteranceDefaultSpeechRate) * 100.0
        } else {
            ratePercentage = 100.0
        }
    }

    private func refreshPosition() {
        let pos = try? databaseManager.readingPosition(for: document.id)
        positionOffset = pos?.characterOffset ?? 0
    }
}

// ========== BLOCK 02: LIBRARY READING TIME LABEL VIEW - END ==========
