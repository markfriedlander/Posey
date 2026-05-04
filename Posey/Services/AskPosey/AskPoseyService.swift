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

/// Metadata carried alongside a completed prose response. The view
/// model uses these fields to (a) persist the assistant turn into
/// `ask_posey_conversations` with the right diagnostics, (b) surface
/// the M7 "Sources" attribution strip when chunks have made it in
/// (M5 always reports an empty array), and (c) support the local-API
/// tuning loop's "what did the model see, what got dropped" view.
struct AskPoseyResponseMetadata: Sendable, Equatable {
    /// Final assistant message text. Same value the streaming
    /// callback's last snapshot delivered, captured here for the
    /// caller's persistence path so race conditions on snapshot
    /// observation don't corrupt the saved row.
    let finalText: String
    /// Total prompt tokens estimated by `AskPoseyTokenEstimator` —
    /// scaffolding included. Recorded per turn for tuning.
    let promptTokenTotal: Int
    /// Per-section token costs.
    let breakdown: AskPoseyPromptTokenBreakdown
    /// Drops applied during prompt assembly, with reasons.
    let droppedSections: [AskPoseyPromptDroppedSection]
    /// Document chunks that actually made it into the prompt. M5: [].
    /// Persisted as JSON in `ask_posey_conversations.chunks_injected`.
    let chunksInjected: [RetrievedChunk]
    /// Verbatim prompt body the model saw — instructions + rendered
    /// body joined. Persisted as `full_prompt_for_logging`.
    let fullPromptForLogging: String
    /// AFM round-trip duration end-to-end (first request to last
    /// snapshot). Useful for budget-tuning correlation against
    /// response-quality observations.
    let inferenceDuration: TimeInterval
}

/// Streaming prose interface. Same protocol-driven test/preview
/// substitution rationale as `AskPoseyClassifying`. The closure is
/// invoked each time AFM emits a snapshot — the view model uses it
/// to update the assistant bubble's content in place. The closure is
/// `@MainActor` because AFM's stream emits on a background queue and
/// the view model needs to mutate `@Published` state.
@MainActor
protocol AskPoseyStreaming: Sendable {
    /// Build a prompt from `inputs`, run a fresh `LanguageModelSession`
    /// against the system instructions, stream the response, and
    /// return final metadata. Each snapshot delivers the **accumulated**
    /// content so the view model can simply assign it to the assistant
    /// bubble without diffing.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func streamProseResponse(
        inputs: AskPoseyPromptInputs,
        budget: AskPoseyTokenBudget,
        onSnapshot: @MainActor @Sendable (String) -> Void
    ) async throws -> AskPoseyResponseMetadata
}

/// Conversation summarization interface for the M6 hard-blocker
/// auto-summarizer. The view model awaits an in-flight call before
/// building its next prompt so the conversation summary is always
/// current. Same fresh-session-per-call lifecycle as the prose path.
@MainActor
protocol AskPoseySummarizing: Sendable {
    /// Compress a span of older conversation turns into a short prose
    /// summary suitable for the prompt builder's `conversationSummary`
    /// slot. Returns the summary text on success; throws an
    /// `AskPoseyServiceError` translation of any AFM error so the
    /// caller can decide whether to retry or fall back to no-summary.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func summarizeConversation(turns: [AskPoseyMessage]) async throws -> String

    /// Task 4 #9 (2026-05-03) — pairwise summarization mode.
    /// Compresses a single Q&A exchange into a third-person prose
    /// summary sized to `targetSentences`. Used by
    /// `AskPoseyPairwiseSummarizer` to build tiered per-pair
    /// summaries that replace verbatim STM in the parallel
    /// summarization mode.
    ///
    /// - `targetSentences`: 1 (older pair, terse), 2–3 (mid),
    ///   4–5 (most recent pair, fuller). Caller picks tier;
    ///   summarizer obeys.
    /// - `failingSentence`: when non-nil, the caller has flagged a
    ///   prior summary attempt as not embedding-supported by the
    ///   verbatim exchange. The model is prompted to RE-SUMMARIZE
    ///   with explicit faithfulness reinforcement; the failing
    ///   sentence text is included so the model can avoid the
    ///   unsupported claim.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func summarizePair(
        question: String,
        answer: String,
        targetSentences: Int,
        failingSentence: String?
    ) async throws -> String
}

