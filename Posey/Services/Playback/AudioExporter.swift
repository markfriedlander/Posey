import AVFoundation
import Combine
import Foundation

// ========== BLOCK 01: TYPES + ERRORS - START ==========
/// State of an in-flight audio export. Drives the UI progress view.
enum AudioExportState: Equatable, Sendable {
    case idle
    case rendering(progress: Double, currentSegmentIndex: Int, totalSegments: Int)
    case finished(fileURL: URL)
    case failed(reason: String)
}

/// Errors the audio exporter throws — distinguished so the UI can
/// surface "switch to Custom voice" specifically when AFM/Siri-tier
/// voices refuse to render to a buffer.
enum AudioExportError: LocalizedError, Sendable {
    /// `AVSpeechSynthesizer.write(_:toBufferCallback:)` produced no
    /// audio buffers. Empirically this means the chosen voice is
    /// gated from third-party capture (Best Available / Siri-tier
    /// voices typically are). UI surfaces "switch to Custom voice."
    case voiceNotCapturable
    /// File system / AVAudioFile setup failed.
    case audioFileSetupFailed(String)
    /// User cancelled while rendering.
    case cancelled
    /// 2026-05-13 — iOS expired the `beginBackgroundTask` window
    /// while the render was still in flight. The UI distinguishes
    /// this from user-cancel so the failure notification reads
    /// "Couldn't finish in the background" instead of the misleading
    /// "Export cancelled."
    case backgroundTimeExpired
    /// Anything else from AVFoundation we couldn't classify.
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .voiceNotCapturable:
            return "Best Available voices can't be captured to audio files. Switch to Custom voice in Preferences and try again."
        case .audioFileSetupFailed(let s):
            return "Couldn't create the audio file: \(s)"
        case .cancelled:
            return "Export cancelled."
        case .backgroundTimeExpired:
            return "Posey couldn't finish exporting in the background. Open Posey and try again — staying in the app keeps it running."
        case .unknown(let s):
            return "Audio export failed: \(s)"
        }
    }
}
// ========== BLOCK 01: TYPES + ERRORS - END ==========


// ========== BLOCK 02: AUDIO EXPORTER - START ==========
/// Renders a document's text segments to an M4A audio file via
/// `AVSpeechSynthesizer.write(_:toBufferCallback:)`. M8 audio export
/// per `NEXT.md` and `DECISIONS.md`. Honors the user's voice
/// selection from `PlaybackPreferences`; the Best-Available
/// capture investigation runs at render time — we attempt the write
/// and detect when no buffers come back, surfacing a clear error.
///
/// **Threading.** `@MainActor` because state changes drive a SwiftUI
/// progress view. The actual buffer capture runs on the synthesizer's
/// own queue (we hop to main inside the callback) but the public
/// API is main-thread.
///
/// **Lifecycle.** Created when the user kicks off an export, lives
/// until either completion or cancellation. Holds an
/// `AVSpeechSynthesizer` (separate from the playback service's so
/// concurrent reading + export don't collide on one synthesizer).
@MainActor
final class AudioExporter: NSObject, ObservableObject {

    @Published private(set) var state: AudioExportState = .idle

    /// Task 7 (2026-05-03): voice mode the current render is using.
    /// Surfaced via the AudioExportSheet so the user can see which
    /// voice the .m4a will be rendered with — especially useful
    /// when their playback voice is Best Available and the export
    /// auto-falls-back to a capturable Custom voice.
    var exportingVoiceMode: SpeechPlaybackService.VoiceMode? { voiceModeOptional }
    private var voiceModeOptional: SpeechPlaybackService.VoiceMode?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioFile: AVAudioFile?
    private var segments: [TextSegment] = []
    private var currentIndex: Int = 0
    private var totalSegments: Int = 0
    private var voiceMode: SpeechPlaybackService.VoiceMode = .bestAvailable
    private var outputURL: URL?
    private var receivedAnyBuffer: Bool = false
    private var continuation: CheckedContinuation<URL, Error>?
    private var didFinish: Bool = false

