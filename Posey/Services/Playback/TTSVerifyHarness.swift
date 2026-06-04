import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
#if canImport(ReplayKit)
import ReplayKit
#endif

// ===== BLOCK 01: OVERVIEW - START =====
// TTS Verification Harness — SILENT DIGITAL capture (2026-06-03, rev 2).
//
// HARD CONSTRAINTS (Mark, 2026-06-03): NO microphone, NO audible playback. Audio
// must be captured digitally and silently. So this rev does NOT use AVAudioRecorder.
//
// WHY ReplayKit (and why NOT an AVAudioEngine tap, the "preferred" idea):
//   AVSpeechSynthesizer.speak() — the PRODUCTION path that drives the on-screen
//   highlight via the didStart delegate — plays straight to the audio session
//   output. It does NOT route through an app-created AVAudioEngine, so an engine
//   tap on mainMixerNode captures only the (empty) engine graph = silence. The
//   only engine-capturable route is AVSpeechSynthesizer.write(toBufferCallback:),
//   which is the OFFLINE render (wrong rate) replayed through a synthetic player —
//   that's the exact premise that already FAILED for sync, and it isn't the
//   production highlight path. `probeEngineTap` measures this empirically so the
//   claim is evidence, not assertion (Rule 9).
//
//   ReplayKit's RPScreenRecorder.startCapture delivers the app's OWN audio mix
//   (`.audioApp` CMSampleBuffers) digitally — no microphone. It captures the real
//   speak() output. Silence is achieved by the phone's media volume being at 0:
//   ReplayKit captures the app-level mix (pre hardware-volume), so volume-0 ==
//   silent speaker AND full-amplitude capture. THAT must be validated before it's
//   trusted (the `amplitudeMax` probe + a whisper pass on a silent run) — if the
//   capture is silent while the speaker is silent, there is no silent-digital path
//   on this platform and the honest move is BLOCKED (never mic, never audible).
//
// BATCHING: one startCapture == one iOS consent alert. We start capture ONCE
// (TTS_VERIFY_CAPTURE_START), run many stretches under it (each writes its own
// m4a + highlight log), then stopCapture — minimizing taps to one.
//
// ONE CLOCK / non-circularity (Req 2): `.audioApp` buffer PTS are on the host
// time base (CACurrentMediaTime domain). Highlight samples are stamped with
// CACurrentMediaTime() (the value that drives the on-screen highlight — the
// "seen" signal). The audio file (written with startSession(atSourceTime:
// firstPTS)) is 0-based at firstPTS; we re-zero the highlight samples to
// firstPTS too, so ASR word time ("heard", an independent subsystem) and
// highlight time are directly comparable with no rate assumption.
//
// DEBUG-only (real). Release ships an inert stub — no ReplayKit, no recording.
// ===== BLOCK 01: OVERVIEW - END =====

#if DEBUG

// ===== BLOCK 02: OFF-MAIN CAPTURE SINK - START =====
// Receives `.audioApp` CMSampleBuffers on ReplayKit's background queue and writes
// the current stretch to an m4a via AVAssetWriter. All state touched only on its
// own serial queue (@unchecked Sendable is sound under that discipline).
final class TTSCaptureSink: @unchecked Sendable {
    private let q = DispatchQueue(label: "com.posey.ttsverify.capture")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var firstPTS: CMTime = .invalid
    private var url: URL?
    private var amplitudeMax: Float = 0
    private var open = false

    /// Begin writing a new stretch to `url`. Input is created lazily from the
    /// first buffer's format (so channels/sample-rate match the source exactly).
    func openStretch(url: URL) {
        q.sync {
            try? FileManager.default.removeItem(at: url)
            self.url = url
            self.firstPTS = .invalid
            self.sessionStarted = false
            self.amplitudeMax = 0
            self.input = nil
            self.writer = try? AVAssetWriter(outputURL: url, fileType: .m4a)
            self.open = true
        }
    }

    /// Route one `.audioApp` buffer (called on ReplayKit's bg queue).
    func handleAudioApp(_ sb: CMSampleBuffer) {
        q.async { [weak self] in self?.appendLocked(sb) }
    }