// AskPoseyNavigating is declared in AskPoseyNavigationCards.swift; the
// live AskPoseyService extension below conforms.
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
final class AskPoseyService: AskPoseyClassifying, AskPoseyStreaming, AskPoseySummarizing, AskPoseyNavigating {

    private let model: SystemLanguageModel
    private let instructions: String
    /// Temperature for the GROUNDED call (Mark's "what did I find").
    /// Low — accuracy first, no creative drift. Real Q&A iteration
    /// settled on 0.1: anything higher introduced stochastic
    /// "drops Mark Friedlander" failures on the AI Book test.
    private let groundedTemperature: Double

    /// Temperature for the POLISH call (Mark's "make it sound like
    /// Posey"). Warmer so the rewrite reads conversational, slightly
    /// irreverent, present. Per Mark 2026-05-02: "0.1 is too cold.
    /// A robotic Posey is a failed Posey regardless of factual
    /// accuracy." Started at 0.7; dropped to 0.5 after first
    /// real-Q&A test revealed the polish call inventing an ISBN
    /// when the grounded answer said "doesn't say."
    ///
    /// **2026-05-02 second iteration.** After the integrated UI test
    /// on real device, real Q&A showed polish at 0.55 was producing
    /// near-identical-to-grounded output for terse factual answers
    /// ("Who are the authors?" → grounded text passed through with
    /// trivial reordering). Root cause was the polish prompt rules
    /// pulling the model toward minimal change. Prompt was rebalanced
    /// (explicit DOs alongside DON'Ts, "stay close to length" instead
    /// of "match the length"). First attempt at 0.65 overshot — model
    /// invented metaphors describing the document's people ("Mark is
    /// like the DJ in the room", "the methodology is like a dance",
    /// "it's a bit like a game of charades"). Settled at 0.6 with the
    /// prompt re-tightened around "don't invent metaphors that
    /// describe the document's people, topics, or events" — the DOs
    /// stay in place so voice still emerges, but metaphor-padding is
    /// explicitly out of bounds.
    private let polishTemperature: Double

