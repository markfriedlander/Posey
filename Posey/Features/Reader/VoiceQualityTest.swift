#if DEBUG
import AVFoundation
import SwiftUI

// ========== BLOCK 1: TEST CONTROLLER - START ==========
/// Temporary empirical test: compare prefersAssistiveTechnologySettings = true
/// vs direct premium voice query. Delete this file once the question is answered.
@MainActor
final class VoiceQualityTestController: NSObject, ObservableObject {
    enum TestMode { case spokenContent, directPremium }

    @Published var status: String = "Tap a button to start"
    @Published var directVoiceLabel: String = ""
    @Published var isPlaying = false

    private let synthesizer = AVSpeechSynthesizer()
    private var currentMode: TestMode?

    static let sampleText = """
        William James believed that consciousness is not a thing but a process — a stream that flows without pause or interruption. \
        The mind, he argued, does not move from one fixed state to another the way a train moves between stations. \
        Instead it flows, continuously and fluidly, like water finding its own path. \
        James introduced this metaphor in 1890, in his landmark work The Principles of Psychology. \
        His aim was to capture something that introspection alone could never fully describe. \
        We can observe the obvious peaks — the clear thoughts, the named emotions, the distinct memories — but the transitions between them are fleeting and almost impossible to hold still. \
        That is where the real texture of mental life lives, in those dim peripheries and passing moments. \
        For James, ignoring the transitive parts of thought was like studying a river by looking only at its surface.
        """

    override init() {
        super.init()
        synthesizer.delegate = self
        resolveDirectVoiceLabel()
    }

    func playSpokenContent() {
        stop()
        currentMode = .spokenContent
        let utterance = AVSpeechUtterance(string: Self.sampleText)
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
        status = "Playing: Spoken Content mode (prefersAssistiveTechnologySettings = true)"
        isPlaying = true
    }

    func playDirectPremium() {
        stop()
        currentMode = .directPremium
        let utterance = AVSpeechUtterance(string: Self.sampleText)
        utterance.prefersAssistiveTechnologySettings = false
        utterance.voice = bestAvailableEnglishVoice()
        synthesizer.speak(utterance)
        status = "Playing: Direct Premium mode"
        isPlaying = true
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isPlaying = false
        status = "Stopped"
    }

    private func bestAvailableEnglishVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-US") }

        return voices.first(where: { $0.quality == .premium })
            ?? voices.first(where: { $0.quality == .enhanced })
            ?? voices.first(where: { $0.quality == .default })
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func resolveDirectVoiceLabel() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-US") }

        if let v = voices.first(where: { $0.quality == .premium }) {
            directVoiceLabel = "Will use: \(v.name) [premium] — \(v.identifier)"
        } else if let v = voices.first(where: { $0.quality == .enhanced }) {
            directVoiceLabel = "Will use: \(v.name) [enhanced] — \(v.identifier)"
        } else if let v = voices.first(where: { $0.quality == .default }) {
            directVoiceLabel = "Will use: \(v.name) [default] — \(v.identifier)"
        } else {
            directVoiceLabel = "No en-US voice found — will use system default"
        }
    }
}
// ========== BLOCK 1: TEST CONTROLLER - END ==========

// ========== BLOCK 2: TEST VIEW - START ==========
extension VoiceQualityTestController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
            self.status = "Finished"
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }
}

struct VoiceQualityTestSection: View {
    @StateObject private var controller = VoiceQualityTestController()

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !controller.directVoiceLabel.isEmpty {
                    Text(controller.directVoiceLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        controller.playSpokenContent()
                    } label: {
                        Text("A: Spoken Content")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isPlaying)

                    Button {
                        controller.playDirectPremium()
                    } label: {
                        Text("B: Direct Premium")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isPlaying)
                }

                if controller.isPlaying {
                    Button("Stop", role: .destructive) {
                        controller.stop()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Voice Quality Test (Debug)")
        } footer: {
            Text("A uses prefersAssistiveTechnologySettings = true. B queries the highest-quality en-US voice directly. Listen to both and report which sounds better.")
                .font(.caption2)
        }
    }
}
// ========== BLOCK 2: TEST VIEW - END ==========
#endif
