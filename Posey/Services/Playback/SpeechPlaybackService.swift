import AVFoundation
import Combine
import Foundation

// ========== BLOCK 01: TYPES AND CONSTANTS - START ==========
@MainActor
final class SpeechPlaybackService: NSObject, ObservableObject {

    /// Whether to use the real AVSpeechSynthesizer or a deterministic timer (tests only).
    enum Mode: Equatable {
        case system
        case simulated(stepInterval: TimeInterval)
    }

    /// Voice quality mode.
    ///
    /// - bestAvailable: prefersAssistiveTechnologySettings = true. Siri-quality voice.
    ///   utterance.rate is NOT set — the system Spoken Content rate slider applies.
    /// - custom: Specific voice from AVSpeechSynthesisVoice.speechVoices() with explicit
    ///   in-app rate control. Lower quality than bestAvailable, but fully user-controlled.
    enum VoiceMode: Equatable {
        case bestAvailable
        case custom(voiceIdentifier: String, rate: Float)
    }

    enum PlaybackState: Equatable {
        case idle
        case playing
        case paused
        case finished
    }

    /// The word the synthesizer is speaking RIGHT NOW: which sentence (`index`, the
    /// playback-queue index == `currentSentenceIndex`) and how many characters into
    /// that sentence's spoken text the word starts (`wordOffset`). Published from
    /// `willSpeakRange` so the reader's read-along can light the exact VISUAL LINE the
    /// voice is on and glide it to the focal point — true line-level sync through a
    /// multi-line sentence (Mark's single-point-of-gaze). `wordOffset` indexes the
    /// SPOKEN text (list markers stripped, any visual-announcement prefix included), so
    /// it matches the sentence text exactly for prose; list/announcement rows can be
    /// off by the stripped/prepended length — acceptable, prose is the dominant case.
    struct SpokenWord: Equatable, Sendable {
        let index: Int
        let wordOffset: Int
    }

    /// Utterances to keep queued ahead of the current position.
    private static let windowSize = 50

    // ========== BLOCK 01: TYPES AND CONSTANTS - END ==========

    // ========== BLOCK 02: PROPERTIES AND INIT - START ==========

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentSentenceIndex: Int?
    /// The word currently being spoken (sentence index + intra-sentence char offset).
    /// Drives line-level read-along. nil when idle/paused/stopped.
    @Published private(set) var spokenWord: SpokenWord?

    /// The current spoken CHUNK's text, for Teleprompter mode (one card per chunk).
    /// Published on each chunk's `didStart`; nil when idle/paused/stopped or not
    /// chunking. Line/Glide leave this nil (they speak whole sentences).
    @Published private(set) var currentChunk: String?

    private let synthesizer = AVSpeechSynthesizer()
    private let mode: Mode
    private(set) var voiceMode: VoiceMode

    /// Utterance ID → sentence index, for the window currently in the synthesizer queue.
    private var sentenceIndicesByUtteranceID: [ObjectIdentifier: Int] = [:]
    /// Utterance ID → chunk info (Teleprompter): the chunk's display text + whether it
    /// is the LAST chunk of its sentence. `didFinish` advances to the next sentence
    /// only after a sentence's final chunk, so mid-sentence chunks don't over-fill.
    private var chunkInfoByUtteranceID: [ObjectIdentifier: (text: String, isLast: Bool)] = [:]
    /// When set (Teleprompter mode), each sentence is spoken as capped chunks — each
    /// chunk its own utterance AND display card. nil = whole sentences (Line / Glide).
    var teleprompterChunkMaxChars: Int?
    /// Full segment array for the active document.
    private var activeSegments: [TextSegment] = []