    private func appendLocked(_ sb: CMSampleBuffer) {
        guard open, let writer = writer, CMSampleBufferDataIsReady(sb) else { return }
        if input == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(sb),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                AVSampleRateKey: asbd.mSampleRate,
                AVEncoderBitRateKey: 96_000
            ]
            let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: fmt)
            inp.expectsMediaDataInRealTime = true
            if writer.canAdd(inp) { writer.add(inp) }
            self.input = inp
            writer.startWriting()
        }
        guard let input = input, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
            sessionStarted = true
        }
        updateAmplitude(sb)
        if input.isReadyForMoreMediaData {
            input.append(sb)
        }
    }

    /// Peak-amplitude probe — proves whether real signal was captured while the
    /// speaker is silent. Handles Float32 and Int16 LPCM (ReplayKit's formats).
    private func updateAmplitude(_ sb: CMSampleBuffer) {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &len, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
              let base = ptr, len > 0,
              let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var peak: Float = 0
        if isFloat {
            let n = len / MemoryLayout<Float>.size
            base.withMemoryRebound(to: Float.self, capacity: n) { fp in
                for i in 0..<n { let v = abs(fp[i]); if v > peak { peak = v } }
            }
        } else {
            let n = len / MemoryLayout<Int16>.size
            base.withMemoryRebound(to: Int16.self, capacity: n) { ip in
                for i in 0..<n { let v = abs(Float(ip[i]) / 32768.0); if v > peak { peak = v } }
            }
        }
        if peak > amplitudeMax { amplitudeMax = peak }
    }

    /// Finish the current stretch. Returns the stretch's audio anchor (firstPTS
    /// in seconds, host clock), the peak amplitude seen, and byte size.
    func closeStretch() -> (firstPTSSeconds: Double, amplitude: Float, bytes: Int) {
        var out = (0.0, Float(0), 0)
        q.sync {
            self.open = false
            let amp = self.amplitudeMax
            let first = self.firstPTS.isValid && self.firstPTS.isNumeric ? self.firstPTS.seconds : 0.0
            if let input = self.input { input.markAsFinished() }
            if let writer = self.writer, writer.status == .writing {
                let sem = DispatchSemaphore(value: 0)
                writer.finishWriting { sem.signal() }
                sem.wait()
            }
            let bytes = (self.url.flatMap { try? Data(contentsOf: $0).count }) ?? 0
            out = (first, amp, bytes)
            self.writer = nil; self.input = nil
        }
        return out
    }
}
// ===== BLOCK 02: OFF-MAIN CAPTURE SINK - END =====

// ===== BLOCK 03: HARNESS (DEBUG REAL) - START =====
@MainActor
final class TTSVerifyHarness {
    static let shared = TTSVerifyHarness()
    private init() {}

    enum Status: String { case idle, recording, finished, failed }

    private(set) var status: Status = .idle
    private(set) var runID: String = ""
    private(set) var errorMessage: String?
    private(set) var lastReason: String = ""
    private(set) var captureActive = false
    private(set) var lastAmplitude: Float = 0
    private(set) var lastAudioBytes: Int = 0

    private let sink = TTSCaptureSink()
    private var samplesAbs: [(absT: Double, index: Int, offset: Int)] = []
    private var playedSegments: [(index: Int, startOffset: Int, endOffset: Int, text: String)] = []
    private var startSentence = 0
    private var endSentenceExclusive = 0
    private var audioURL: URL?
    private var jsonURL: URL?
    private var runFiles: [String: (audio: URL, json: URL)] = [:]
    private var watchdog: Timer?
    private var trailingStop: Timer?
    private var onStop: (() -> Void)?

    // ---- Batched capture session (one consent tap) -------------------------
    /// Start the ReplayKit app-audio capture session. Triggers ONE iOS consent
    /// alert (Mark grants it). Microphone explicitly disabled. Keep this running
    /// across many stretches; stop with `stopCapture`.
    func startCapture(completion: @escaping (Bool, String?) -> Void) {
        #if canImport(ReplayKit)
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else { completion(false, "RPScreenRecorder not available"); return }
        guard !captureActive else { completion(true, "already active"); return }
        recorder.isMicrophoneEnabled = false
        // Capture the Sendable sink locally — the handler runs on a background
        // queue and must NOT touch the @MainActor harness's `self`.
        let sink = self.sink
        recorder.startCapture(handler: { sampleBuffer, bufferType, error in
            guard error == nil else { return }
            if bufferType == .audioApp {
                sink.handleAudioApp(sampleBuffer)
            }
            // .video / .audioMic ignored (mic disabled; video unused).
        }, completionHandler: { [weak self] error in
            Task { @MainActor in
                if let error = error {
                    self?.captureActive = false
                    completion(false, error.localizedDescription)
                } else {
                    self?.captureActive = true
                    completion(true, nil)
                }
            }
        })
        #else
        completion(false, "ReplayKit unavailable on this platform")
        #endif
    }

