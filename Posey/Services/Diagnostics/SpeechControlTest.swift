import Foundation
import AVFoundation

// ========== BLOCK 01: SPEECH CONTROL TEST (DEBUG DIAGNOSTIC) - START ==========

#if DEBUG
/// DEBUG-only control test for the read-along freeze diagnosis.
///
/// Speaks a FIXED sentence through a BARE `AVSpeechSynthesizer` — no
/// Posey read-along engine, no sliding-window queue, no ViewModel, none
/// of Posey's playback path — and logs every `willSpeakRange` offset the
/// engine reports. This isolates the question: are the sparse / gapped
/// word-boundary callbacks (which freeze the read-along highlight)
/// inherent to `AVSpeechSynthesizer` + the chosen voice, or are they
/// introduced by something in Posey's own playback machinery?
///
/// Read the result off-device via the `LOGS` verb: look at the sequence
/// of `CTL WR w=<offset>` lines. A big jump between consecutive offsets =
/// the engine went quiet for that stretch (the same gap the real
/// read-along run showed). If the bare test reproduces the gap, it's the
/// engine/voice (Apple). If it does NOT, the gap is on Posey's side.
///
/// The fixed sentence is the exact one Mark watched freeze (The Time
/// Machine, "There is, however, a tendency…"), 178 characters.
final class SpeechControlTest: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = SpeechControlTest()

    private let synth = AVSpeechSynthesizer()
    private var currentMode = ""

    static let testSentence =
        "There is, however, a tendency to draw an unreal distinction between " +
        "the former three dimensions and the latter, because it happens that " +
        "our consciousness moves intermittently in one direction along the " +
        "latter from the beginning to the end of our lives."

    private override init() {
        super.init()
        synth.delegate = self
        // Match Posey's playback: use the app audio session, not the system
        // spoken-content session.
        synth.usesApplicationAudioSession = true
    }

    /// mode:
    ///   "best"    → `prefersAssistiveTechnologySettings = true` — the SAME
    ///               voice Posey uses in `.bestAvailable` (system Spoken
    ///               Content / Siri-quality voice, no rate override).
    ///   "default" → an explicit default compact voice for the language,
    ///               to see whether a lower-tier voice reports densely.
    func run(mode: String) {
        currentMode = mode
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: Self.testSentence)
        switch mode {
        case "default":
            u.prefersAssistiveTechnologySettings = false
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
        default:
            // "best" — mirror Posey's .bestAvailable exactly.
            u.prefersAssistiveTechnologySettings = true
        }
        dbgLog("CTL RUN mode=%@ len=%ld", mode, (Self.testSentence as NSString).length)
        synth.speak(u)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        dbgLog("CTL ST mode=%@", currentMode)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        dbgLog("CTL WR w=%ld len=%ld", characterRange.location, characterRange.length)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        dbgLog("CTL FN mode=%@", currentMode)
    }
}
#endif

// ========== BLOCK 01: SPEECH CONTROL TEST - END ==========
