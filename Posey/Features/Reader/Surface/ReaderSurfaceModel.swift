import Foundation

// ========== BLOCK 01: SURFACE SEGMENT - START ==========

/// A sentence as a RANGE in the single surface string. The range IS the anchor —
/// highlight, scroll-to, tap-to-jump, read-along all reduce to "a range." Carries
/// the Posey ids so the surface can talk back to the playback/notes systems.
struct SurfaceSegment: Equatable {
    let sentenceID: UUID
    let unitID: UUID
    /// 0-based index into the document's flat playback order (the position the
    /// SpeechPlaybackService thinks in). Lets the surface map a tapped/spoken
    /// sentence to the playback head and back.
    let playbackIndex: Int
    let range: NSRange
    let text: String
}

// ========== BLOCK 01: SURFACE SEGMENT - END ==========

// ========== BLOCK 02: LAYOUT MAP (THE SINGLE COORDINATE AUTHORITY) - START ==========

/// The one coordinate authority for the surface — replaces the old three-system
/// reconciliation (global plainText offsets / intra-unit offsets / array indices).
/// Built ONCE alongside the attributed string by SurfaceBuilder, so string and map
/// can never drift.
struct LayoutMap {

    /// Full surface range each content unit occupies (text + any marker/attachment).
    let unitRanges: [UUID: NSRange]
    /// Ordered sentences (playback order) as surface ranges.
    let segments: [SurfaceSegment]

    private let indexBySentenceID: [UUID: Int]
    private let indexByPlaybackIndex: [Int: Int]

    init(unitRanges: [UUID: NSRange], segments: [SurfaceSegment]) {
        self.unitRanges = unitRanges
        self.segments = segments
        var bySentence: [UUID: Int] = [:]
        var byPlayback: [Int: Int] = [:]
        for (i, s) in segments.enumerated() {
            bySentence[s.sentenceID] = i
            byPlayback[s.playbackIndex] = i
        }
        self.indexBySentenceID = bySentence
        self.indexByPlaybackIndex = byPlayback
    }

    func segment(forSentenceID id: UUID) -> SurfaceSegment? {
        indexBySentenceID[id].map { segments[$0] }
    }

    /// The surface range for a playback-queue index (how SpeechPlaybackService
    /// addresses sentences) — the bridge that lets the existing TTS drive read-along.
    func segment(forPlaybackIndex i: Int) -> SurfaceSegment? {
        indexByPlaybackIndex[i].map { segments[$0] }
    }

    /// The segment whose range contains a surface offset (tap-to-jump, hit-test).
    func segment(atSurfaceOffset offset: Int) -> SurfaceSegment? {
        // Binary search would be ideal; linear is fine until profiling says otherwise
        // (segments are pre-sorted by location).
        segments.first { NSLocationInRange(offset, $0.range) }
    }

    func unitRange(_ unitID: UUID) -> NSRange? { unitRanges[unitID] }
}

// ========== BLOCK 02: LAYOUT MAP (THE SINGLE COORDINATE AUTHORITY) - END ==========

// ========== BLOCK 03: READER SURFACE CONTENT - START ==========

/// The built document for the surface: ONE attributed string + its layout map.
struct ReaderSurfaceContent {
    let attributed: NSAttributedString
    let layout: LayoutMap

    static let empty = ReaderSurfaceContent(
        attributed: NSAttributedString(string: ""),
        layout: LayoutMap(unitRanges: [:], segments: []))
}

// ========== BLOCK 03: READER SURFACE CONTENT - END ==========
