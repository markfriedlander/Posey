import UIKit
import QuartzCore

// ========== BLOCK 01: READ-ALONG ENGINE (CORE SPINE) - START ==========

/// The read-along engine: given the spoken word's position, light its VISUAL LINE
/// and glide it to the focal point. Highlight + scroll-pin are two faces of one
/// engine, kept together.
///
/// It does NOT own the synthesizer. Posey's `SpeechPlaybackService` drives it — it
/// knows the playback-queue index of the spoken sentence and, via `willSpeakRange`,
/// the word offset within that sentence. The engine maps (playbackIndex, word
/// offset) → a surface offset. The surface/core never know which source is speaking.
///
/// ## Read-along modes (Mark, 2026-07-12)
/// - `.line` — move the highlight only when a real word-position report arrives.
///   Exact, but a voice that reports sparsely (Apple's premium/Siri voices go quiet
///   for stretches — measured 2026-07-12) leaves the highlight frozen until the next
///   report, then it jumps. The honest, no-estimation mode.
/// - `.glide` — same line highlight, but a display-link timer keeps nudging the
///   highlight FORWARD at the estimated reading pace to bridge the reporting gaps,
///   snapping to the true position whenever a report arrives. Forward-only (never
///   snaps backward) and biased to TRAIL the voice slightly so it sits just behind
///   and gets pulled forward, rather than running ahead. On a densely-reporting
///   voice the timer barely contributes — the real reports carry it.
/// - `.teleprompter` — handled at the glow-extent level (whole sentence); advancement
///   still rides the reports. (A dedicated presentation is a later stage.)
@MainActor
final class ReadAlongEngine {

    private let surface: ReaderSurface
    private var lastLineRange: NSRange?
    private var lastHighlightRange: NSRange?

    /// Fired on each line change (status / now-playing / observers).
    var onLineChange: ((_ lineRange: NSRange, _ segment: SurfaceSegment?) -> Void)?

    // ---- Glide state (only used in .glide mode) ----
    private var displayLink: CADisplayLink?
    /// True only while mode == .glide AND playback is live — the one condition under
    /// which the timer may advance the highlight (so it never moves while paused).
    private var glideActive = false
    private var glideSentenceIndex = -1
    private var glideSentenceRange = NSRange(location: 0, length: 0)
    /// The current (monotonic, forward-only) surface offset the highlight targets.
    private var glideOffset: Double = 0
    /// The last TRUE word position reported by the voice, and when it arrived.
    private var lastRealOffset: Double = 0
    private var lastRealTime: CFTimeInterval = 0
    /// Estimated speaking pace in characters/second (smoothed from real reports).
    private var glideRate = ReadAlongEngine.defaultRate

    /// ~150 wpm typical TTS ≈ 14 chars/sec including spaces — the starting estimate
    /// until real reports refine it. TUNING KNOB.
    private static let defaultRate: Double = 14
    /// Predict at a fraction of the measured pace so the glide TRAILS the voice and
    /// gets pulled forward by reports, never leading it. TUNING KNOB.
    private static let trailFactor: Double = 0.9
    private static let minRate: Double = 4
    private static let maxRate: Double = 45

    init(surface: ReaderSurface) { self.surface = surface }

    /// Playback started/stopped/seeked — next word re-pins fresh.
    func reset() {
        lastLineRange = nil
        lastHighlightRange = nil
        surface.setActiveLine(nil)
        resetGlideState()
    }

    /// The surface content was rebuilt (offsets changed) — drop stale glide anchors so
    /// a pending timer tick can't advance to an offset from the old layout. The next
    /// real report re-establishes them. Does not clear the visible highlight.
    func handleContentReload() {
        glideSentenceIndex = -1
    }

    /// The Coordinator reports the current mode + whether playback is live. The
    /// gliding timer runs ONLY while in `.glide` mode AND actually playing, so the
    /// highlight can never drift while paused.
    func updateGlide(mode: ReaderTuning.ReadAlongMode, isPlaying: Bool) {
        let shouldGlide = (mode == .glide) && isPlaying
        guard shouldGlide != glideActive else { return }
        glideActive = shouldGlide
        if shouldGlide { startDisplayLink() } else { stopDisplayLink() }
    }

    /// The voice is speaking the word at `wordOffset` characters into the sentence at
    /// playback index `playbackIndex`. In `.line`/`.teleprompter`, pin that word's
    /// line directly. In `.glide`, fold it in as the true anchor for the timer.
    func onSpokenWord(playbackIndex: Int, wordOffset: Int) {
        // Teleprompter advances per-SENTENCE (driven by the currentSentenceIndex
        // subscription in SurfaceReaderHost), so per-word reports don't move it.
        guard surface.tuning.readAlongMode != .teleprompter else { return }
        guard let seg = surface.content.layout.segment(forPlaybackIndex: playbackIndex) else { return }
        let realOffset = seg.range.location + max(0, min(wordOffset, seg.range.length - 1))
        if surface.tuning.readAlongMode == .glide {
            ingestRealReport(playbackIndex: playbackIndex, seg: seg, realOffset: realOffset)
        } else {
            advance(toSurfaceOffset: realOffset, segment: seg)
        }
    }

