import UIKit

// ========== BLOCK 01: READER TUNING (THE KNOBS) - START ==========

/// Every feel-parameter of the one-surface reader as a NAMED field — never a magic
/// number. Defaults mimic the Apple-Music-Lyrics feel Mark validated in the tester.
/// Reading "modes" become presets of this struct; a private value today is a
/// user-facing reading option at release for free. See READER_REBUILD_PLAN.md §3.
///
/// Stage B (rebuild). Behind the `useNewReaderSurface` flag; the old reader is
/// untouched until cutover.
struct ReaderTuning: Equatable {

    /// Where the active line is held as text glides underneath, as a fraction of
    /// viewport height. Orientation-aware: portrait is tall (0.34 keeps read-ahead
    /// room below); landscape is short (0.50 balances lead-in/lead-out).
    var focalFractionPortrait: CGFloat = 0.34   // Mark's "read-ahead" knob
    var focalFractionLandscape: CGFloat = 0.50

    /// The read-along highlight. `highlightLines` widens the lit region beyond the
    /// single spoken line (a calmer "reading zone") — pure knob, no architecture
    /// change; the scroll pin still tracks one focal line.
    var highlightColor: UIColor = UIColor(named: "AccentColor")?.withAlphaComponent(0.30)
        ?? UIColor.systemBlue.withAlphaComponent(0.30)
    var highlightLinesAbove: Int = 0
    var highlightLinesBelow: Int = 0

    /// How the read-along highlight follows the voice — a user-facing MODE
    /// (Mark, 2026-07-12). Three genuinely different behaviors, not sizes of one glow:
    /// - `.line` — light the visual line the voice is on, pinned to the focal spot.
    ///   Rides ONLY the voice's real word-position reports, so it's exact when the
    ///   voice reports densely (compact voices) and can pause on premium/Siri voices
    ///   that report their position sparsely. The honest, no-estimation mode.
    /// - `.glide` — same line highlight, but it keeps gliding forward at reading pace
    ///   to bridge the stretches where the voice goes quiet, correcting to the real
    ///   position whenever a report arrives (forward-only, never snaps backward).
    ///   Smooth on any voice, but approximate during the gaps.
    /// - `.teleprompter` — show one sentence at a time held in the same spot, advancing
    ///   on the reliable "starting this sentence" signal. Works on any voice, no
    ///   estimation; a fixed-anchor, focused presentation.
    /// `String`-backed so it persists in `PlaybackPreferences` and round-trips through
    /// the `SET_READALONG_LEVEL` antenna verb by raw name; `CaseIterable` drives the
    /// Preferences picker.
    enum ReadAlongMode: String, CaseIterable, Equatable {
        case line, glide, teleprompter

        /// Title shown in the Preferences picker.
        var displayName: String {
            switch self {
            case .line:         return "Line"
            case .glide:        return "Glide"
            case .teleprompter: return "Teleprompter"
            }
        }

        /// One-line explanation under the picker.
        var description: String {
            switch self {
            case .line:
                return "Follow the exact line the voice is on. Precise, but can pause on some premium voices."
            case .glide:
                return "The highlight glides along at reading pace, so it keeps moving even when the voice goes quiet. Smooth, but approximate."
            case .teleprompter:
                return "Show one sentence at a time, held in the same spot. Reliable on any voice."
            }
        }
    }
    var readAlongMode: ReadAlongMode = .line

    /// Surface insets. Big bottom inset lets even the last line reach the focal
    /// position; top/side are reading margins. The LEFT margin is widened into a
    /// `gutterWidth` so annotation glyphs sit beside the text without colliding with it.
    var topInset: CGFloat = 24
    var sideInset: CGFloat = 16
    var bottomInset: CGFloat = 600

    /// RIGHT gutter that holds the annotation kind-glyph (note / bookmark / conversation)
    /// beside each annotated line — collision-free (outside the text column) and out of
    /// the reading path (lines are ragged-right), so the left reading margin stays clean.
    var gutterWidth: CGFloat = 38
    /// Margin glyph point size as a FRACTION of the body font, so it scales with the
    /// reading size (a Dynamic-Type / font bump carries the glyph with it).
    var annotationGlyphScale: CGFloat = 0.95

    /// Focus-mode dimming of non-active sentences (the surviving M8 reading style).
    var dimNonActiveOpacity: CGFloat = 0.45

    /// Inline annotation styling (E2). The anchored substring is underlined in the
    /// SAME hue as the read-along highlight (Mark, 2026-06-22) so a note visually ties
    /// to the reading highlight; full-strength alpha keeps the underline legible where
    /// the 0.30 highlight band would be too faint as a thin line. The underline marks
    /// WHERE + confidence (solid = sure, dotted = unsure); the margin glyph marks WHAT
    /// kind. Glyph lives in the gutter (margin), not inline (inline collides / reflows).
    var annotationUnderlineColor: UIColor = UIColor(named: "AccentColor")?.withAlphaComponent(0.9)
        ?? UIColor.systemBlue.withAlphaComponent(0.9)

    static let aml = ReaderTuning()
}

// ========== BLOCK 01: READER TUNING (THE KNOBS) - END ==========
