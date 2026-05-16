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
        static let fontSize             = "posey.reader.fontSize"
        static let lastOpenedDocumentID = "posey.library.lastOpenedDocumentID"
        static let readingStyle         = "posey.reader.readingStyle"
    }

    /// M8 Reading Style preferences. Persisted as a string so future
    /// cases append without migration. Per `DECISIONS.md` "Reading
    /// Style as Preferences not Modes" (2026-05-01).
    enum ReadingStyle: String, CaseIterable, Equatable {
        /// 2026-05-04 — `.standard` HIDDEN from the UI for 1.0
        /// (Mark's directive). Was the original "no styling"
        /// default — barely a reading style at all. Kept in the
        /// enum so persisted UserDefaults values still parse;
        /// migrated to `.focus` on read (see `readingStyle` getter).
        /// Excluded from `userSelectableCases`.
        case standard
        /// Dim every non-active sentence to ~45% opacity so the eye
        /// is naturally drawn to the active one. Functionally
        /// additive on top of the existing highlight tier.
        /// 2026-05-04 — Default for 1.0.
        case focus
        /// 2026-05-04 — `.immersive` HIDDEN from the UI for 1.0
        /// (Mark's directive). Centers + fades surrounding text but
        /// overlapped substantially with `.motion` (which adds the
        /// "one large centered sentence" framing on top of the same
        /// center+fade behavior). Kept in enum for parse-compat;
        /// migrated to `.focus` on read.
        case immersive
        /// Large single centered sentence, optimized for
        /// walking / driving / hands-free. Inherits the
        /// three-setting Off / On / Auto behavior captured in
        /// `MotionPreference`.
        case motion

        /// 2026-05-04 — Subset of `allCases` shown in the user-
        /// facing Preferences picker. Standard and Immersive are
        /// excluded for 1.0 per Mark's directive (Standard was
        /// barely a style; Immersive overlapped Motion). Both
        /// remain in the enum for parse-compat with existing
        /// UserDefaults; the `readingStyle` getter migrates them
        /// to `.focus` on read so users on the hidden styles land
        /// on a selectable one.
        static let userSelectableCases: [ReadingStyle] = [.focus, .motion]

        var displayName: String {
            switch self {
            case .standard:  return "Standard"
            case .focus:     return "Focus"
            case .immersive: return "Immersive"
            case .motion:    return "Motion"
            }
        }

        var description: String {
            switch self {
            case .standard:
                return "Single highlighted active sentence; surrounding text at full opacity."
            case .focus:
                return "Dim every non-active sentence so your eye lands on the brightest one."
            case .immersive:
                return "Active sentence centered and bright; nearby sentences fade and shrink with distance."
            case .motion:
                return "One large centered sentence at a time. For walking, driving, hands-free reading."
            }
        }
    }

    /// M8 Motion sub-preference for the three-setting design captured
    /// in `DECISIONS.md` "Motion Mode Three-Setting Design" (2026-05-01).
    /// Honored only when `readingStyle == .motion`. The Auto case
    /// requires explicit user consent before CoreMotion monitoring
    /// engages — that consent is tracked separately.
    enum MotionPreference: String, CaseIterable, Equatable {
        /// Never use Motion mode regardless of device movement.
        /// Always use the user's last non-Motion Reading Style.
        case off
        /// Motion mode always — intentional choice (low vision,
        /// stationary reader who prefers the large centered
        /// sentence).
        case on
        /// Switch automatically based on device motion (CoreMotion
        /// monitoring, requires explicit consent before enabling).
        case auto

        var displayName: String {
            switch self {
            case .off:  return "Off"
            case .on:   return "On"
            case .auto: return "Auto"
            }
        }

        var description: String {
            switch self {
            case .off:  return "Never. Always use my non-Motion style."
            case .on:   return "Always. Use Motion regardless of movement."
            case .auto: return "Switch automatically when I'm moving."
            }
        }
    }

    /// User-chosen reading style. Defaults to `.standard` for new
    /// installs (the current Posey behavior). Stored as the raw
    /// string so future cases append cleanly.
    var readingStyle: ReadingStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.readingStyle),
                  let style = ReadingStyle(rawValue: raw) else {
                return .focus
            }
            // 2026-05-04 — Migrate styles hidden from the 1.0 UI
            // (`.standard`, `.immersive`) to the closest selectable
            // style (`.focus`) so users who had those selected don't
            // get stuck on a style they can't re-pick from the
            // picker. The persisted raw value is left untouched —
            // if we ever re-introduce those styles, the user's
            // original choice surfaces again.
            switch style {
            case .standard, .immersive:
                return .focus
            case .focus, .motion:
                return style
            }
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.readingStyle)
        }
    }

    /// User-chosen Motion sub-preference. Defaults to `.off` so new
    /// installs never engage CoreMotion implicitly. Honored only when
    /// `readingStyle == .motion`.
    var motionPreference: MotionPreference {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "posey.reader.motionPreference"),
                  let value = MotionPreference(rawValue: raw) else {
                return .off
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "posey.reader.motionPreference")
        }
    }

    /// Whether the user has explicitly consented to CoreMotion
    /// monitoring for the Motion-mode Auto path. Required because
    /// CoreMotion is a privacy-sensitive sensor; we never engage it
    /// without an opt-in screen the user has acknowledged.
    var motionAutoConsent: Bool {
        get { UserDefaults.standard.bool(forKey: "posey.reader.motionAutoConsent") }
        set { UserDefaults.standard.set(newValue, forKey: "posey.reader.motionAutoConsent") }
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

    var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: Keys.fontSize)
            return stored > 0 ? CGFloat(stored) : 18
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: Keys.fontSize)
        }
    }

    /// 2026-05-14 (B3) — User-tunable retrieval strictness for the
    /// Ask Posey weak-retrieval gate. Three levels chosen so the
    /// label space is meaningful to non-engineers and the underlying
    /// threshold range matches the empirical 2026-05-04 sweep that
    /// pinned 0.45 as a fabrication-vs-grounded boundary.
    ///
    /// Relabeled 2026-05-14 per Mark — the picker now describes
    /// **search breadth**, not Posey's willingness to answer.
    ///
    /// - `broad` (was permissive) → 0.35: searches widely; attempts
    ///   answers from loosely related passages.
    /// - `balanced` → 0.45 (default): searches thoroughly; answers when
    ///   it finds relevant content. Recommended.
    /// - `precise` (was strict) → 0.55: only matches closely related
    ///   passages. Best for technical / legal documents.
    ///
    /// `rawValue`s remain `permissive` / `balanced` / `strict` so
    /// users' persisted preference doesn't reset across upgrade —
    /// only the UI labels change.
    enum RetrievalStrictness: String, CaseIterable, Equatable {
        case broad     = "permissive"
        case balanced  = "balanced"
        case precise   = "strict"

        /// Cosine threshold a non-front-matter chunk must clear for
        /// `isWeakRetrieval` to return `false` (i.e. to attempt an
        /// AFM answer). Returned as a `Double` so it can be compared
        /// directly against `RetrievedChunk.relevance`.
        var weakRetrievalThreshold: Double {
            switch self {
            case .broad:    return 0.35
            case .balanced: return 0.45
            case .precise:  return 0.55
            }
        }

        var displayName: String {
            switch self {
            case .broad:    return "Broad"
            case .balanced: return "Balanced"
            case .precise:  return "Precise"
            }
        }

        var description: String {
            switch self {
            case .broad:
                return "Posey searches widely and attempts answers even from loosely related passages."
            case .balanced:
                return "Posey searches thoroughly and answers when she finds relevant content. Recommended."
            case .precise:
                return "Posey only answers from closely matched passages. Best for technical or legal documents."
            }
        }
    }

    /// Current retrieval-strictness preference. Default `.balanced`
    /// (matches the 0.45 floor hard-coded before this preference
    /// existed, so existing behavior is preserved for users who
    /// don't visit Preferences).
    var retrievalStrictness: RetrievalStrictness {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "posey.askposey.retrievalStrictness"),
                  let value = RetrievalStrictness(rawValue: raw) else {
                return .balanced
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "posey.askposey.retrievalStrictness")
        }
    }

    /// The document the user was last reading. Restored at cold launch so the
    /// app reopens to the reader instead of the library list.
    /// Cleared when the user explicitly navigates back to the library.
    var lastOpenedDocumentID: UUID? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.lastOpenedDocumentID) else {
                return nil
            }
            return UUID(uuidString: raw)
        }
        set {
            if let id = newValue {
                UserDefaults.standard.set(id.uuidString, forKey: Keys.lastOpenedDocumentID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastOpenedDocumentID)
            }
        }
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
