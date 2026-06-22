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

// ========== BLOCK 01b: ANCHOR UNIT (CANONICAL ↔ SURFACE BRIDGE) - START ==========

/// One prose-bearing unit's footprint in BOTH coordinate spaces, so an annotation
/// anchor can round-trip exactly between them:
///   • **canonical** — a stable Character (grapheme) offset into the document's
///     joined prose text (units in order, separated by `"\n\n"`). This is what an
///     annotation persists; it survives font-size / rotation / re-layout because it
///     indexes the *text*, not the on-screen glyphs.
///   • **surface** — the UTF-16 `NSRange` location in the live attributed string the
///     UITextView actually lays out (all kinds, `"\n"` separators, attachments).
///
/// Both directions go through this one table, so create (selection → canonical) and
/// render (canonical → highlight) can never disagree — the round-trip is exact by
/// construction (Step-1 foundation for substring-accurate inline annotations, E2).
struct AnchorUnit {
    let unitID: UUID
    /// Character offset where this unit's text begins in the canonical joined text.
    let canonicalStart: Int
    /// `unit.text.count` — Character count (the canonical length of this unit).
    let charCount: Int
    /// UTF-16 location in the surface string where this unit's text begins.
    let surfaceTextStart: Int
    /// The unit's text — the authority for Character ↔ UTF-16 conversion AND, in
    /// Step 2, the source of the durable anchored-substring + context window.
    let text: String

    /// UTF-16 length of this unit's text in the surface string.
    var surfaceTextLength: Int { text.utf16.count }
}

// ========== BLOCK 01b: ANCHOR UNIT - END ==========

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
    /// Prose-bearing units in document order — the canonical ↔ surface bridge for
    /// annotation anchors. Sorted by both `canonicalStart` and `surfaceTextStart`
    /// (both monotonic, since units are emitted in sequence order).
    let anchors: [AnchorUnit]

    private let indexBySentenceID: [UUID: Int]
    private let indexByPlaybackIndex: [Int: Int]

    init(unitRanges: [UUID: NSRange], segments: [SurfaceSegment], anchors: [AnchorUnit] = []) {
        self.unitRanges = unitRanges
        self.segments = segments
        self.anchors = anchors
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

    // ----- Annotation anchor bridge (canonical ↔ surface) -----

    /// Map a SURFACE selection range to a CANONICAL anchor range (the persisted form).
    /// Each endpoint is resolved into the prose unit that contains it and converted
    /// from UTF-16 → Character offset. Returns nil if the selection touches no prose
    /// text (e.g. only an image attachment). Endpoints in different units are fine —
    /// canonical offsets are globally monotonic.
    func canonicalRange(forSurfaceRange r: NSRange) -> NSRange? {
        guard !anchors.isEmpty else { return nil }
        guard let lo = canonicalOffset(forSurfaceLocation: r.location),
              let hi = canonicalOffset(forSurfaceLocation: NSMaxRange(r)) else { return nil }
        let start = min(lo, hi), end = max(lo, hi)
        return NSRange(location: start, length: end - start)
    }

    /// Map a CANONICAL anchor range back to a SURFACE range to highlight. Returns nil
    /// if the canonical offsets fall outside the current prose (e.g. the text changed
    /// and the anchor no longer resolves — the caller treats that as "unanchorable").
    func surfaceRange(forCanonicalRange r: NSRange) -> NSRange? {
        guard !anchors.isEmpty else { return nil }
        guard let lo = surfaceLocation(forCanonicalOffset: r.location),
              let hi = surfaceLocation(forCanonicalOffset: NSMaxRange(r)) else { return nil }
        let start = min(lo, hi), end = max(lo, hi)
        return NSRange(location: start, length: end - start)
    }

    /// The exact canonical substring for a canonical range (Step-2 durability: the
    /// anchored text we persist + re-find by). Reconstructed from the anchor table.
    func canonicalText(forCanonicalRange r: NSRange) -> String {
        var out = ""
        for a in anchors {
            let aStart = a.canonicalStart, aEnd = a.canonicalStart + a.charCount
            let lo = max(r.location, aStart), hi = min(NSMaxRange(r), aEnd)
            guard lo < hi else { continue }
            let s = a.text
            guard let i = s.index(s.startIndex, offsetBy: lo - aStart, limitedBy: s.endIndex),
                  let j = s.index(s.startIndex, offsetBy: hi - aStart, limitedBy: s.endIndex) else { continue }
            out += s[i..<j]
        }
        return out
    }

    /// Resolve a surface UTF-16 location to a canonical Character offset. Snaps a
    /// location that lands between units (a `"\n"` gap / attachment) to the nearest
    /// unit boundary so a selection endpoint always resolves.
    private func canonicalOffset(forSurfaceLocation loc: Int) -> Int? {
        // Inside a unit's text?
        for a in anchors where loc >= a.surfaceTextStart && loc <= a.surfaceTextStart + a.surfaceTextLength {
            let u16 = loc - a.surfaceTextStart
            return a.canonicalStart + charOffset(in: a.text, forUTF16Offset: u16)
        }
        // Between/around units: snap to the nearest boundary in surface space.
        if let first = anchors.first, loc <= first.surfaceTextStart { return first.canonicalStart }
        if let last = anchors.last, loc >= last.surfaceTextStart + last.surfaceTextLength {
            return last.canonicalStart + last.charCount
        }
        // In a gap between two units — snap to the end of the unit before it.
        let before = anchors.last { loc >= $0.surfaceTextStart + $0.surfaceTextLength }
        return before.map { $0.canonicalStart + $0.charCount }
    }

    /// Resolve a canonical Character offset to a surface UTF-16 location.
    private func surfaceLocation(forCanonicalOffset off: Int) -> Int? {
        for a in anchors where off >= a.canonicalStart && off <= a.canonicalStart + a.charCount {
            let c = off - a.canonicalStart
            return a.surfaceTextStart + utf16Offset(in: a.text, forCharOffset: c)
        }
        return nil   // outside current prose → unanchorable
    }

    private func charOffset(in s: String, forUTF16Offset u: Int) -> Int {
        let clamped = max(0, min(u, s.utf16.count))
        let idx = String.Index(utf16Offset: clamped, in: s)
        return s.distance(from: s.startIndex, to: idx)
    }

    private func utf16Offset(in s: String, forCharOffset c: Int) -> Int {
        guard let idx = s.index(s.startIndex, offsetBy: max(0, min(c, s.count)), limitedBy: s.endIndex) else {
            return s.utf16.count
        }
        return idx.utf16Offset(in: s)
    }
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
