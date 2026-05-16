import SwiftUI

// ========== BLOCK 01: PROGRESS MODEL - START ==========
/// Pure calculation surface so the meter is testable without a
/// SwiftUI body. Estimates "time remaining" from the current
/// position and the user's effective speech rate.
///
/// **Words-per-minute baseline.** 155 wpm at rate=100% (the May-7
/// audio-export investigation pinned Posey's live playback at ~150
/// wpm; 155 splits the difference between conversational and the
/// faster `say` baseline). Custom-mode rate scales linearly: rate=150
/// → 232 wpm, rate=75 → 116 wpm. Best Available mode is
/// rate-independent (Apple controls pacing via the system Spoken
/// Content setting); we use the 155 wpm baseline as a reasonable
/// fallback.
///
/// **Words from chars.** Mean English word length is ~5 characters
/// including the trailing space. Using 5.0 as the divisor gives a
/// stable estimate across genres without segment-level counting.
struct ReaderProgressEstimate: Equatable {
    /// 0.0 … 1.0, fraction of segments past.
    let fraction: Double
    /// Estimated minutes remaining at the current effective WPM.
    /// Nil when the document is finished (fraction ≥ 1.0) or when
    /// there's nothing meaningful to display (empty/1-segment docs).
    let minutesRemaining: Int?

    /// Compose a human label from `minutesRemaining`. Always
    /// "~N min left" so the meter reads at a glance. Less than one
    /// minute → "less than 1 min left". Done → "Done".
    var label: String {
        guard let mins = minutesRemaining else { return "Done" }
        if mins < 1 { return "less than 1 min left" }
        return "~\(mins) min left"
    }

    /// Compute a `ReaderProgressEstimate` from playback context.
    /// - Parameters:
    ///   - currentSentenceIndex: VM's active sentence (0-based).
    ///   - totalSegments: Total number of sentences.
    ///   - charactersRemaining: Plain-text characters from the start
    ///     of the active sentence to the end of the document.
    ///   - ratePercentage: User's custom-mode rate as a percentage
    ///     (75 → 150 in the in-app slider). Pass `100` for the
    ///     baseline.
    static func compute(
        currentSentenceIndex: Int,
        totalSegments: Int,
        charactersRemaining: Int,
        ratePercentage: Float
    ) -> ReaderProgressEstimate {
        guard totalSegments > 0 else {
            return ReaderProgressEstimate(fraction: 0, minutesRemaining: nil)
        }
        let safeIndex = max(0, min(currentSentenceIndex, totalSegments - 1))
        let frac = Double(safeIndex + 1) / Double(totalSegments)
        if charactersRemaining <= 0 {
            return ReaderProgressEstimate(fraction: 1.0, minutesRemaining: nil)
        }
        let baseWPM: Double = 155.0
        let pct = max(50.0, min(200.0, Double(ratePercentage > 0 ? ratePercentage : 100)))
        let effectiveWPM = baseWPM * (pct / 100.0)
        let words = Double(charactersRemaining) / 5.0
        let minutes = max(0, Int((words / effectiveWPM).rounded()))
        return ReaderProgressEstimate(
            fraction: min(1.0, max(0.0, frac)),
            minutesRemaining: minutes
        )
    }
}
// ========== BLOCK 01: PROGRESS MODEL - END ==========


// ========== BLOCK 02: VIEW - START ==========
/// Ambient reader progress meter — thin bar + "~N min left" label.
/// Sits at the bottom of the reader, always visible regardless of
/// chrome state. Quiet typography (caption, secondary) so it doesn't
/// pull attention from the document.
///
/// The progress bar uses the system tint at 35% opacity over a
/// neutral track so it blends with both reading background variants.
struct ReaderProgressMeter: View {
    @ObservedObject var viewModel: ReaderViewModel

    private var estimate: ReaderProgressEstimate {
        let segs = viewModel.segments
        let idx = viewModel.currentSentenceIndex
        let charsRemaining: Int = {
            guard segs.indices.contains(idx) else {
                return 0
            }
            let segStart = segs[idx].startOffset
            return max(0, viewModel.document.characterCount - segStart)
        }()
        return ReaderProgressEstimate.compute(
            currentSentenceIndex: idx,
            totalSegments: segs.count,
            charactersRemaining: charsRemaining,
            ratePercentage: viewModel.customRatePercentage
        )
    }

    var body: some View {
        let snap = estimate
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: proxy.size.width * snap.fraction)
                }
            }
            .frame(height: 2)
            HStack {
                Spacer()
                Text(snap.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader.progressMeter.label")
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading progress: \(Int(snap.fraction * 100)) percent. \(snap.label).")
    }
}
// ========== BLOCK 02: VIEW - END ==========