    init(
        model: SystemLanguageModel = .default,
        instructions: String = AskPoseyPrompts.classifierInstructions,
        groundedTemperature: Double = 0.1,
        polishTemperature: Double = 0.65
    ) {
        self.model = model
        self.instructions = instructions
        self.groundedTemperature = groundedTemperature
        self.polishTemperature = polishTemperature
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

    /// Stream a prose response for an Ask Posey turn.
    ///
    /// **Lifecycle.** A fresh `LanguageModelSession` is created here,
    /// used for one streaming round-trip, and dropped when the function
    /// returns. AFM sessions accumulate a transcript across calls;
    /// reusing one would let an earlier turn's wording bias the next.
    /// Per Mark's directive (2026-05-01): the app owns the context,
    /// not the model. Every byte the model sees on this turn is
    /// explicitly placed there by `AskPoseyPromptBuilder`.
    ///
    /// **Threading.** `@MainActor` because the snapshot callback
    /// updates the chat view model's `@Published` state. The
    /// underlying `streamResponse` work runs on AFM's queue; we await
    /// each snapshot on main, which is fast — accumulated string
    /// assignment is constant time.
    func streamProseResponse(
        inputs: AskPoseyPromptInputs,
        budget: AskPoseyTokenBudget = .afmDefault,
        onSnapshot: @MainActor @Sendable (String) -> Void
    ) async throws -> AskPoseyResponseMetadata {

        guard model.availability == .available else {
            throw AskPoseyServiceError.afmUnavailable
        }

        let output = AskPoseyPromptBuilder.build(inputs, budget: budget)
        let started = Date()

        // ---- Call 1: GROUNDED (low temp, accuracy first) ----
        // No streaming to user — the grounded text isn't what the
        // user sees. The polish call streams to user.
        var grounded = ""
        do {
            grounded = try await runGroundedCall(
                instructions: output.instructions,
                body: output.renderedBody
            )
            dbgLog("AskPosey: grounded call returned %d chars", grounded.count)
        } catch is CancellationError {
            throw CancellationError()
        } catch let originalError {
            dbgLog("AskPosey: grounded call threw: type=%@ description=%@",
                  String(describing: type(of: originalError)),
                  String(describing: originalError).prefix(200) as CVarArg)
            // Refusal-retry per Mark 2026-05-02: detect refusal both
            // by typed-case match (preferred) AND by stringified
            // payload (defensive — `if case .refusal = g` proved
            // unreliable on AFM's macro-generated enum case in this
            // Swift toolchain). Either path leads to the retry; the
            // string check is the safety net.
            let isRefusal: Bool
            if let g = originalError as? LanguageModelSession.GenerationError {
                // Multiple defenses against pattern-matching quirks
                // on AFM's macro-generated enum: (1) full pattern
                // with associated value wildcards, (2) switch form,
                // (3) string-based fallback. Belt and suspenders
                // because the typed pattern was silently failing in
                // device tests despite the error clearly being a
                // refusal at runtime.
                let switched: Bool = {
                    switch g {
                    case .refusal:
                        return true
                    default:
                        return false
                    }
                }()
                let stringified = "\(g)"
                let stringContains = stringified.contains("refusal(")
                    || stringified.lowercased().contains("refusal")
                isRefusal = switched || stringContains
                dbgLog("AskPosey: refusal-detection switched=%@ stringContains=%@ stringified=%@",
                      String(describing: switched),
                      String(describing: stringContains),
                      stringified.prefix(120) as CVarArg)
            } else {
                isRefusal = "\(originalError)".contains("refusal(")
            }

            if isRefusal {
                dbgLog("AskPosey: grounded call refused; retrying with neutral rephrasing")
                let rephrased = AskPoseyPromptBuilder.neutralRephrasingPromptBody(
                    originalUserQuestion: inputs.currentQuestion,
                    originalRenderedBody: output.renderedBody
                )
                do {
                    grounded = try await runGroundedCall(
                        instructions: output.instructions,
                        body: rephrased
                    )
                    dbgLog("AskPosey: neutral-rephrasing retry succeeded")
                } catch is CancellationError {
                    throw CancellationError()
                } catch let retryError {
                    let isRetryRefusal: Bool
                    if let r = retryError as? LanguageModelSession.GenerationError {
                        let switched: Bool = {
                            switch r {
                            case .refusal: return true
                            default: return false
                            }
                        }()
                        let s = "\(r)"
                        let stringContains = s.contains("refusal(") || s.lowercased().contains("refusal")
                        isRetryRefusal = switched || stringContains
                        dbgLog("AskPosey: retry refusal-detection switched=%@ stringContains=%@ s=%@",
                              String(describing: switched),
                              String(describing: stringContains),
                              s.prefix(120) as CVarArg)
                    } else {
                        isRetryRefusal = "\(retryError)".lowercased().contains("refusal")
                    }
                    if isRetryRefusal {
                        dbgLog("AskPosey: retry also refused; surfacing informative failure")
                        throw AskPoseyServiceError.permanent(
                            underlyingDescription: "informativeRefusalFailure"
                        )
                    }
                    if let r = retryError as? LanguageModelSession.GenerationError {
                        throw Self.translate(r)
                    }
                    throw AskPoseyServiceError.permanent(underlyingDescription: "\(retryError)")
                }
            } else if isContextWindowOverflow(originalError) {
                // Task 4 #3 — exceeded-context-window retry. Our
                // chars-per-token estimator under-counts AFM's actual
                // tokenization by ~10–30% in pathological cases. When
                // we hit AFM's hard ceiling, rebuild the prompt with
                // every droppable section emptied (drop ALL RAG,
                // drop summary, drop STM) and retry once. The user
                // question + anchor + system + surrounding survive
                // — same drop-priority spirit as #2, just more
                // aggressive when AFM tells us we overshot.
                dbgLog("AskPosey: grounded call exceeded context window — retrying with droppables stripped")
                let strippedInputs = AskPoseyPromptInputs(
                    intent: inputs.intent,
                    anchor: inputs.anchor,
                    surroundingContext: inputs.surroundingContext,
                    conversationHistory: [],
                    conversationSummary: nil,
                    documentChunks: [],
                    currentQuestion: inputs.currentQuestion
                )
                let strippedOutput = AskPoseyPromptBuilder.build(strippedInputs, budget: budget)
                do {
                    grounded = try await runGroundedCall(
                        instructions: strippedOutput.instructions,
                        body: strippedOutput.renderedBody
                    )
                    dbgLog("AskPosey: stripped-prompt retry succeeded (%d chars)", grounded.count)
                } catch {
                    dbgLog("AskPosey: stripped-prompt retry also failed; surfacing informative failure")
                    throw AskPoseyServiceError.permanent(
                        underlyingDescription: "informativeRefusalFailure"
                    )
                }
            } else {
                // Debug marker so we can see which path threw when
                // the user-facing error appears.
                if let g = originalError as? LanguageModelSession.GenerationError {
                    dbgLog("AskPosey: NOT classified as refusal; translating raw")
                    throw AskPoseyServiceError.permanent(
                        underlyingDescription: "[NO-RETRY-PATH-typed] \(g)"
                    )
                }
                throw AskPoseyServiceError.permanent(
                    underlyingDescription: "[NO-RETRY-PATH-untyped] \(originalError)"
                )
            }
        }

        // ---- Task 4 #7 — anti-fabrication entity check ----
        // Extract named entities from the grounded answer; compare
        // to entities present in the injected RAG chunks (and
        // anchor + surrounding). Any answer entity NOT grounded in
        // the prompt material is a fabrication signal.
        //
        // On hit: re-prompt with explicit "if the document doesn't
        // say, say so" framing using the existing
        // `neutralRephrasingPromptBody` helper. If the retry also
        // fabricates (or refuses), throw `informativeRefusalFailure`
        // so the friendly fallback bubble surfaces.
        //
        // Surfaced in Task 3: DOCX hallucinated "presented at AAAI
        // Conference and ICML Conference" on a refusal-test
        // question; EPUB hallucinated "Peter Jackson said Joe Malik
        // wasn't on a paranoid trip" attributing a character's
        // speech to "the author." Both had 0 citations because
        // embedding attribution couldn't ground them — but the user
        // saw the fabrication regardless. Now we catch it before
        // polish runs.
        if let ungrounded = ungroundedEntities(in: grounded, against: output, inputs: inputs),
           !ungrounded.isEmpty {
            dbgLog("AskPosey: grounded answer contains %d ungrounded entities: %@ — retrying with explicit refusal framing",
                  ungrounded.count,
                  Array(ungrounded).joined(separator: ", ") as NSString)
            let rephrased = AskPoseyPromptBuilder.neutralRephrasingPromptBody(
                originalUserQuestion: inputs.currentQuestion,
                originalRenderedBody: output.renderedBody
            )
            do {
                let retried = try await runGroundedCall(
                    instructions: output.instructions,
                    body: rephrased
                )
                dbgLog("AskPosey: anti-fabrication retry returned %d chars", retried.count)
                // Validate the retry too. If it ALSO fabricates,
                // the question is genuinely outside the document
                // and the model can't be trusted on it — surface
                // the friendly fallback.
                if let stillUngrounded = ungroundedEntities(in: retried, against: output, inputs: inputs),
                   !stillUngrounded.isEmpty {
                    dbgLog("AskPosey: retry still ungrounded (%@) — surfacing informative failure",
                          Array(stillUngrounded).joined(separator: ", ") as NSString)
                    throw AskPoseyServiceError.permanent(
                        underlyingDescription: "informativeRefusalFailure"
                    )
                }
                grounded = retried
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                dbgLog("AskPosey: anti-fabrication retry threw — surfacing informative failure")
                throw AskPoseyServiceError.permanent(
                    underlyingDescription: "informativeRefusalFailure"
                )
            }
        }

        // ---- Call 2: POLISH (Posey's voice, warmer temp) ----
        // Streams to user. On polish failure, fall back gracefully
        // to the grounded text so the user gets the right answer
        // even if the voice rewrite breaks.
        //
        // **Refusal-shape guard.** If the grounded answer is a
        // not-in-the-document response, skip the polish entirely.
        // The polish call at temp 0.5 has demonstrated capacity to
        // invent specific facts (e.g. an ISBN) when given an empty
        // draft and a question implying a number-shaped answer. The
        // grounded answer is already short and clean; polishing it
        // is high-risk, low-reward.
        let groundedLower = grounded.lowercased()
        let refusalShape = [
            "the document doesn't say",
            "the document does not say",
            "doesn't say",
            "does not say",
            "the document doesn't mention",
            "the document does not mention",
            "doesn't mention",
            "isn't mentioned",
            "is not mentioned",
            "not in the document",
            "not present in",
            "the document doesn't specify",
            "the document does not specify",
            "doesn't specify"
        ].contains(where: { groundedLower.contains($0) })

        // AFM safety refusal — model declines to answer due to its
        // own content policy (Illuminatus / certain topics trigger
        // this). Phrases include "as an AI", "I cannot comply",
        // "I can't help with", "I'm sorry, but". Rewrite the
        // grounded answer to a neutral "doesn't say" so the user
        // doesn't see Apple's safety boilerplate for an in-document
        // question. Verified on EPUB Q2 ("Who is Hagbard Celine?")
        // in Three Hats QA — AFM refused due to Illuminatus topic.
        let afmSafetyRefusal = [
            "as an ai",
            "i cannot comply",
            "i can't help with",
            "i'm not able to help",
            "i'm sorry, but as",
            "i am not able to comply",
            "i'm sorry, but i",
            "harmful and inappropriate",
            "promotes harmful"
        ].contains(where: { groundedLower.contains($0) })

        let groundedFinal: String
        if afmSafetyRefusal {
            dbgLog("AskPosey: AFM safety refusal detected — rewriting to neutral refusal")
            groundedFinal = "The document doesn't have a clear answer to that."
        } else {
            groundedFinal = grounded
        }
        let refusalShapeFinal = refusalShape || afmSafetyRefusal

        // Task 2 — clean separation of concerns: polish ALWAYS runs.
        // No special cases. Voice is polish's job; citations are
        // embedding attribution's job (downstream in the chat view
        // model's `finalizeAssistantTurn`). Refusal-shape responses
        // are the one structural exception — there's nothing to
        // polish into voice when the grounded answer is "the
        // document doesn't say."
        var accumulated = ""
        if refusalShapeFinal {
            // Stream the grounded text through verbatim. The
            // grounded call's wording is already short and clean
            // ("The document doesn't say.") — no polish needed.
            accumulated = groundedFinal
            onSnapshot(groundedFinal)
        } else {
            do {
                let polishSession = LanguageModelSession(
                    model: model,
                    instructions: AskPoseyPromptBuilder.polishInstructions
                )
                let polishBody = AskPoseyPromptBuilder.polishPromptBody(
                    question: inputs.currentQuestion,
                    groundedDraft: groundedFinal
                )
                let stream = polishSession.streamResponse(
                    options: GenerationOptions(temperature: polishTemperature)
                ) { Prompt(polishBody) }
                for try await snapshot in stream {
                    accumulated = snapshot.content
                    onSnapshot(accumulated)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Polish failed (refusal, transient, anything). Fall
                // back to the grounded answer — better to ship a
                // robotic-but-correct reply than nothing.
                accumulated = groundedFinal
                onSnapshot(groundedFinal)
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        return AskPoseyResponseMetadata(
            finalText: accumulated,
            promptTokenTotal: output.tokenBreakdown.totalIncludingScaffolding,
            breakdown: output.tokenBreakdown,
            droppedSections: output.droppedSections,
            chunksInjected: output.chunksInjected,
            fullPromptForLogging: output.combinedForLogging,
            inferenceDuration: elapsed
        )
    }

    /// Task 4 #7 anti-fabrication helper. Returns the set of
    /// named entities present in `answer` but NOT in any of the
    /// excerpts the prompt builder fed AFM (anchor + surrounding
    /// + every retrieved RAG chunk). An ungrounded entity is the
    /// strongest local signal for fabrication: the model named
    /// someone the document didn't.
    ///
    /// Returns nil when there's no way to validate (no chunks +
    /// no anchor + no surrounding). That's effectively trust-the-
    /// model territory; the fallback for genuinely-no-context
    /// answers is the existing refusal-shape guard downstream.
    private func ungroundedEntities(
        in answer: String,
        against output: AskPoseyPromptOutput,
        inputs: AskPoseyPromptInputs
    ) -> Set<String>? {
        // Build the haystack: every text source the model legitimately
        // saw. Anchor passage + surrounding context + each RAG chunk
        // + conversation history (user may have mentioned a name in
        // a prior turn we should accept).
        var haystack = ""
        if let anchorText = inputs.anchor?.trimmedDisplayText {
            haystack += " "; haystack += anchorText
        }
        if let surrounding = inputs.surroundingContext {
            haystack += " "; haystack += surrounding
        }
        for chunk in inputs.documentChunks {
            haystack += " "; haystack += chunk.text
        }
        for msg in inputs.conversationHistory {
            haystack += " "; haystack += msg.content
        }
        guard !haystack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let haystackLower = haystack.lowercased()

        // Three sources of candidate ungrounded entities, unioned:
        //   (1) NLTagger named entities — best for clean person/
        //       place names ("Joe Malik", "New York")
        //   (2) Quoted strings — AFM tends to enclose fabricated
        //       proper-noun names in quotes ("AI Ethics Conference",
        //       "Law of Fives"). NLTagger misses these because the
        //       common words throw the classifier.
        //   (3) Title-Case multi-word capitalizations — catches
        //       ungrounded proper-noun phrases the other two miss
        //       ("Machine Learning Summit", "At the Mountains of
        //       Madness"). Single capitalized words are excluded
        //       (too noisy — sentence-initial words trip it).
        var candidates: Set<String> = []
        for e in DocumentEmbeddingIndex.extractEntities(from: answer) {
            candidates.insert(e)
        }
        candidates.formUnion(extractQuotedStrings(from: answer))
        candidates.formUnion(extractTitleCasePhrases(from: answer))

        guard !candidates.isEmpty else { return nil }

        var ungrounded: Set<String> = []
        for entity in candidates {
            if entity.count < 4 { continue }   // ignore "AI", "Mr"
            if haystackLower.contains(entity) { continue }
            ungrounded.insert(entity)
        }
        return ungrounded
    }

    /// Extract quoted string contents from `text`. Both straight
    /// and curly quotes. Lowercased + trimmed for haystack
    /// comparison.
    private func extractQuotedStrings(from text: String) -> Set<String> {
        var out = Set<String>()
        let patterns = [
            #""([^"]{3,80})""#,            // straight double quotes
            #"'([^']{3,80})'"#,            // straight single quotes
            "\u{201C}([^\u{201D}]{3,80})\u{201D}",  // curly double
        ]
        for pat in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat) else { continue }
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for m in matches where m.numberOfRanges >= 2 {
                let inner = nsText.substring(with: m.range(at: 1))
                let lowered = inner.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if lowered.count >= 4 { out.insert(lowered) }
            }
        }
        return out
    }

    /// Extract Title Case multi-word phrases (≥ 2 capitalized
    /// words in a row). Skips sentence-initial single words.
    private func extractTitleCasePhrases(from text: String) -> Set<String> {
        var out = Set<String>()
        let pattern = #"\b([A-Z][a-zA-Z]+(?:\s+(?:[A-Z][a-zA-Z]+|of|the|and|in|on|for|to|at)){1,7}\s+[A-Z][a-zA-Z]+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for m in matches where m.numberOfRanges >= 2 {
            let phrase = nsText.substring(with: m.range(at: 1))
            let lowered = phrase.lowercased()
            if lowered.count >= 6 { out.insert(lowered) }
        }
        return out
    }

    /// True when `error` is a `LanguageModelSession.GenerationError`
    /// of case `.exceededContextWindowSize` (the AFM hard ceiling).
    /// Belt-and-suspenders: typed pattern match plus stringified
    /// fallback because AFM's macro-generated enum cases have been
    /// unreliable to pattern-match in this Swift toolchain.
    private func isContextWindowOverflow(_ error: Error) -> Bool {
        if let g = error as? LanguageModelSession.GenerationError {
            switch g {
            case .exceededContextWindowSize: return true
            default: break
            }
            let s = "\(g)".lowercased()
            return s.contains("exceededcontextwindowsize")
                || s.contains("exceeds the maximum allowed context size")
        }
        return "\(error)".lowercased().contains("exceededcontextwindowsize")
    }

    /// Single grounded-call helper — low-temp, no streaming, returns
    /// the full accumulated text. Used both for the primary attempt
    /// and the neutral-rephrasing retry. Throws raw
    /// `LanguageModelSession.GenerationError` so the caller can
    /// pattern-match `.refusal` and decide on retry; other errors
    /// bubble unchanged.
    private func runGroundedCall(instructions: String, body: String) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        var accumulated = ""
        let stream = session.streamResponse(
            options: GenerationOptions(temperature: groundedTemperature)
        ) { Prompt(body) }
        for try await snapshot in stream {
            accumulated = snapshot.content
        }
        return accumulated
    }

