import SwiftUI

// ========== BLOCK 01: ROTATING STATUS TEXT - START ==========

/// A `Text` that crossfades through a set of phrases on a timer — the same
/// rotation mechanism `ThinkingIndicatorBubble` uses for its thinking phrases,
/// factored out so the readiness statuses (RAPTOR "re-reading", the Preferences
/// Status section, etc.) reuse it instead of reinventing it.
///
/// Random start + anti-repeat so the user doesn't see the same opener twice in a
/// row; honors Reduce Motion (instant swap, no crossfade). Rotation runs only
/// while the view is on screen (the `.task` cancels when it disappears), so it
/// costs nothing once the status clears.
///
/// 2026-06-17 — built with the readiness affordance; copy lives in
/// `PoseyStatusCopy`, all variants rotated per Mark's brief.
struct RotatingStatusText: View {

    /// The phrases to cycle. Already `%PCT%`-filled by the caller if needed.
    let phrases: [String]
    /// Seconds each phrase stays before the next. These are AMBIENT statuses you
    /// read next to (not a thinking-spinner), so the cadence is deliberately
    /// slow — a fast cycle is twitchy and distracting (Mark, 2026-06-17).
    var rotationSeconds: Double = 20.0
    var font: Font = .footnote
    var color: Color = .secondary
    /// When set (e.g. 1 for the bottom pill), the text is constrained to that
    /// many lines and auto-shrinks to fit rather than wrapping — keeps the pill
    /// tidy/single-line like the time-left label while still showing the full
    /// in-character variant.
    var lineLimit: Int? = nil
    var minimumScaleFactor: CGFloat = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index: Int = 0

    var body: some View {
        Text(phrases.isEmpty ? "" : phrases[min(index, phrases.count - 1)])
            .font(font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .minimumScaleFactor(minimumScaleFactor)
            .id(index)               // fresh transition per change
            .transition(.opacity)
            .onAppear {
                // Random start so repeated appearances don't all open the same.
                if phrases.count > 1 { index = Int.random(in: 0..<phrases.count) }
            }
            .task(id: phrases.count) {
                guard phrases.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(rotationSeconds))
                    if Task.isCancelled { return }
                    let next: () -> Int = {
                        var n = Int.random(in: 0..<phrases.count)
                        if n == index { n = (n + 1) % phrases.count }   // anti-repeat
                        return n
                    }
                    if reduceMotion {
                        index = next()
                    } else {
                        withAnimation(.easeInOut(duration: 0.35)) { index = next() }
                    }
                }
            }
    }
}

// ========== BLOCK 01: ROTATING STATUS TEXT - END ==========
