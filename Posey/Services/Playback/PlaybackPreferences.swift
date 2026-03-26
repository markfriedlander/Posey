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

    /// Returns the last persisted custom mode if one exists, regardless of whether
    /// bestAvailable is currently active. Used to restore custom settings when
    /// the user switches back to Custom mode after using Best Available.
    var lastCustomVoiceMode: SpeechPlaybackService.VoiceMode? {
        guard let identifier = UserDefaults.standard.string(forKey: Keys.customVoiceIdentifier)
        else { return nil }
        let stored = UserDefaults.standard.float(forKey: Keys.customRate)
        let rate = stored > 0 ? stored : AVSpeechUtteranceDefaultSpeechRate
        return .custom(voiceIdentifier: identifier, rate: rate)
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
                // Only persist the mode token. Keep customVoiceIdentifier and customRate
                // so they can be restored if the user switches back to Custom mode.
                UserDefaults.standard.set(ModeToken.bestAvailable, forKey: Keys.voiceMode)
            case .custom(let identifier, let rate):
                UserDefaults.standard.set(ModeToken.custom, forKey: Keys.voiceMode)
                UserDefaults.standard.set(identifier, forKey: Keys.customVoiceIdentifier)
                UserDefaults.standard.set(rate, forKey: Keys.customRate)
            }
        }
    }
}

// ========== BLOCK 01: PLAYBACK PREFERENCES - END ==========
