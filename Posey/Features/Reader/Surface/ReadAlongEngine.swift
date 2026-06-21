import UIKit

// ========== BLOCK 01: READ-ALONG ENGINE (CORE SPINE) - START ==========

/// The read-along engine: given the spoken word's position, light its VISUAL LINE
/// and glide it to the focal point. Highlight + scroll-pin are two faces of one
/// engine, kept together.
///
/// It does NOT own the synthesizer. At Stage C, Posey's `SpeechPlaybackService`
/// drives it — it already knows the playback-queue index of the spoken sentence,
/// and (once we add `willSpeakRange`) the word offset within that sentence. The
/// engine maps (playbackIndex, intra-word offset) → a surface offset via the
/// `LayoutMap`, exactly as the tester's TTSDriver did. The surface/core never know
/// which source is speaking.
@MainActor
final class ReadAlongEngine {

    private let surface: ReaderSurface
    private var lastLineRange: NSRange?

    /// Fired on each line change (status / now-playing / observers).
    var onLineChange: ((_ lineRange: NSRange, _ segment: SurfaceSegment?) -> Void)?

    init(surface: ReaderSurface) { self.surface = surface }

    /// Playback started/stopped/seeked — next word re-pins fresh.
    func reset() {
        lastLineRange = nil
        surface.setActiveLine(nil)
    }

    /// The voice is speaking the word at `wordOffset` characters into the sentence at
    /// playback index `playbackIndex`. Light + pin that word's visual line.
    func onSpokenWord(playbackIndex: Int, wordOffset: Int) {
        guard let seg = surface.content.layout.segment(forPlaybackIndex: playbackIndex) else { return }
        let surfaceOffset = seg.range.location + max(0, min(wordOffset, seg.range.length - 1))
        advance(toSurfaceOffset: surfaceOffset, segment: seg)
    }

    /// Sentence-granular fallback (no word offset available): pin the sentence's
    /// first line. Lets read-along work even before `willSpeakRange` is wired.
    func onSpokenSentence(playbackIndex: Int) {
        guard let seg = surface.content.layout.segment(forPlaybackIndex: playbackIndex) else { return }
        advance(toSurfaceOffset: seg.range.location, segment: seg)
    }

    /// Manual seek (tap-to-jump landing): pin the line at a surface offset.
    func pin(toSurfaceOffset surfaceOffset: Int) {
        advance(toSurfaceOffset: surfaceOffset, segment: surface.content.layout.segment(atSurfaceOffset: surfaceOffset))
    }

    private func advance(toSurfaceOffset surfaceOffset: Int, segment: SurfaceSegment?) {
        guard let line = surface.visualLine(forCharAt: surfaceOffset), line.range.length > 0 else { return }
        if let last = lastLineRange, NSEqualRanges(last, line.range) { return }   // dedup to line changes
        lastLineRange = line.range
        surface.setActiveLine(line.range)
        surface.glide(toRect: line.rect)
        onLineChange?(line.range, segment)
    }
}

// ========== BLOCK 01: READ-ALONG ENGINE (CORE SPINE) - END ==========
