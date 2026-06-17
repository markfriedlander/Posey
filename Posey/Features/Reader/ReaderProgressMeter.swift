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

    /// Compose a human label from `minutesRemaining`. Mark's spec
    /// (2026-05-26): no leading "~", and minutes ≥ 60 render as
    /// `Xh Ym` (e.g. 661 → "11h 1m"); under 60 stays compact (e.g.
    /// 45 → "45m"); under 1 minute → "<1m left"; nil → "Done".
    var label: String {
        guard let mins = minutesRemaining else { return "Done" }
        if mins < 1 { return "<1m left" }
        if mins < 60 { return "\(mins)m left" }
        let h = mins / 60
        let m = mins % 60
        if m == 0 { return "\(h)h left" }
        return "\(h)h \(m)m left"
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
/// Ambient reader "time remaining" label. Sits at the bottom of the
/// reader, always visible regardless of chrome state. Quiet typography
/// (caption, secondary) so it doesn't pull attention from the document.
///
/// 2026-06-08 — Mark: REMOVED the thin progress bar (the "blue line").
/// A prior instance added a 2px Capsule progress bar above this label
/// (gray track + accent fill whose width tracked the reading fraction).
/// Floating over the scrolling prose it read as a stray half-blue/
/// half-gray underline beneath whatever sentence happened to be behind
/// it — undocumented, unrequested, and visually noisy. Only the
/// "N min left" label remains; the `fraction` is still computed and
/// surfaced via the accessibility label.
struct ReaderProgressMeter: View {
    @ObservedObject var viewModel: ReaderViewModel
    /// 2026-06-17 — drives the floating "reading ahead…" status pill that
    /// mirrors the time-left label on the opposite (leading) side while this
    /// document is still embedding. Replaces the old top-center indexing banner
    /// (Mark: a floating low-key pill opposite the time-left, same quiet visual).
    @ObservedObject var indexingTracker: IndexingTracker

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
        HStack {
            // Leading: floating "reading ahead…" status, only while this
            // document is still embedding. Mirrors the time-left pill on the
            // opposite side in the same quiet visual; persists when chrome fades.
            readingAheadPill
            Spacer()
            // Trailing: the ambient "time remaining" label.
            // 2026-05-22 — .primary at 0.85 (was .secondary, drowned by prose).
            // 2026-05-28 (N4) — opaque Capsule pill so it reads over any text.
            Text(snap.label)
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.85))
                .statusPill()
                .accessibilityIdentifier("reader.progressMeter.label")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading progress: \(Int(snap.fraction * 100)) percent. \(snap.label).")
    }

    /// In-character "reading ahead — N%" pill, shown only while this document's
    /// embedding is in flight. Rotates through the variants (same mechanism as
    /// the thinking phrases); the `%` updates live from `unifiedProgress`.
    @ViewBuilder
    private var readingAheadPill: some View {
        if let frac = indexingTracker.unifiedProgress(for: viewModel.document.id) {
            let pct = Int((frac * 100).rounded())
            // Terse variants sized for this narrow slot (the long ones are for
            // the sparkle popover). One line, only a gentle shrink as a safety
            // net so the text reads at full size like the time-left label.
            let phrases = PoseyStatusCopy.readingAheadShort.map { PoseyStatusCopy.filled($0, pct: pct) }
            RotatingStatusText(phrases: phrases, font: .caption2, color: .primary.opacity(0.85),
                               lineLimit: 1, minimumScaleFactor: 0.9)
                .statusPill()
                .accessibilityIdentifier("reader.indexingPill")
                .transition(.opacity)
        }
    }
}

// ========== BLOCK 03: STATUS PILL STYLE - START ==========

/// The shared low-key capsule treatment used by BOTH the time-left label and
/// the reading-ahead status pill, so they read as a matched pair on opposite
/// sides of the bottom row. Truly-opaque `systemBackground` fill (not Material)
/// + faint border, adaptive to light/dark.
private struct StatusPillStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.systemBackground))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
            )
    }
}

private extension View {
    func statusPill() -> some View { modifier(StatusPillStyle()) }
}
// ========== BLOCK 03: STATUS PILL STYLE - END ==========
// ========== BLOCK 02: VIEW - END ==========
