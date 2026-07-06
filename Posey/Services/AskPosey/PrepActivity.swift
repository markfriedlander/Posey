import Foundation

// ========== BLOCK 01: PREP ACTIVITY — PURPOSE - START ==========
/// One shared vocabulary for "what is Posey doing to this document right now,
/// and how far along is it" — used by BOTH the library toast and the Advanced
/// sheet's live-activity line so the two can never drift out of sync (they used
/// to be two independent free-text strings; the toast froze on "reading page 814"
/// while the sheet said "Building document structure…"). Mark, 2026-07-05.
///
/// The STEP is the source of truth (a fixed identity); the words are a SKIN on
/// top. Two skins — a plain technical voice for us while building, and Posey's
/// in-character (Party Girl) voice for users — are just two columns of a table,
/// chosen by `PrepVoice.current`. Progress is always a real "N of N", a "%", or
/// an honest "working…" when a step genuinely can't be counted.
// ========== BLOCK 01: PREP ACTIVITY — PURPOSE - END ==========

// ========== BLOCK 02: STEP + PROGRESS - START ==========
/// The fixed set of pipeline steps a document moves through. IMPORT steps run in
/// the foreground (blocking "added to library"); PREP steps run in the background.
public enum PrepStep: String, Sendable, CaseIterable {
    // Import (foreground)
    case opening            // opening the file (brief, before the page loop)
    case readingPages       // walking every page, pulling its text
    case scanningPages      // import-time Vision OCR on text-less pages
    case findingChapters    // heading resolution
    case layingOutText      // building the reading units
    case savingDocument     // final DB write / source save
    // Prep (background)
    case rescanningPages    // Tier-2 Vision OCR enhancement
    case chunking           // splitting into passages
    case embedding          // vector embedding ("reading ahead")
    case studyingUp         // RAPTOR summary tree
}

/// How far along a step is. `.working` = genuinely uncountable (keep it honest,
/// never fake a number). `.count` renders "N of M"; `.percent` renders "P%".
public enum StepProgress: Sendable, Equatable {
    case working
    case count(done: Int, total: Int)
    case percent(Double)   // 0…1

    /// The trailing progress text ("140 of 814", "60%"), or nil for `.working`.
    var text: String? {
        switch self {
        case .working:
            return nil
        case .count(let done, let total):
            guard total > 0 else { return nil }
            return "\(done.formatted()) of \(total.formatted())"
        case .percent(let f):
            return "\(Int((max(0, min(1, f)) * 100).rounded()))%"
        }
    }
}
// ========== BLOCK 02: STEP + PROGRESS - END ==========

// ========== BLOCK 03: VOICE (two label skins + switch) - START ==========
public enum PrepVoice: String, Sendable {
    /// Plain, literal engineering labels — what WE want while building.
    case technical
    /// Posey's in-character voice (Parker Posey's Mary in *Party Girl*): witty,
    /// stylish, a little imperious, secretly devoted to the book — what USERS see.
    case inCharacter

    /// The active voice. Defaults to `.technical` during development; flip to
    /// `.inCharacter` for release (and the dev toggle in the Advanced sheet lets
    /// us preview either). Read on the main actor by the UI.
    @MainActor public static var current: PrepVoice = .technical
}

extension PrepStep {
    /// The label prefix for this step in the given voice. The in-character lines
    /// are drafts in Mary's register — tune the wording here without touching any
    /// plumbing (that's the whole point of keeping the step separate from its skin).
    func label(_ voice: PrepVoice) -> String {
        switch voice {
        case .technical:
            switch self {
            case .opening:         return "Opening the document"
            case .readingPages:    return "Reading the pages"
            case .scanningPages:   return "OCR — scanning pages"
            case .findingChapters: return "Finding chapters"
            case .layingOutText:   return "Building reading units"
            case .savingDocument:  return "Saving"
            case .rescanningPages: return "OCR — re-scanning pages"
            case .chunking:        return "Chunking"
            case .embedding:       return "Embedding"
            case .studyingUp:      return "RAPTOR summary tree"
            }
        case .inCharacter:
            switch self {
            case .opening:         return "Cracking open your book"
            case .readingPages:    return "Turning the pages"
            case .scanningPages:   return "Squinting at the blurry bits"
            case .findingChapters: return "Sorting out where the chapters live"
            case .layingOutText:   return "Setting the type, darling"
            case .savingDocument:  return "Tucking it onto the shelf"
            case .rescanningPages: return "Taking a closer look at the messy pages"
            case .chunking:        return "Breaking it into bite-size pieces"
            case .embedding:       return "Reading ahead"
            case .studyingUp:      return "Studying up"
            }
        }
    }
}
// ========== BLOCK 03: VOICE - END ==========

// ========== BLOCK 04: ACTIVITY VALUE - START ==========
/// A document's current step + progress. This is what the tracker stores and
/// both surfaces render — one value, one truth.
public struct PrepActivity: Sendable, Equatable {
    public var step: PrepStep
    public var progress: StepProgress

    public init(step: PrepStep, progress: StepProgress = .working) {
        self.step = step
        self.progress = progress
    }

    /// The full one-line display in the given voice: "Label — N of M" / "Label — P%"
    /// / "Label…". This is the single formatter both the toast and the board use.
    @MainActor public func display() -> String { display(PrepVoice.current) }

    public func display(_ voice: PrepVoice) -> String {
        let name = step.label(voice)
        if let p = progress.text { return "\(name) — \(p)" }
        return "\(name)…"
    }
}
// ========== BLOCK 04: ACTIVITY VALUE - END ==========
