// SparkleWithProgressRing.swift
//
// Sparkle icon with an optional circular progress overlay. Drives
// the unified background-enhancement signal on the Ask Posey chrome
// button: while indexing + metadata extraction (and eventually Phase
// B per-chunk contextual prepends) are in flight for the current
// document, an arc fills around the icon from 0 → 360°. When
// progress is nil (no enhancement running, or finished), only the
// sparkle is shown.
//
// Standard iOS download-style affordance. Tappable throughout —
// Ask Posey works at any percentage; the ring is just ambient
// information saying "Posey is still studying this; answers will
// get better in a few minutes." Disappears when 100% so the user
// isn't reminded of work that no longer matters.

import SwiftUI

struct SparkleWithProgressRing: View {

    /// Foreground color for both the sparkle glyph and the progress
    /// arc. Matches the surrounding chrome tint.
    let tint: Color

    /// Current background-enhancement progress, [0, 1]. When nil,
    /// no ring is drawn. When in-range, an arc covers (progress)
    /// fraction of the circle. Animations on changes are caller's
    /// responsibility — IndexingTracker batches updates per 50
    /// chunks so the ring tween is smooth without reading every
    /// chunk.
    let progress: Double?

    var body: some View {
        ZStack {
            // Background ring, faintly visible while progress is
            // active. Same diameter as the foreground arc so they
            // overlay perfectly.
            if progress != nil {
                Circle()
                    .stroke(tint.opacity(0.20), lineWidth: 2)
                    .frame(width: 28, height: 28)
            }
            // Foreground arc — only drawn when progress is in flight.
            if let p = progress {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1.0, p)))
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 28, height: 28)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: p)
            }
            // Sparkle always present, slightly smaller than the ring
            // so the arc reads cleanly around it.
            Image(systemName: "sparkle")
                .font(.title3)
                .foregroundStyle(tint)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(false)
    }
}