    /// Sentence-granular fallback (no word offset available): pin the sentence's
    /// first line. Used for pause/seek/initial-position (not live playback).
    func onSpokenSentence(playbackIndex: Int) {
        guard let seg = surface.content.layout.segment(forPlaybackIndex: playbackIndex) else { return }
        advance(toSurfaceOffset: seg.range.location, segment: seg)
    }

    /// Manual seek (tap-to-jump landing): pin the line at a surface offset.
    func pin(toSurfaceOffset surfaceOffset: Int) {
        advance(toSurfaceOffset: surfaceOffset, segment: surface.content.layout.segment(atSurfaceOffset: surfaceOffset))
    }

    /// Search: light EXACTLY the found substring and pin its line. Unlike
    /// `onSpokenSentence` — which anchors at the sentence's first character — search
    /// marks the matched text itself, wherever it sits in the sentence. A hit deep in
    /// a long sentence must glow on its own words, not on the sentence's opening. This
    /// is the honest find-in-page behavior.
    func highlightExactRange(_ range: NSRange) {
        guard let line = surface.visualLine(forCharAt: range.location), line.range.length > 0 else { return }
        let lineChanged = !(lastLineRange.map { NSEqualRanges($0, line.range) } ?? false)
        lastLineRange = line.range
        lastHighlightRange = range
        surface.setActiveLine(range)
        if lineChanged { surface.glide(toRect: line.rect) }
        onLineChange?(line.range, surface.content.layout.segment(atSurfaceOffset: range.location))
    }

    // ---- Glide internals ----

    /// Fold a true word report into the glide: reset on a new sentence, otherwise
    /// refine the pace estimate and pull the highlight forward to the true spot.
    private func ingestRealReport(playbackIndex: Int, seg: SurfaceSegment, realOffset: Int) {
        let now = CACurrentMediaTime()
        let realOffsetD = Double(realOffset)
        if playbackIndex != glideSentenceIndex {
            // New sentence — restart the glide from this sentence's start.
            glideSentenceIndex = playbackIndex
            glideSentenceRange = seg.range
            glideOffset = realOffsetD
            lastRealOffset = realOffsetD
            lastRealTime = now
        } else {
            // Same sentence — refine pace from this report vs the previous one.
            let dt = now - lastRealTime
            let dOffset = realOffsetD - lastRealOffset
            if dt > 0.02, dOffset > 0 {
                let inst = dOffset / dt
                glideRate = max(Self.minRate, min(Self.maxRate, 0.6 * glideRate + 0.4 * inst))
            }
            lastRealOffset = realOffsetD
            lastRealTime = now
            glideOffset = max(glideOffset, realOffsetD)   // forward-only pull
        }
        renderGlide(atOffset: Int(glideOffset), segment: seg)
    }

    @objc private nonisolated func glideTick(_ link: CADisplayLink) {
        let ts = link.timestamp
        MainActor.assumeIsolated { self.glideStep(now: ts) }
    }

    private func glideStep(now: CFTimeInterval) {
        guard glideActive, glideSentenceIndex >= 0 else { return }
        // Predict where the voice is now, biased to trail slightly, clamped so the
        // glide never wanders past the current sentence into the next one.
        let predicted = lastRealOffset + glideRate * Self.trailFactor * (now - lastRealTime)
        let sentenceEnd = Double(glideSentenceRange.location + max(0, glideSentenceRange.length - 1))
        let target = min(predicted, sentenceEnd)
        guard target > glideOffset else { return }   // forward-only
        glideOffset = target
        renderGlide(atOffset: Int(glideOffset),
                    segment: surface.content.layout.segment(atSurfaceOffset: Int(glideOffset)))
    }

    private func renderGlide(atOffset offset: Int, segment: SurfaceSegment?) {
        advance(toSurfaceOffset: offset, segment: segment)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(glideTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func resetGlideState() {
        stopDisplayLink()
        glideActive = false
        glideSentenceIndex = -1
        glideOffset = 0
        lastRealOffset = 0
        lastRealTime = 0
        glideRate = Self.defaultRate
    }

    @discardableResult
    private func advance(toSurfaceOffset surfaceOffset: Int, segment: SurfaceSegment?) -> Bool {
        guard let line = surface.visualLine(forCharAt: surfaceOffset), line.range.length > 0 else { return false }
        // All in-surface modes light the single visual LINE and pin it to the focal
        // point. (Teleprompter's full-screen one-sentence presentation is a separate
        // overlay — see `TeleprompterView`; here it just keeps the hidden page synced
        // to the current sentence so the right spot shows when playback stops.)
        let highlight = line.range
        let lineChanged = !(lastLineRange.map { NSEqualRanges($0, line.range) } ?? false)
        let highlightChanged = !(lastHighlightRange.map { NSEqualRanges($0, highlight) } ?? false)
        guard lineChanged || highlightChanged else { return false }
        lastLineRange = line.range
        lastHighlightRange = highlight
        surface.setActiveLine(highlight)
        if lineChanged { surface.glide(toRect: line.rect) }   // only re-glide on line change → no per-word jitter
        onLineChange?(line.range, segment)
        return true
    }
}

// ========== BLOCK 01: READ-ALONG ENGINE (CORE SPINE) - END ==========
