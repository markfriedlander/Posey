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
    /// Seconds each phrase stays before the next. Default matches the thinking
    /// bubble (long enough to read, short enough to see a few).
    var rotationSeconds: Double = 3.0
    var font: Font = .footnote
    var color: Color = .secondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index: Int = 0

    var body: some View {
        Text(phrases.isEmpty ? "" : phrases[min(index, phrases.count - 1)])
            .font(font)
            .foregroundStyle(color)
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
