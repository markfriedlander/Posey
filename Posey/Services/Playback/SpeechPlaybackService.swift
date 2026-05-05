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

    /// Utterances to keep queued ahead of the current position.
    private static let windowSize = 50

    // ========== BLOCK 01: TYPES AND CONSTANTS - END ==========

    // ========== BLOCK 02: PROPERTIES AND INIT - START ==========

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentSentenceIndex: Int?

    private let synthesizer = AVSpeechSynthesizer()
    private let mode: Mode
    private(set) var voiceMode: VoiceMode

    /// Utterance ID → sentence index, for the window currently in the synthesizer queue.
    private var sentenceIndicesByUtteranceID: [ObjectIdentifier: Int] = [:]
    /// Full segment array for the active document.
    private var activeSegments: [TextSegment] = []
    /// Next segment index to feed into the synthesizer window.
    private var nextEnqueueIndex: Int = 0

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

    func play(segments: [TextSegment], startingAt startIndex: Int) {
        playInternal(segments: segments, startingAt: startIndex, shouldResumeIfPaused: true)
    }

    func restart(segments: [TextSegment], startingAt startIndex: Int) {
        playInternal(segments: segments, startingAt: startIndex, shouldResumeIfPaused: false)
    }

    func pause() {
        switch mode {
        case .system:
            guard synthesizer.isSpeaking else { return }
            // .immediate halts the synthesizer mid-word, which feels truly
            // responsive to a tap. .word waits for the next word boundary,
            // which on the Best Available (Siri-tier) audio path can take
            // hundreds of ms — long enough to feel broken. Reading apps
            // resume from the saved sentence anyway, so a clean cut is
            // preferable to a polished-sounding lag.
            if synthesizer.pauseSpeaking(at: .immediate) {
                state = .paused
            }
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

        let boundedIndex = min(max(startIndex, 0), segments.count - 1)
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

    /// Fills the synthesizer queue with up to windowSize utterances starting at startIndex.
    private func enqueueWindow(startingAt startIndex: Int) {
        nextEnqueueIndex = startIndex
        let endIndex = min(startIndex + Self.windowSize, activeSegments.count)
        for index in startIndex..<endIndex {
            enqueueOneSegment(at: index)
        }
    }

    /// Builds one utterance from the segment at index and adds it to the synthesizer queue.
    private func enqueueOneSegment(at index: Int) {
        guard activeSegments.indices.contains(index) else { return }
        let segment = activeSegments[index]
        let utterance = makeUtterance(for: segment)
        sentenceIndicesByUtteranceID[ObjectIdentifier(utterance)] = segment.id
        synthesizer.speak(utterance)
        nextEnqueueIndex = index + 1
    }

    /// Constructs a mode-aware utterance. This is the single place voice mode is applied.
    private func makeUtterance(for segment: TextSegment) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: segment.text)
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

    /// Stops the synthesizer and clears the utterance tracking map.
    /// Does not clear activeSegments — those are preserved for re-enqueue on mode change.
    private func stopSynthesizer() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        sentenceIndicesByUtteranceID.removeAll()
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
        let nextIndex = currentSentenceIndex + 1
        if simulatedSegments.indices.contains(nextIndex) {
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
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.interruptSpokenAudioAndMixWithOthers])
        } catch {
            assertionFailure("Failed to configure AVAudioSession: \(error)")
        }
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
            self.currentSentenceIndex = self.sentenceIndicesByUtteranceID[utteranceID]
            self.state = .playing
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.sentenceIndicesByUtteranceID.removeValue(forKey: utteranceID)
            // Extend the sliding window: enqueue one more segment if available.
            if self.nextEnqueueIndex < self.activeSegments.count {
                self.enqueueOneSegment(at: self.nextEnqueueIndex)
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
