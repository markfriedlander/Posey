import AVFoundation
import Foundation

// ========== BLOCK 01: PLAYBACK PREFERENCES - START ==========

/// Persists voice mode selection across sessions via UserDefaults.
///
/// VoiceMode is stored as a mode key ("bestAvailable" or "custom") plus
/// a voice identifier string and a rate float for the custom case.
final class PlaybackPreferences {

    static let shared = PlaybackPreferences()
    private init() {}

    private enum Keys {
        static let voiceMode            = "posey.playback.voiceMode"
        static let customVoiceIdentifier = "posey.playback.customVoiceIdentifier"
        static let customRate           = "posey.playback.customRate"
    }

    private enum ModeToken {
        static let bestAvailable = "bestAvailable"
        static let custom        = "custom"
    }

    var voiceMode: SpeechPlaybackService.VoiceMode {
        get {
            let token = UserDefaults.standard.string(forKey: Keys.voiceMode)
            guard token == ModeToken.custom,
                  let identifier = UserDefaults.standard.string(forKey: Keys.customVoiceIdentifier)
            else {
                return .bestAvailable
            }
            let stored = UserDefaults.standard.float(forKey: Keys.customRate)
            let rate = stored > 0 ? stored : AVSpeechUtteranceDefaultSpeechRate
            return .custom(voiceIdentifier: identifier, rate: rate)
        }
        set {
            switch newValue {
            case .bestAvailable:
                UserDefaults.standard.set(ModeToken.bestAvailable, forKey: Keys.voiceMode)
                UserDefaults.standard.removeObject(forKey: Keys.customVoiceIdentifier)
                UserDefaults.standard.removeObject(forKey: Keys.customRate)
            case .custom(let identifier, let rate):
                UserDefaults.standard.set(ModeToken.custom, forKey: Keys.voiceMode)
                UserDefaults.standard.set(identifier, forKey: Keys.customVoiceIdentifier)
                UserDefaults.standard.set(rate, forKey: Keys.customRate)
            }
        }
    }
}

// ========== BLOCK 01: PLAYBACK PREFERENCES - END ==========