    /// 2026-05-13 (A1) — sidecar map: sentence index → announcement text to
    /// prepend when speaking that segment. Populated by the ReaderViewModel
    /// in Motion reading style for sentences that follow a visualPlaceholder.
    /// The announcement reads as the start of the same utterance ("Image.
    /// First sentence after the image...") so playback flows without an
    /// extra pause, accomplishing Mark's Motion-mode spec: image displays
    /// inline, TTS says "Image", playback continues without stopping.
    /// Empty in non-Motion modes (where the visual block triggers a pause
    /// via `pauseForVisualBlockIfNeeded` instead).
    var visualAnnouncementText: [Int: String] = [:]
    // [DECISION Mark 2026-06-30] The page-break audible beat was removed: PDF
    // page markers are now invisible (see SurfaceBuilder .pageBreak) and PDFs
    // read as continuous flow like every other format — so there is no audible
    // page-turn pause either. The former `pageBreakPauseSentenceIndices` +
    // `pageBreakPreUtteranceDelay` mechanism is gone entirely.
    /// Next segment index to feed into the synthesizer window.
    private var nextEnqueueIndex: Int = 0

    /// 2026-06-15 — Segment indices the playback head GLIDES PAST without
    /// speaking (Mark's "move the head to the other side of the table like
    /// an image"). DOCX `.table` units are rendered as an image but keep
    /// their text as sentences so search / Ask-Posey still find them; those
    /// sentence/segment indices are listed here so TTS skips them while the
    /// index space (used by read-along highlight + search) stays intact.
    /// The head advances from the segment before the table straight to the
    /// first segment after it. Empty for the common case. Set by the
    /// ReaderViewModel at content-load.
    var skipSegmentIndices: Set<Int> = []

    private var simulatedSegments: [TextSegment] = []
    private var simulatedTimer: Timer?
    private var audioSessionObservers: [NSObjectProtocol] = []

    init(mode: Mode = .system, voiceMode: VoiceMode = .bestAvailable) {
        self.mode = mode
        self.voiceMode = voiceMode
        super.init()
        synthesizer.delegate = self
        // 2026-05-04 — Use the app's audio session, not the system
        // accessibility/spoken-content session. AVSpeechSynthesizer
        // defaults to routing through the system spoken-content
        // session which doesn't honor our `.playback` background
        // configuration — that's why playback was stopping when
        // Mark locked the screen. With usesApplicationAudioSession
        // = true, the synthesizer respects the .playback session
        // we configure (with `audio` UIBackgroundMode), so playback
        // continues with the screen locked AND the lock-screen
        // controls (already wired via NowPlayingController +
        // MPRemoteCommandCenter) become functional.
        synthesizer.usesApplicationAudioSession = true
        configureAudioSessionIfNeeded()
    }

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // ========== BLOCK 02: PROPERTIES AND INIT - END ==========

    // ========== BLOCK 03: PUBLIC API - START ==========

    func prepare(at sentenceIndex: Int) {
        currentSentenceIndex = sentenceIndex
        if state == .finished {
            state = .idle
        }
    }

    /// Apply a new voice mode, taking effect immediately.
    ///
    /// If currently playing: stops and re-enqueues from current position with new settings.
    /// If paused: stops synthesizer and returns to idle so the next play uses new settings.
    /// If idle/finished: stores the mode for next play.
    func applyVoiceMode(_ newMode: VoiceMode) {
        guard newMode != voiceMode else { return }
        voiceMode = newMode
        guard state == .playing || state == .paused else { return }
        let resumeIndex = currentSentenceIndex ?? 0
        let wasPlaying = state == .playing
        stopSynthesizer()
        if wasPlaying {
            enqueueWindow(startingAt: resumeIndex)
            state = .playing
        }
        // If was paused: state is now idle, currentSentenceIndex preserved.
        // User taps play to resume with new settings.
    }

    /// Set (or clear) Teleprompter chunking (max characters per chunk; nil = whole
    /// sentences). Takes effect immediately: if playing, re-enqueues from the current
    /// sentence so the cards/chunks match the new mode right away.
    func applyTeleprompterChunking(_ maxChars: Int?) {
        guard teleprompterChunkMaxChars != maxChars else { return }
        teleprompterChunkMaxChars = maxChars
        guard state == .playing || state == .paused else { return }
        let resumeIndex = currentSentenceIndex ?? 0
        let wasPlaying = state == .playing
        stopSynthesizer()
        if wasPlaying {
            enqueueWindow(startingAt: resumeIndex)
            state = .playing
        }
    }

