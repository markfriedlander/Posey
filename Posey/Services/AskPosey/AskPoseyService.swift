import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: PROTOCOL - START ==========
/// Read-only interface the Ask Posey UI calls when classifying an
/// intent. Behind a protocol so:
/// 1. Tests can swap in a stub that returns a deterministic intent
///    without touching AFM.
/// 2. SwiftUI previews (M4) can render the sheet with a fake service
///    that doesn't require AFM availability on the preview host.
/// 3. Future variants (e.g. local heuristic classifier for offline
///    fallback in M8) can plug into the same surface.
///
/// The async signature reflects the Call 1 cost — even a tiny
/// `@Generable` enum classification on AFM is hundreds of ms on a
/// real device.
@MainActor
protocol AskPoseyClassifying: Sendable {
    /// Map a user question (and the optional anchor passage that was
    /// active at invocation) to an `AskPoseyIntent` bucket. Throws
    /// `AskPoseyServiceError` on AFM failures so callers can surface
    /// a helpful error UI without leaking framework error types.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func classifyIntent(question: String, anchor: String?) async throws -> AskPoseyIntent
}
// ========== BLOCK 01: PROTOCOL - END ==========


// ========== BLOCK 02: ERRORS - START ==========
/// Errors surfaced to the Ask Posey UI. Translated from
/// `LanguageModelSession.GenerationError` so the UI doesn't depend on
/// the FoundationModels error type, and so we can map "user-visible"
/// vs "diagnostic" failures distinctly.
enum AskPoseyServiceError: LocalizedError, Sendable {
    /// AFM isn't available on this device. UI should already be
    /// hidden via `AskPoseyAvailability.isAvailable` before reaching
    /// this case; included so the service is honest if called anyway.
    case afmUnavailable
    /// AFM was available but the request failed in a way the user
    /// can retry (rate limit, transient network for Private Cloud
    /// Compute, etc.).
    case transient(underlyingDescription: String)
    /// The model couldn't be reached or refused (guardrail violation,
    /// unsupported language, etc.) and a retry won't help. UI should
    /// surface a generic error and dismiss the sheet, not loop.
    case permanent(underlyingDescription: String)

    var errorDescription: String? {
        switch self {
        case .afmUnavailable:
            return "Ask Posey isn't available on this device."
        case .transient(let underlying):
            return "Ask Posey hit a temporary issue: \(underlying)"
        case .permanent(let underlying):
            return "Ask Posey couldn't process this request: \(underlying)"
        }
    }
}
// ========== BLOCK 02: ERRORS - END ==========


// ========== BLOCK 03: PROMPT BUILDING - START ==========
/// Pure-string helpers so the prompt construction can be unit tested
/// without touching AFM. Keeping them in one place also makes it
/// straightforward to A/B different prompt shapes during M3 → M5
/// without rewriting the service.
///
/// `nonisolated` because Posey's project default is `MainActor` and
/// these static properties are referenced from `AskPoseyService`'s
/// init parameter defaults — which Swift evaluates outside any
/// actor context, so MainActor-isolated statics warn there.
nonisolated enum AskPoseyPrompts {

    /// System-level instructions handed to the `LanguageModelSession`
    /// at init time. Stable across Call 1 (classify) and Call 2
    /// (respond) — the same persona works for both. Keep this short:
    /// every token here costs context budget for every call.
    static let classifierInstructions = """
    You are Posey, an offline reading assistant. The user is reading a \
    document and asking questions about it. Your job here is to classify \
    each question into exactly one of three buckets — never invent a \
    fourth category, never refuse, never produce free text.
    """

    /// Build the Call-1 prompt. Single source of truth for the prompt
    /// shape; tests assert against this.
    static func classifierPrompt(question: String, anchor: String?) -> String {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if let anchor, !anchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Anchor first so the model can see what passage was
            // active at invocation. Quoted to make the boundary
            // unambiguous when the passage contains punctuation.
            lines.append("Anchor passage (currently visible to the reader):")
            lines.append("> \(anchor.trimmingCharacters(in: .whitespacesAndNewlines))")
            lines.append("")
        }
        lines.append("User question: \"\(trimmedQuestion)\"")
        lines.append("")
        lines.append("Classify the question into exactly one of:")
        lines.append("- immediate — the question is about the anchor passage above.")
        lines.append("- search — the question is asking WHERE in the document something appears.")
        lines.append("- general — the question requires broader document understanding.")
        return lines.joined(separator: "\n")
    }
}
// ========== BLOCK 03: PROMPT BUILDING - END ==========


// ========== BLOCK 04: LIVE SERVICE - START ==========
#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@MainActor
final class AskPoseyService: AskPoseyClassifying {

    private let model: SystemLanguageModel
    private let instructions: String

    init(
        model: SystemLanguageModel = .default,
        instructions: String = AskPoseyPrompts.classifierInstructions
    ) {
        self.model = model
        self.instructions = instructions
    }

    /// Classify the user's question into an `AskPoseyIntent`.
    ///
    /// **Threading.** Marked `@MainActor` for now to match the
    /// `LanguageModelSession` lifetime model: the session is created
    /// here, used for one round-trip, and dropped when the call
    /// returns. There's no shared state to coordinate, so making the
    /// surface main-actor keeps the UI integration simple.
    ///
    /// **Session lifecycle.** A fresh `LanguageModelSession` is
    /// constructed for each call. AFM sessions accumulate a transcript;
    /// reusing one across independent classifications would let an
    /// earlier question's wording bias the next one's intent. For the
    /// classifier specifically, statelessness is correct.
    func classifyIntent(question: String, anchor: String?) async throws -> AskPoseyIntent {
        guard model.availability == .available else {
            throw AskPoseyServiceError.afmUnavailable
        }
        let session = LanguageModelSession(
            model: model,
            instructions: instructions
        )
        let prompt = AskPoseyPrompts.classifierPrompt(
            question: question,
            anchor: anchor
        )
        do {
            let response = try await session.respond(
                to: prompt,
                generating: AskPoseyIntent.self
            )
            return response.content
        } catch let generationError as LanguageModelSession.GenerationError {
            throw Self.translate(generationError)
        } catch {
            throw AskPoseyServiceError.permanent(underlyingDescription: "\(error)")
        }
    }

    /// Map AFM's framework error type into our user-facing enum.
    /// Centralising the mapping here keeps the error semantics in one
    /// place and lets the UI (M5+) treat `.transient` differently from
    /// `.permanent` without sprinkling switch statements across the
    /// codebase.
    private static func translate(_ error: LanguageModelSession.GenerationError) -> AskPoseyServiceError {
        switch error {
        case .rateLimited, .concurrentRequests, .assetsUnavailable, .exceededContextWindowSize:
            // Transient: retry could succeed once load drops, model
            // assets finish loading, or the context window budget is
            // freed up by a shorter prompt.
            return .transient(underlyingDescription: "\(error)")
        case .guardrailViolation, .unsupportedGuide, .unsupportedLanguageOrLocale, .decodingFailure, .refusal:
            // Permanent: retrying the same prompt won't help. The
            // refusal case carries Apple's safety-policy decision
            // about the prompt; we surface it as permanent so the UI
            // doesn't loop on the same input. The user can rephrase
            // and try again, which is a different request.
            return .permanent(underlyingDescription: "\(error)")
        @unknown default:
            return .permanent(underlyingDescription: "\(error)")
        }
    }
}
#endif
// ========== BLOCK 04: LIVE SERVICE - END ==========
