import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: INTENT - START ==========
/// The three buckets the Ask Posey intent classifier maps every user
/// question into. The two-call pattern (see `ask_posey_spec.md` §3 and
/// `ask_posey_implementation_plan.md` §5) uses this enum as the
/// `@Generable` schema for Call 1 — Apple Foundation Models is
/// constrained to fill exactly one of the three cases, which Call 2
/// then uses to choose what context to inject into the response prompt.
///
/// Why an enum, not free text:
/// - With `@Generable`, AFM is forced to pick a valid case. We never
///   parse free text or fight the model on capitalisation / spelling.
/// - The enum is `String`-raw-value for two side benefits: trivial
///   logging / persistence, and easy round-tripping in unit tests.
///
/// `@available(iOS 26.0, ...)` follows the FoundationModels framework
/// availability. Older devices fall through to
/// `AskPoseyAvailability.frameworkUnavailable` and the entire Ask
/// Posey UI is hidden — we never need to construct an `AskPoseyIntent`
/// there, so the availability gate keeps this file from being a
/// compile-time burden on older SDKs.
#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
enum AskPoseyIntent: String, Sendable, CaseIterable, Codable {

    /// The user's question is about the passage currently being read.
    /// Call 2 should answer from the anchor passage plus 2-3 sentences
    /// of surrounding context — no RAG required.
    case immediate

    /// The user wants to find a specific section elsewhere in the
    /// document ("Where does the author discuss X?", "Take me to the
    /// chapter about Y"). Call 2 should run RAG retrieval and return
    /// navigation cards, not prose.
    case search

    /// The user wants broader document understanding ("Summarise this
    /// chapter", "What are the main arguments?"). Call 2 should pull
    /// the rolling summary plus RAG retrieval.
    case general
}
#endif
// ========== BLOCK 01: INTENT - END ==========
