import Foundation

// ========== BLOCK 01: READER CHROME STATE - START ==========
/// Shared accessor for the reader's chrome visibility — used by the
/// local API verb `READER_CHROME_STATE` so automated verification can
/// check whether tap-to-toggle actually flipped chrome on/off without
/// requiring a screenshot diff.
///
/// Written by `ReaderView` whenever `isChromeVisible` changes (via
/// `.onChange`). Read by `LibraryViewModel.executeAPICommand` in the
/// `READER_CHROME_STATE` branch.
@MainActor
final class ReaderChromeState {
    static let shared = ReaderChromeState()
    private init() {}

    /// True while the reader's chrome (Ask Posey, Notes, Play, etc.)
    /// is on screen. False during the faded-out state.
    var isVisible: Bool = true
}
// ========== BLOCK 01: READER CHROME STATE - END ==========
