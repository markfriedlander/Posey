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

    /// How much of the text the read-along glow covers as the voice reads — a user-facing
    /// DIAL (Mark, 2026-06-26). `.sentence` lights the whole spoken sentence; `.line`
    /// lights just the visual line the voice is on (the gliding-line feel); `.word` lights
    /// only the single word being spoken. The scroll always pins the active LINE to the
    /// focal point regardless — only the glow's extent changes with this dial.
    enum ReadAlongGranularity: Equatable { case word, line, sentence }
    var readAlongGranularity: ReadAlongGranularity = .line

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