    func stopCapture(completion: @escaping (Bool, String?) -> Void) {
        #if canImport(ReplayKit)
        guard captureActive else { completion(true, "not active"); return }
        RPScreenRecorder.shared().stopCapture { [weak self] error in
            Task { @MainActor in
                self?.captureActive = false
                completion(error == nil, error?.localizedDescription)
            }
        }
        #else
        completion(false, "ReplayKit unavailable")
        #endif
    }

    // ---- One stretch under the active capture session ----------------------
    /// Begin one capture stretch. Requires `startCapture` to have succeeded. The
    /// caller (ReaderView) starts LIVE playback at `startSentence` right after
    /// this returns true and calls `recordHighlight` on every index change.
    @discardableResult
    func begin(runID: String,
               segments: [TextSegment],
               startSentence: Int,
               numSentences: Int,
               onStop: @escaping () -> Void) -> Bool {
        guard status != .recording else { return false }
        guard captureActive else {
            errorMessage = "capture session not active — call TTS_VERIFY_CAPTURE_START first"
            status = .failed
            return false
        }
        guard !segments.isEmpty else { errorMessage = "no segments"; status = .failed; return false }
        self.runID = runID
        self.onStop = onStop
        self.errorMessage = nil
        self.lastReason = ""
        self.samplesAbs = []
        self.trailingStop?.invalidate(); self.trailingStop = nil
        self.startSentence = max(0, min(startSentence, segments.count - 1))
        self.endSentenceExclusive = min(segments.count, self.startSentence + max(1, numSentences))
        self.playedSegments = (self.startSentence..<self.endSentenceExclusive).map { i in
            (index: i, startOffset: segments[i].startOffset,
             endOffset: segments[i].endOffset, text: segments[i].text)
        }
        let dir = FileManager.default.temporaryDirectory
        let aURL = dir.appendingPathComponent("ttsverify-\(runID).m4a")
        let jURL = dir.appendingPathComponent("ttsverify-\(runID).json")
        self.audioURL = aURL
        self.jsonURL = jURL
        sink.openStretch(url: aURL)
        self.status = .recording

        let maxSeconds = Double(playedSegments.count) * 14.0 + 25.0
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: maxSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.end(reason: "watchdog") }
        }
        return true
    }

    /// Log one on-screen-highlight transition (absolute host clock; re-zeroed to
    /// the audio anchor at end). No-op unless a stretch is recording.
    func recordHighlight(index: Int, offset: Int) {
        guard status == .recording else { return }
        samplesAbs.append((absT: CACurrentMediaTime(), index: index, offset: offset))
        if index >= endSentenceExclusive - 1 {
            scheduleTrailingStop()
        }
    }

    private func scheduleTrailingStop() {
        guard trailingStop == nil else { return }
        trailingStop = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.end(reason: "reached-target") }
        }
    }

    /// End the current stretch: finalize the audio file, re-zero highlight samples
    /// to the audio anchor, write JSON, pause playback. Idempotent. Leaves the
    /// batched capture session running for the next stretch.
    func end(reason: String) {
        guard status == .recording else { return }
        lastReason = reason
        watchdog?.invalidate(); watchdog = nil
        trailingStop?.invalidate(); trailingStop = nil
        let closed = sink.closeStretch()
        lastAmplitude = closed.amplitude
        lastAudioBytes = closed.bytes
        writeHighlightJSON(anchorSeconds: closed.firstPTSSeconds,
                           amplitude: closed.amplitude, audioBytes: closed.bytes)
        if let a = audioURL, let j = jsonURL { runFiles[runID] = (a, j) }
        status = .finished
        let stop = onStop; onStop = nil
        stop?()
    }

    private func writeHighlightJSON(anchorSeconds: Double, amplitude: Float, audioBytes: Int) {
        guard let jURL = jsonURL else { return }
        // Re-zero highlight times to the audio anchor (firstPTS): both are on the
        // host clock, so sample t == absT - anchor matches the 0-based audio file.
        let samples = samplesAbs.map { s -> [String: Any] in
            ["t": (anchorSeconds > 0 ? s.absT - anchorSeconds : 0.0), "index": s.index, "offset": s.offset]
        }
        let payload: [String: Any] = [
            "runID": runID,
            "reason": lastReason,
            "captureMethod": "replaykit-audioApp",
            "audioAnchorSeconds": anchorSeconds,
            "audioBytes": audioBytes,
            "capturedPeakAmplitude": amplitude,
            "startSentence": startSentence,
            "endSentenceExclusive": endSentenceExclusive,
            "samples": samples,
            "segments": playedSegments.map {
                ["index": $0.index, "startOffset": $0.startOffset,
                 "endOffset": $0.endOffset, "text": $0.text]
            }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: jURL)
        }
    }

    func statusSnapshot() -> [String: Any] {
        [
            "runID": runID,
            "status": status.rawValue,
            "reason": lastReason,
            "captureActive": captureActive,
            "sampleCount": samplesAbs.count,
            "lastPeakAmplitude": lastAmplitude,
            "lastAudioBytes": lastAudioBytes,
            "startSentence": startSentence,
            "endSentenceExclusive": endSentenceExclusive,
            "error": errorMessage ?? NSNull()
        ]
    }

    func fetchPayload(runID requested: String?) -> [String: Any]? {
        let key = (requested?.isEmpty == false) ? requested! : runID
        guard let files = runFiles[key],
              let audio = try? Data(contentsOf: files.audio),
              let jsonData = try? Data(contentsOf: files.json) else { return nil }
        return [
            "runID": key,
            "audioFilename": files.audio.lastPathComponent,
            "audioBytes": audio.count,
            "audioBase64": audio.base64EncodedString(),
            "highlightJSON": String(data: jsonData, encoding: .utf8) ?? "{}"
        ]
    }

    // ---- Engine-tap evidence probe (proves the "preferred" path can't capture
    //      speak()). Sets up an AVAudioEngine + mainMixer tap, speaks a known
    //      phrase, and reports the peak amplitude the tap saw. ~0 == confirms the
    //      engine graph never receives speak() audio. -------------------------
    func probeEngineTap(completion: @escaping ([String: Any]) -> Void) {
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        let fmt = mixer.outputFormat(forBus: 0)
        let peakBox = AmplitudeBox()
        mixer.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buffer, _ in
            guard let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var p: Float = 0
            for i in 0..<n { let v = abs(ch[0][i]); if v > p { p = v } }
            peakBox.update(p)
        }
        do { try engine.start() } catch {
            completion(["error": "engine start: \(error.localizedDescription)"]); return
        }
        let synth = AVSpeechSynthesizer()
        synth.usesApplicationAudioSession = true
        let u = AVSpeechUtterance(string: "Posey engine tap capture probe one two three four five.")
        u.volume = 0  // keep silent even if the engine path were audible
        synth.speak(u)
        // Sample for ~4s, then tear down and report.
        Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            mixer.removeTap(onBus: 0)
            engine.stop()
            if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
            completion([
                "method": "AVAudioEngine.mainMixerNode tap",
                "peakAmplitudeFromTap": peakBox.value,
                "interpretation": peakBox.value < 0.001
                    ? "≈0 — engine tap did NOT capture speak() output (expected; speak() bypasses the app engine)"
                    : "non-zero — engine tap captured signal"
            ])
        }
    }
}

