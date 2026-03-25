import AVFoundation
import Combine
import Foundation

@MainActor
final class SpeechPlaybackService: NSObject, ObservableObject {
    enum Mode: Equatable {
        case system
        case simulated(stepInterval: TimeInterval)
    }

    enum PlaybackState: Equatable {
        case idle
        case playing
        case paused
        case finished
    }

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentSentenceIndex: Int?

    private let synthesizer = AVSpeechSynthesizer()
    private let mode: Mode
    private var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var voiceIdentifier: String?
    private var sentenceIndicesByUtteranceID: [ObjectIdentifier: Int] = [:]
    private var simulatedSegments: [TextSegment] = []
    private var activeSegments: [TextSegment] = []
    private var simulatedTimer: Timer?
    private var audioSessionObservers: [NSObjectProtocol] = []

    init(mode: Mode = .system) {
        self.mode = mode
        super.init()
        synthesizer.delegate = self
        configureAudioSessionIfNeeded()
    }

    func prepare(at sentenceIndex: Int) {
        currentSentenceIndex = sentenceIndex
        if state == .finished {
            state = .idle
        }
    }

    func setSpeechRate(_ rate: Float) {
        speechRate = rate
    }

    func setVoiceIdentifier(_ identifier: String?) {
        voiceIdentifier = identifier
    }

    func play(segments: [TextSegment], startingAt startIndex: Int) {
        play(segments: segments, startingAt: startIndex, shouldResumeIfPaused: true)
    }

    func restart(segments: [TextSegment], startingAt startIndex: Int) {
        play(segments: segments, startingAt: startIndex, shouldResumeIfPaused: false)
    }

    private func play(segments: [TextSegment], startingAt startIndex: Int, shouldResumeIfPaused: Bool) {
        guard segments.isEmpty == false else {
            return
        }

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

        stop()

        let boundedIndex = min(max(startIndex, 0), segments.count - 1)
        currentSentenceIndex = boundedIndex

        switch mode {
        case .system:
            enqueueSystemPlayback(segments: segments, startingAt: boundedIndex)
        case .simulated:
            simulatedSegments = Array(segments)
            state = .playing
            scheduleSimulatedPlayback(stepInterval: effectiveSimulatedStepInterval)
        }
    }

    private func enqueueSystemPlayback(segments: [TextSegment], startingAt startIndex: Int) {
        activateAudioSessionIfNeeded()

        for segment in segments[startIndex...] {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.prefersAssistiveTechnologySettings = true
            utterance.rate = speechRate
            if let resolvedVoice = preferredVoice() {
                utterance.voice = resolvedVoice
            }
            sentenceIndicesByUtteranceID[ObjectIdentifier(utterance)] = segment.id
            synthesizer.speak(utterance)
        }
        state = .playing
    }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return voice
        }

        return nil
    }

    func pause() {
        switch mode {
        case .system:
            guard synthesizer.isSpeaking else {
                return
            }

            if synthesizer.pauseSpeaking(at: .word) {
                state = .paused
            }
        case .simulated:
            guard state == .playing else {
                return
            }
            invalidateSimulatedTimer()
            state = .paused
        }
    }

    func stop() {
        invalidateSimulatedTimer()
        simulatedSegments = []
        activeSegments = []

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        sentenceIndicesByUtteranceID.removeAll()
        if state != .finished {
            state = .idle
        }
    }

    private func configureAudioSessionIfNeeded() {
        guard case .system = mode else {
            return
        }

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
        guard case .system = mode else {
            return
        }

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
              let interruptionType = AVAudioSession.InterruptionType(rawValue: rawValue) else {
            return
        }

        switch interruptionType {
        case .began:
            if state == .playing {
                pause()
            }
        case .ended:
            break
        @unknown default:
            break
        }
    }

    private var simulatedStepInterval: TimeInterval {
        switch mode {
        case .system:
            return 0.2
        case .simulated(let stepInterval):
            return stepInterval
        }
    }

    private var effectiveSimulatedStepInterval: TimeInterval {
        let normalizedRate = max(Double(speechRate), 0.1)
        return max(0.05, simulatedStepInterval * (Double(AVSpeechUtteranceDefaultSpeechRate) / normalizedRate))
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

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

extension SpeechPlaybackService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.currentSentenceIndex = self.sentenceIndicesByUtteranceID[utteranceID]
            self.state = .playing
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        let shouldFinish = synthesizer.isSpeaking == false && synthesizer.isPaused == false

        Task { @MainActor in
            self.sentenceIndicesByUtteranceID.removeValue(forKey: utteranceID)
            if shouldFinish {
                self.state = .finished
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)

        Task { @MainActor in
            self.sentenceIndicesByUtteranceID.removeValue(forKey: utteranceID)
            if self.state != .finished {
                self.state = .idle
            }
        }
    }
}