    func play(segments: [TextSegment], startingAt startIndex: Int) {
        playInternal(segments: segments, startingAt: startIndex, shouldResumeIfPaused: true)
    }

    func restart(segments: [TextSegment], startingAt startIndex: Int) {
        playInternal(segments: segments, startingAt: startIndex, shouldResumeIfPaused: false)
    }

    /// Smallest index `>= from` that is in-bounds and NOT skipped — the next
    /// segment the head may actually speak. nil when the rest are all skipped
    /// (or out of range). Drives the glide-past-table behavior.
    private func firstPlayable(from index: Int) -> Int? {
        var i = max(0, index)
        while i < activeSegments.count {
            if !skipSegmentIndices.contains(i) { return i }
            i += 1
        }
        return nil
    }

    func pause() {
        switch mode {
        case .system:
            // 2026-05-13 (A1) — published state now reflects the user's
            // INTENT to pause, not just whether the synthesizer happened
            // to be mid-utterance at this exact moment.
            //
            // Background: pauseForVisualBlockIfNeeded fires when the
            // sentence index advances to one that follows a visual
            // placeholder. That transition often happens BETWEEN
            // utterances (after sentence N finished, before sentence
            // N+1 starts), where `synthesizer.isSpeaking` returns
            // false. The earlier code guarded on isSpeaking and
            // returned early, leaving state as `.playing` even though
            // playback was effectively halted. The Continue button on
            // the inline visualPlaceholder gated on state == .paused
            // and never appeared. Fixed by always setting state to
            // `.paused` and calling pauseSpeaking when applicable.
            // .immediate halts mid-word, which feels truly
            // responsive to a tap. .word would wait for the next word
            // boundary — hundreds of ms on Siri-tier voices, long
            // enough to feel broken. Reading apps resume from the
            // saved sentence anyway, so a clean cut beats a polished-
            // sounding lag.
            if synthesizer.isSpeaking {
                synthesizer.pauseSpeaking(at: .immediate)
            }
            state = .paused
        case .simulated:
            guard state == .playing else { return }
            invalidateSimulatedTimer()
            state = .paused
        }
    }

    func stop() {
        stopSynthesizer()
        invalidateSimulatedTimer()
        simulatedSegments = []
        activeSegments = []
    }

    /// 2026-05-07 (parity #8): test-only state forcer. Lets the
    /// antenna drive transitions that are otherwise hard to set up
    /// (e.g. `.finished` from natural end-of-doc, which would
    /// require playing through the whole document). Public on
    /// purpose — there's no harm in exposing this beyond debug
    /// builds since real users have no way to trigger the antenna.
    func debugForceState(_ newState: PlaybackState) {
        state = newState
    }

    // ========== BLOCK 03: PUBLIC API - END ==========

    // ========== BLOCK 04: SYSTEM PLAYBACK - START ==========

    private func playInternal(
        segments: [TextSegment],
        startingAt startIndex: Int,
        shouldResumeIfPaused: Bool
    ) {
        guard segments.isEmpty == false else { return }
        activeSegments = segments

        switch mode {
        case .system:
            if shouldResumeIfPaused, state == .paused, synthesizer.isPaused {
                synthesizer.continueSpeaking()
                state = .playing
                return
            }
        case .simulated:
            if shouldResumeIfPaused, state == .paused, simulatedTimer == nil {
                scheduleSimulatedPlayback(stepInterval: simulatedStepInterval)
                state = .playing
                return
            }
        }

        stopSynthesizer()
        invalidateSimulatedTimer()

        let requested = min(max(startIndex, 0), segments.count - 1)
        // Snap forward past any skipped (table) segments so we never START
        // the head on a unit we mean to glide past. If nothing from here on
        // is playable (e.g. a doc that is only a table), finish cleanly
        // rather than sit in `.playing` with an empty queue.
        guard let boundedIndex = firstPlayable(from: requested) else {
            currentSentenceIndex = requested
            state = .finished
            return
        }
        currentSentenceIndex = boundedIndex

        switch mode {
        case .system:
            activateAudioSessionIfNeeded()
            enqueueWindow(startingAt: boundedIndex)
            state = .playing
        case .simulated:
            simulatedSegments = Array(segments)
            state = .playing
            scheduleSimulatedPlayback(stepInterval: effectiveSimulatedStepInterval)
        }
    }

