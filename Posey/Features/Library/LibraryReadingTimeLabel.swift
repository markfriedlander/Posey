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
    /// - `positionSentenceIndex`: the reading position's segment ordinal — the
    ///   reader's index into its `[skip, contentEnd)` window of sentences.
    /// - `playbackSentenceCount`: the number of sentences in that same window
    ///   (`DatabaseManager.playbackSentenceCount`). 0 means "unknown" — no
    ///   sentence rows to judge by — and the verdict falls back to the offset
    ///   compare.
    ///
    /// **The "Completed" verdict is decided by IDENTITY** (Position Rule):
    /// the reader builds `segments` by filtering sentences to the `[skip unit,
    /// content-end unit)` sequence window; `sentenceIndex` is the ordinal in
    /// that window. Reaching its last entry == finished the book — independent
    /// of any character ruler. This replaces the old offset comparison, whose
    /// no-content-end fallback compared the **R2** reading offset against the
    /// **R1** `characterCount` (different rulers, drift per document). The
    /// reading-time MINUTES stay a count (offset-based estimate), as intended.
    static func compute(
        characterCount: Int,
        currentOffset: Int,
        contentEndOffset: Int,
        ratePercentage: Float,
        positionSentenceIndex: Int,
        playbackSentenceCount: Int
    ) -> LibraryReadingTimeEstimate {
        let endOffset = contentEndOffset > 0 ? contentEndOffset : characterCount
        guard characterCount > 0, endOffset > 0 else {
            return LibraryReadingTimeEstimate(state: .unstarted(totalMinutes: 0))
        }

        // Unstarted: zero offset → total reading time. Checked first so a
        // freshly-imported doc (position at offset 0 / sentence 0) reads as
        // "total time", never as a false "Completed" on a one-sentence window.
        if currentOffset <= 0 {
            // ONE shared formula with the reader pill (Mark, 2026-06-28) → no drift.
            let minutes = max(1, ReaderProgressEstimate.readingMinutes(
                charactersRemaining: endOffset, ratePercentage: ratePercentage))
            return LibraryReadingTimeEstimate(state: .unstarted(totalMinutes: minutes))
        }

        // Completed — IDENTITY: the reading position's segment ordinal has
        // reached the last sentence of the reader's window. When we have no
        // sentence rows to judge by (`playbackSentenceCount == 0`, legacy /
        // edge), fall back to the old offset compare (small buffer for
        // sentence-boundary rounding).
        if playbackSentenceCount > 0 {
            if positionSentenceIndex >= playbackSentenceCount - 1 {
                return LibraryReadingTimeEstimate(state: .completed)
            }
        } else if currentOffset >= max(0, endOffset - 1) {
            return LibraryReadingTimeEstimate(state: .completed)
        }

        // In progress: minutes remaining from current position to end — SAME
        // shared formula + SAME content-end finish line as the reader pill.
        let charsRemaining = max(0, endOffset - currentOffset)
        let minutes = max(1, ReaderProgressEstimate.readingMinutes(
            charactersRemaining: charsRemaining, ratePercentage: ratePercentage))
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
    @State private var positionSentenceIndex: Int = 0
    @State private var playbackSentenceCount: Int = 0

    var body: some View {
        Text(estimate.label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .onAppear {
                refreshRate()
                refreshPosition()
                refreshPlaybackCount()
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
                refreshPlaybackCount()
            }
            .onChange(of: document.characterCount) { _, _ in
                refreshPosition()
                refreshPlaybackCount()
            }
    }

    private var estimate: LibraryReadingTimeEstimate {
        LibraryReadingTimeEstimate.compute(
            characterCount: document.characterCount,
            currentOffset: positionOffset,
            contentEndOffset: document.contentEndOffset,
            ratePercentage: ratePercentage,
            positionSentenceIndex: positionSentenceIndex,
            playbackSentenceCount: playbackSentenceCount
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
        positionSentenceIndex = pos?.sentenceIndex ?? 0
    }

    // The reader window's sentence count is fixed per import (it changes only
    // when the document is re-imported, which also changes characterCount), so
    // it's fetched alongside the position rather than on every recompute.
    private func refreshPlaybackCount() {
        playbackSentenceCount = (try? databaseManager.playbackSentenceCount(for: document.id)) ?? 0
    }
}

// ========== BLOCK 02: LIBRARY READING TIME LABEL VIEW - END ==========