    /// Summarize a span of older conversation turns into a short
    /// prose summary. M6 hard-blocker per Mark's M5 architectural
    /// correction — without this, M5's STM window quietly drops
    /// older turns from the model's view as conversations grow past
    /// ~3-4 turns. The cached summary lives in `ask_posey_conversations`
    /// as an `is_summary = 1` row, surfaced to the prompt builder via
    /// `AskPoseyPromptInputs.conversationSummary`.
    ///
    /// Same per-call lifecycle as the prose path: fresh
    /// `LanguageModelSession`, dies when the function returns.
    /// Temperature held at 0.2 — summarization wants determinism, not
    /// creative reinterpretation.
    func summarizeConversation(turns: [AskPoseyMessage]) async throws -> String {
        guard model.availability == .available else {
            throw AskPoseyServiceError.afmUnavailable
        }
        guard !turns.isEmpty else { return "" }

        let summaryInstructions = """
        You are summarizing an earlier portion of a reading-companion \
        conversation between a user and an AI named Posey. Your job is \
        to compress the exchange into a brief, faithful summary so the \
        rest of the conversation can continue with shared context. \
        Keep it short (3–6 sentences). Capture: the topics discussed, \
        any specific passages or document sections referenced, and any \
        commitments Posey made about what it found. Skip greetings and \
        meta-talk. Never invent — only summarize what actually happened.
        """

        var transcriptLines: [String] = []
        for turn in turns {
            let speaker = turn.role == .user ? "User" : "Posey"
            transcriptLines.append("\(speaker): \(turn.content)")
        }
        let body = """
        Conversation to summarize:

        \(transcriptLines.joined(separator: "\n\n"))
        """

        let session = LanguageModelSession(
            model: model,
            instructions: summaryInstructions
        )
        var accumulated = ""
        do {
            let stream = session.streamResponse(
                options: GenerationOptions(temperature: 0.2)
            ) { Prompt(body) }
            for try await snapshot in stream {
                accumulated = snapshot.content
            }
        } catch let g as LanguageModelSession.GenerationError {
            throw Self.translate(g)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AskPoseyServiceError.permanent(underlyingDescription: "\(error)")
        }
        return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ========== BLOCK 09B: PAIRWISE SUMMARIZATION (Task 4 #9) - START ==========
    /// Task 4 #9 — single-pair summarizer for the parallel summarization
    /// mode. Same fresh-session-per-call lifecycle as the prose path;
    /// temperature 0.2 (faithfulness over creativity).
    func summarizePair(
        question: String,
        answer: String,
        targetSentences: Int,
        failingSentence: String?
    ) async throws -> String {
        guard model.availability == .available else {
            throw AskPoseyServiceError.afmUnavailable
        }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || !a.isEmpty else { return "" }

        let target = max(1, min(targetSentences, 6))
        let lengthGuidance: String = {
            switch target {
            case 1: return "ONE short sentence (≤ 20 words)."
            case 2: return "TWO sentences."
            case 3: return "THREE sentences."
            case 4: return "FOUR sentences."
            default: return "\(target) sentences."
            }
        }()

        var instructions = """
        You compress one user/Posey exchange from a reading-companion \
        conversation into a brief, faithful third-person summary so a \
        future turn has shared context without re-reading the verbatim \
        exchange.

        HARD RULES:
        1. Length: \(lengthGuidance) Do not exceed this.
        2. Third person ("the user asked …", "Posey explained …"). \
        Never use first or second person.
        3. Faithful only — never invent specifics not in the exchange. \
        Better to drop a detail than to hallucinate one.
        4. No greetings, meta-talk, or quoting. Plain prose.
        5. Capture WHAT was asked and WHAT Posey said in response. \
        Skip filler.
        """
        if let failingSentence, !failingSentence.isEmpty {
            instructions += """


            REWRITE NOTICE: a previous attempt produced a sentence that \
            was not supported by the verbatim exchange:
            "\(failingSentence)"
            Avoid claims of that shape. Stick to what the exchange \
            literally says.
            """
        }

        let body = """
        EXCHANGE:
        User: \(q)

        Posey: \(a)
        """

        let session = LanguageModelSession(model: model, instructions: instructions)
        var accumulated = ""
        do {
            let stream = session.streamResponse(
                options: GenerationOptions(temperature: 0.2)
            ) { Prompt(body) }
            for try await snapshot in stream {
                accumulated = snapshot.content
            }
        } catch let g as LanguageModelSession.GenerationError {
            throw Self.translate(g)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AskPoseyServiceError.permanent(underlyingDescription: "\(error)")
        }
        return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // ========== BLOCK 09B: PAIRWISE SUMMARIZATION - END ==========

    /// M7 navigation cards — Call-2 path for `.search` intent.
    /// AFM is constrained via `@Generable` to pick 3–6 cards from
    /// the supplied candidate chunks; we resolve the chosen indices
    /// back to chunk metadata and return ready-to-render
    /// `AskPoseyNavigationCard` values.
    ///
    /// Same fresh-session-per-call lifecycle as the other surfaces.
    /// If AFM picks an out-of-range candidate index, we silently drop
    /// that card rather than crashing — defensive parsing because the
    /// `@Generable` schema can't constrain integers to a runtime-known
    /// range.
    func generateNavigationCards(
        question: String,
        candidates: [RetrievedChunk]
    ) async throws -> [AskPoseyNavigationCard] {
        guard model.availability == .available else {
            throw AskPoseyServiceError.afmUnavailable
        }
        guard !candidates.isEmpty else {
            // No retrieval results means nothing to navigate to. The
            // caller surfaces a "no matches" UI state.
            return []
        }
        let session = LanguageModelSession(
            model: model,
            instructions: AskPoseyNavigationPrompts.systemInstructions
        )
        let body = AskPoseyNavigationPrompts.body(question: question, candidates: candidates)
        do {
            let response = try await session.respond(
                to: body,
                generating: AskPoseyNavigationCardSet.self
            )
            return response.content.cards.compactMap { card in
                guard candidates.indices.contains(card.candidateIndex) else { return nil }
                let source = candidates[card.candidateIndex]
                return AskPoseyNavigationCard(
                    title: card.title,
                    reason: card.reason,
                    plainTextOffset: source.startOffset,
                    relevance: source.relevance,
                    chunkID: source.chunkID
                )
            }
        } catch let g as LanguageModelSession.GenerationError {
            throw Self.translate(g)
        } catch is CancellationError {
            throw CancellationError()
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