    /// Fills the synthesizer queue with up to windowSize utterances starting
    /// at startIndex, GLIDING PAST any skipped (table) segments.
    private func enqueueWindow(startingAt startIndex: Int) {
        nextEnqueueIndex = startIndex
        var enqueued = 0
        while enqueued < Self.windowSize, let index = firstPlayable(from: nextEnqueueIndex) {
            enqueueOneSegment(at: index)   // sets nextEnqueueIndex = index + 1
            enqueued += 1
        }
    }

    /// Builds the utterance(s) for the segment at index and adds them to the queue.
    /// In Teleprompter mode the segment is split into capped CHUNKS, each its own
    /// utterance (spoken back-to-back) so a display card advances on the reliable
    /// per-utterance signal; otherwise it's one utterance for the whole sentence.
    /// All chunks map to the SAME sentence id, so the position model is unchanged.
    private func enqueueOneSegment(at index: Int) {
        guard activeSegments.indices.contains(index) else { return }
        let segment = activeSegments[index]
        let base = spokenText(for: segment)
        let pieces: [String] = teleprompterChunkMaxChars
            .map { SentenceChunker.chunks(base, maxChars: $0) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? [base]
        for (ci, piece) in pieces.enumerated() {
            let utterance = makeUtterance(text: piece)
            let oid = ObjectIdentifier(utterance)
            sentenceIndicesByUtteranceID[oid] = segment.id
            chunkInfoByUtteranceID[oid] = (text: piece, isLast: ci == pieces.count - 1)
            // 2026-05-12 — record the actual string passed to AVSpeechSynthesizer
            // so PLAYBACK_STOP_BLOCK_TEST can verify no "Visual content on page N"
            // placeholder text ever reaches TTS. DEBUG-only; Release stub is no-op.
            RemoteControlState.shared.recordSpokenUtterance(piece)
            synthesizer.speak(utterance)
        }
        nextEnqueueIndex = index + 1
    }

    /// Builds the spoken text for a segment, prepending any
    /// visual-announcement prefix the ReaderViewModel set on this
    /// sentence index. The base utteranceText strips list markers
    /// (• / 1. ); the announcement prefix is added BEFORE that
    /// stripped text so it reads as "Image. <sentence>".
    private func spokenText(for segment: TextSegment) -> String {
        let base = SpeechPlaybackService.utteranceText(for: segment.text)
        if let prefix = visualAnnouncementText[segment.id], !prefix.isEmpty {
            return "\(prefix) \(base)"
        }
        return base
    }

    /// Constructs a mode-aware utterance for already-prepared spoken text. This is the
    /// single place voice mode is applied.
    private func makeUtterance(text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        switch voiceMode {
        case .bestAvailable:
            utterance.prefersAssistiveTechnologySettings = true
            // Do NOT set utterance.rate — the system Spoken Content rate slider applies.
        case .custom(let voiceIdentifier, let rate):
            utterance.prefersAssistiveTechnologySettings = false
            utterance.rate = rate
            if let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            }
        }
        return utterance
    }