    /// Render `segments` to an M4A at a temp file URL. Returns the
    /// resulting URL on success; throws on failure or cancellation.
    /// The caller is responsible for moving the file to its final
    /// destination (Files app, share sheet, etc.).
    func render(
        segments: [TextSegment],
        voiceMode: SpeechPlaybackService.VoiceMode,
        outputDirectory: URL? = nil,
        documentTitle: String = "Posey Export"
    ) async throws -> URL {
        guard !segments.isEmpty else {
            throw AudioExportError.unknown("No text to export.")
        }
        self.segments = segments
        self.totalSegments = segments.count
        self.currentIndex = 0
        self.voiceMode = voiceMode
        self.voiceModeOptional = voiceMode
        self.receivedAnyBuffer = false
        self.didFinish = false

        let dir = outputDirectory ?? FileManager.default.temporaryDirectory
        let safeTitle = documentTitle.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(safeTitle).m4a")
        try? FileManager.default.removeItem(at: url)
        self.outputURL = url

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            self.continuation = cont
            self.state = .rendering(progress: 0, currentSegmentIndex: 0, totalSegments: totalSegments)
            renderNextSegment()
        }
    }

    /// Cancel an in-flight render. Synthesizer is stopped; the
    /// continuation throws `.cancelled` so the caller's `try await`
    /// resolves promptly.
    func cancel() {
        guard !didFinish else { return }
        synthesizer.stopSpeaking(at: .immediate)
        finish(with: .failure(AudioExportError.cancelled))
    }

    /// 2026-05-13 — Specifically end the render because iOS expired
    /// the calling site's `beginBackgroundTask` window. Distinct
    /// from `cancel()` so the resulting failure notification reads
    /// "Posey couldn't finish exporting in the background" instead
    /// of the misleading "Export cancelled."
    func cancelDueToBackgroundExpiration() {
        guard !didFinish else { return }
        synthesizer.stopSpeaking(at: .immediate)
        finish(with: .failure(AudioExportError.backgroundTimeExpired))
    }

    private func renderNextSegment() {
        guard !didFinish else { return }
        guard currentIndex < segments.count else {
            // All done.
            audioFile = nil
            if let url = outputURL {
                state = .finished(fileURL: url)
                finish(with: .success(url))
            } else {
                finish(with: .failure(AudioExportError.unknown("Output URL went missing.")))
            }
            return
        }
        let segment = segments[currentIndex]
        // 2026-05-06 (parity #4): strip leading list markers before
        // synthesis (see SpeechPlaybackService.utteranceText).
        let utterance = AVSpeechUtterance(string: SpeechPlaybackService.utteranceText(for: segment.text))
        applyVoice(to: utterance)

        // Track whether this utterance produced ANY buffers. The
        // Best-Available capture investigation runs here: if the
        // first utterance receives nothing, we bail with
        // .voiceNotCapturable so the user can switch.
        let segmentStartedAt = Date()
        var sawBufferThisUtterance = false

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self else { return }
            // Hop to main; AVAudioFile + state mutations live there.
            Task { @MainActor in
                guard !self.didFinish else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // Final buffer — synthesizer signals end-of-utterance
                    // with a zero-frame-length buffer.
                    self.completeCurrentSegment(sawBuffer: sawBufferThisUtterance, started: segmentStartedAt)
                    return
                }
                sawBufferThisUtterance = true
                self.receivedAnyBuffer = true
                self.appendBuffer(pcm)
            }
        }
    }

    private func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        do {
            if audioFile == nil {
                guard let url = outputURL else {
                    finish(with: .failure(AudioExportError.audioFileSetupFailed("Output URL not set")))
                    return
                }
                // Use the buffer's format as the file's native
                // format. M4A wraps AAC; AVAudioFile picks the
                // right codec from the .m4a extension.
                // Task 7 (2026-05-03): bumped quality medium → high.
                // Spoken-word AAC at native rate is small even at
                // high quality (~1 MB / 8 minutes); the perceptual
                // gain on premium voices is real. medium left
                // sibilants harsh on long exports.
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: buffer.format.sampleRate,
                    AVNumberOfChannelsKey: buffer.format.channelCount,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                audioFile = try AVAudioFile(
                    forWriting: url,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            }
            try audioFile?.write(from: buffer)
        } catch {
            finish(with: .failure(AudioExportError.audioFileSetupFailed("\(error)")))
        }
    }

    private func completeCurrentSegment(sawBuffer: Bool, started: Date) {
        // Voice-not-capturable detection: if we're past the first
        // utterance and nothing has come through, AFM gated capture.
        // Bail out before walking the whole document with no audio.
        if currentIndex == 0 && !sawBuffer {
            finish(with: .failure(AudioExportError.voiceNotCapturable))
            return
        }
        currentIndex += 1
        let progress = Double(currentIndex) / Double(max(1, totalSegments))
        state = .rendering(progress: progress, currentSegmentIndex: currentIndex, totalSegments: totalSegments)
        renderNextSegment()
    }

    private func applyVoice(to utterance: AVSpeechUtterance) {
        switch voiceMode {
        case .bestAvailable:
            // Best Available is empirically not buffer-capturable on
            // most devices; we attempt anyway and surface
            // .voiceNotCapturable when it fails.
            utterance.prefersAssistiveTechnologySettings = true
        case .custom(let identifier, let rate):
            utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
            utterance.rate = rate
            utterance.prefersAssistiveTechnologySettings = false
        }
    }

    private func finish(with result: Result<URL, Error>) {
        guard !didFinish else { return }
        didFinish = true
        let cont = continuation
        continuation = nil
        switch result {
        case .success(let url):
            cont?.resume(returning: url)
        case .failure(let error):
            // Update state for UI; throw for caller.
            if case AudioExportError.cancelled = error {
                state = .idle
            } else if let exportError = error as? AudioExportError {
                state = .failed(reason: exportError.errorDescription ?? "\(error)")
            } else {
                state = .failed(reason: "\(error)")
            }
            cont?.resume(throwing: error)
        }
    }
}
// ========== BLOCK 02: AUDIO EXPORTER - END ==========
