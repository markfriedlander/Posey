import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: TYPES - START ==========
/// Whether Ask Posey is usable on this device right now, and (if not) why.
///
/// The Ask Posey UI is gated on this value. Per `ask_posey_spec.md` resolved
/// decision 5 ("AFM unavailable: hide the Ask Posey interface entirely"),
/// the entry points (selection-menu item, bottom-bar glyph) are omitted —
/// not greyed out — when the state is anything other than `.available`.
public enum AskPoseyAvailabilityState: Equatable, Sendable {
    /// AFM is ready to take requests on this device.
    case available
    /// FoundationModels is not present (running on iOS < 26).
    case frameworkUnavailable
    /// Apple Intelligence isn't enabled in Settings.
    case appleIntelligenceNotEnabled
    /// Device hardware doesn't support AFM.
    case deviceNotEligible
    /// Model assets aren't installed yet (downloading or not provisioned).
    case modelNotReady
    /// FoundationModels surfaced an `Availability.UnavailableReason` we don't
    /// have a case for. The raw description is captured for diagnostics so
    /// future SDK additions don't silently fall through.
    case unknownUnavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}
// ========== BLOCK 01: TYPES - END ==========


// ========== BLOCK 02: AVAILABILITY SOURCE - START ==========
/// Single chokepoint for "is Ask Posey usable here?"
///
/// Calling code (sheet entry points, classifier, prompt builder) reads
/// `current` whenever it needs to decide whether to render UI or initiate a
/// request. Internally this is a small wrapper around
/// `SystemLanguageModel.default.availability` — the wrapper exists so the
/// rest of the codebase doesn't have to deal with `#available`,
/// `#canImport`, the `UnavailableReason` enum, or the simulator-vs-device
/// distinction every time it asks the question.
///
/// Cheap to call: under the hood it queries the framework directly each
/// time, no caching. AFM availability can change at runtime (Apple
/// Intelligence toggled in Settings, model assets finish downloading), and
/// caching would just produce stale `isAvailable` reads.
public struct AskPoseyAvailability {

    /// Read once whenever the UI needs to decide visibility.
    public static var current: AskPoseyAvailabilityState {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return resolve(SystemLanguageModel.default.availability)
        }
        return .frameworkUnavailable
        #else
        return .frameworkUnavailable
        #endif
    }

    /// Convenience boolean. Equivalent to `current.isAvailable`.
    public static var isAvailable: Bool {
        current.isAvailable
    }

    /// Human-readable explanation suitable for diagnostic logging. Not for
    /// end-user UI — the user-facing rule is "hide entirely when not
    /// available," so we never display a reason string to the user.
    public static var diagnosticDescription: String {
        switch current {
        case .available:
            return "available"
        case .frameworkUnavailable:
            return "FoundationModels framework not available (iOS < 26)"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence not enabled in Settings"
        case .deviceNotEligible:
            return "Device hardware not eligible for Apple Intelligence"
        case .modelNotReady:
            return "Apple Intelligence model assets not ready"
        case .unknownUnavailable(let reason):
            return "AFM unavailable (unknown reason): \(reason)"
        }
    }
}
// ========== BLOCK 02: AVAILABILITY SOURCE - END ==========


// ========== BLOCK 03: FOUNDATIONMODELS BRIDGE - START ==========
#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
extension AskPoseyAvailability {

    /// Convert FoundationModels' `Availability` into our local enum so the
    /// rest of the codebase can pattern-match without depending on the
    /// framework type directly. Centralising the mapping here also means a
    /// new `UnavailableReason` case in a future SDK release lands as
    /// `.unknownUnavailable` rather than a compile-time break.
    fileprivate static func resolve(_ availability: SystemLanguageModel.Availability)
        -> AskPoseyAvailabilityState
    {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .unknownUnavailable(reason: String(describing: reason))
            }
        @unknown default:
            return .unknownUnavailable(reason: String(describing: availability))
        }
    }
}
#endif
// ========== BLOCK 03: FOUNDATIONMODELS BRIDGE - END ==========