    /// 2026-05-06 (parity #4) — Strip leading list markers before
    /// AVSpeechSynthesizer ever sees them. The reader displays `• `
    /// and `1. ` prefixes for visual list parity across formats, but
    /// the audio path should not pronounce them: AVSpeechSynthesizer's
    /// behavior on `•` and `1.` patterns is undocumented (researched
    /// against Apple docs, WWDC 2018, NSHipster, etc. — all silent on
    /// per-character behavior). Per DECISIONS.md "List markers" we
    /// strip at the speech boundary so the audio experience is
    /// guaranteed clean regardless of what AVSpeechSynthesizer would
    /// otherwise do.
    ///
    /// Strip is leading-anchor only: a sentence whose body talks
    /// about bullet points or numbered steps in prose still pronounces
    /// those characters normally. Only the marker prefix at the start
    /// of an utterance is removed.
    static func utteranceText(for source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"^(?:•|\d+\.)\s+"#
        ) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source, range: range, withTemplate: ""
        )
    }

    /// Stops the synthesizer and clears the utterance tracking map.
    /// Does not clear activeSegments — those are preserved for re-enqueue on mode change.
    private func stopSynthesizer() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        sentenceIndicesByUtteranceID.removeAll()
        chunkInfoByUtteranceID.removeAll()
        spokenWord = nil
        currentChunk = nil
        if state != .finished {
            state = .idle
        }
    }

    // ========== BLOCK 04: SYSTEM PLAYBACK - END ==========

    // ========== BLOCK 05: SIMULATED PLAYBACK - START ==========

    private var simulatedStepInterval: TimeInterval {
        switch mode {
        case .system: return 0.2
        case .simulated(let stepInterval): return stepInterval
        }
    }

    private var effectiveSimulatedStepInterval: TimeInterval {
        switch voiceMode {
        case .bestAvailable:
            return simulatedStepInterval
        case .custom(_, let rate):
            let normalizedRate = max(Double(rate), 0.1)
            let defaultRate = Double(AVSpeechUtteranceDefaultSpeechRate)
            return max(0.05, simulatedStepInterval * (defaultRate / normalizedRate))
        }
    }

    private func scheduleSimulatedPlayback(stepInterval: TimeInterval) {
        invalidateSimulatedTimer()
        simulatedTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceSimulatedPlayback()
            }
        }
    }

    private func advanceSimulatedPlayback() {
        guard let currentSentenceIndex else {
            invalidateSimulatedTimer()
            state = .finished
            return
        }
        // Glide past skipped (table) segments here too, so simulated/DEBUG
        // playback matches the system path.
        if let nextIndex = firstPlayable(from: currentSentenceIndex + 1) {
            self.currentSentenceIndex = nextIndex
        } else {
            invalidateSimulatedTimer()
            state = .finished
        }
    }

    private func invalidateSimulatedTimer() {
        simulatedTimer?.invalidate()
        simulatedTimer = nil
    }

    // ========== BLOCK 05: SIMULATED PLAYBACK - END ==========

    // ========== BLOCK 06: AUDIO SESSION - START ==========

    private func configureAudioSessionIfNeeded() {
        guard case .system = mode else { return }
        #if os(iOS)
        applyAudioSessionCategory()
        let center = NotificationCenter.default
        audioSessionObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleAudioSessionInterruption(rawValue: rawValue)
                }
            }
        )
        #endif
    }

    /// 2026-05-04 — Audio session category for read-aloud playback.
    /// `.playback` + `.spokenAudio` + `.interruptSpokenAudioAndMixWithOthers`:
    /// background audio works (with the UIBackgroundModes audio
    /// entitlement injected by the post-Resources Run Script
    /// build phase), and other non-spoken audio (music, podcasts)
    /// can play alongside.
    /// Lock Screen / Dynamic Island controls do NOT show in this
    /// configuration because the system doesn't surface now-playing
    /// controls for mixable sessions. We tried switching to a
    /// non-mixing `.solo`-style configuration to get the controls
    /// back; controls appeared but audio stopped after the queued
    /// utterance window finished and metadata cleared (likely
    /// SwiftUI deinit'ing ReaderViewModel on background, OR an
    /// AVSpeechSynthesizer + non-mixing-session interaction we
    /// haven't fully traced). Reverted to mixable here for 1.0;
    /// background playback works without controls. Lock-screen
    /// controls are deferred to a future release pass.
    private func applyAudioSessionCategory() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.interruptSpokenAudioAndMixWithOthers])
        } catch {
            assertionFailure("Failed to configure AVAudioSession: \(error)")
        }
        #endif
    }

    private func activateAudioSessionIfNeeded() {
        guard case .system = mode else { return }
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            assertionFailure("Failed to activate AVAudioSession: \(error)")
        }
        #endif
    }

    private func handleAudioSessionInterruption(rawValue: UInt?) {
        guard case .system = mode,
              let rawValue,
              let interruptionType = AVAudioSession.InterruptionType(rawValue: rawValue)
        else { return }
        // 2026-05-04 — Diagnostic for lock-screen playback issue.
        // Mark reports playback dies on screen lock. The most likely
        // surface for that is an audio-session interruption fired
        // when the screen locks — but for `.playback` category,
        // screen lock SHOULDN'T cause an interruption per Apple's
        // docs. Logging which path actually fires so we can see
        // tomorrow whether the lock is producing an interruption
        // (and we should suppress pause() for it) or whether
        // something else entirely is killing playback.
        switch interruptionType {
        case .began:
            dbgLog("[POSEY_PLAYBACK] AVAudioSession interruption began (state=\(state))")
            if state == .playing { pause() }
        case .ended:
            dbgLog("[POSEY_PLAYBACK] AVAudioSession interruption ended")
        @unknown default:
            dbgLog("[POSEY_PLAYBACK] AVAudioSession interruption unknown type: \(rawValue)")
        }
    }

    // ========== BLOCK 06: AUDIO SESSION - END ==========
}