/// Thread-safe float box for the engine-probe tap (tap fires off-main).
final class AmplitudeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: Float = 0
    var value: Float { lock.lock(); defer { lock.unlock() }; return _v }
    func update(_ p: Float) { lock.lock(); if p > _v { _v = p }; lock.unlock() }
}
// ===== BLOCK 03: HARNESS (DEBUG REAL) - END =====

#else

// ===== BLOCK 04: HARNESS (RELEASE NO-OP) - START =====
// Release stub: preserves the API surface; ships no ReplayKit / recording.
@MainActor
final class TTSVerifyHarness {
    static let shared = TTSVerifyHarness()
    private init() {}

    enum Status: String { case idle, recording, finished, failed }
    var status: Status { .idle }
    var runID: String { "" }
    var errorMessage: String? { nil }
    var lastReason: String { "" }
    var captureActive: Bool { false }

    func startCapture(completion: @escaping (Bool, String?) -> Void) { completion(false, "release") }
    func stopCapture(completion: @escaping (Bool, String?) -> Void) { completion(false, "release") }
    @discardableResult
    func begin(runID: String, segments: [TextSegment], startSentence: Int,
               numSentences: Int, onStop: @escaping () -> Void) -> Bool { false }
    func recordHighlight(index: Int, offset: Int) {}
    func end(reason: String) {}
    func statusSnapshot() -> [String: Any] { [:] }
    func fetchPayload(runID requested: String?) -> [String: Any]? { nil }
    func probeEngineTap(completion: @escaping ([String: Any]) -> Void) { completion([:]) }
}
// ===== BLOCK 04: HARNESS (RELEASE NO-OP) - END =====

#endif
