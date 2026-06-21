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

    /// Surface insets. Big bottom inset lets even the last line reach the focal
    /// position; top/side are reading margins.
    var topInset: CGFloat = 24
    var sideInset: CGFloat = 16
    var bottomInset: CGFloat = 600

    /// Focus-mode dimming of non-active sentences (the surviving M8 reading style).
    var dimNonActiveOpacity: CGFloat = 0.45

    static let aml = ReaderTuning()
}

// ========== BLOCK 01: READER TUNING (THE KNOBS) - END ==========