// ========== BLOCK 07: DELEGATE - START ==========
extension SpeechPlaybackService: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            // 2026-05-13 (A1) — set state BEFORE currentSentenceIndex.
            // Why: subscribers to $currentSentenceIndex
            // (ReaderViewModel.pauseForVisualBlockIfNeeded) may call
            // playbackService.pause() synchronously during their sink.
            // If we set state = .playing AFTER currentSentenceIndex,
            // the pause's state mutation to .paused gets overwritten
            // when the Task continues. Setting state first means
            // pauseForVisualBlockIfNeeded sees state == .playing
            // (correctly — the synthesizer DID just start utterance),
            // calls pause(), pause sets state = .paused, and nothing
            // overwrites it after.
            self.state = .playing
            self.currentSentenceIndex = self.sentenceIndicesByUtteranceID[utteranceID]
            self.currentChunk = self.chunkInfoByUtteranceID[utteranceID]?.text
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let index = self.sentenceIndicesByUtteranceID[utteranceID] else { return }
            self.spokenWord = SpokenWord(index: index, wordOffset: characterRange.location)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            let wasLastChunk = self.chunkInfoByUtteranceID[utteranceID]?.isLast ?? true
            self.sentenceIndicesByUtteranceID.removeValue(forKey: utteranceID)
            self.chunkInfoByUtteranceID.removeValue(forKey: utteranceID)
            // Advance the sliding window only after a sentence's FINAL chunk — a
            // sentence's earlier chunks (Teleprompter) are already queued. For whole
            // sentences every utterance is the "last chunk", so behavior is unchanged.
            guard wasLastChunk else { return }
            // Extend the sliding window: enqueue one more PLAYABLE segment
            // (gliding past skipped/table segments) if available.
            if let index = self.firstPlayable(from: self.nextEnqueueIndex) {
                self.enqueueOneSegment(at: index)
            } else if self.sentenceIndicesByUtteranceID.isEmpty {
                // No more to enqueue and all tracked utterances are done.
                self.state = .finished
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        // 2026-05-04 — Diagnostic for the lock-screen-stops-playback
        // issue. didCancel fires when an utterance is cancelled
        // before completing — could indicate iOS killing speech on
        // background, an interruption-driven stop, or our own
        // stopSynthesizer() call. Logging so tomorrow we can see
        // who's killing playback when the screen locks.
        dbgLog("[POSEY_PLAYBACK] AVSpeechSynthesizer didCancel utterance")
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            // Cleanup only. State transitions are managed by stopSynthesizer()/applyVoiceMode.
            self.sentenceIndicesByUtteranceID.removeValue(forKey: utteranceID)
        }
    }
}
// ========== BLOCK 07: DELEGATE - END ==========
