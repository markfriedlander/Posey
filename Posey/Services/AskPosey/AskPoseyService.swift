import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

// 2026-05-23 — Step 8f: these notifications used to live on
// BackgroundEnhancementScheduler (which listened to pause itself
// during user AFM turns) and were extension-declared there. With
// the scheduler torn out, the only remaining poster is AskPoseyService
// itself; the names are kept so any future listener (or test
// harness) can still subscribe.
extension Notification.Name {
    static let askPoseyAFMDidBegin = Notification.Name("askPosey.afmDidBegin")
    static let askPoseyAFMDidEnd   = Notification.Name("askPosey.afmDidEnd")
}

// ========== BLOCK 01: PROTOCOL - START ==========
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
        case .transient:
            return "Posey ran into a temporary issue. Try again in a moment."
        case .permanent(let underlying):
            // Friendly user-facing wording for known internal codes.
            // Surfaced in the local-API /ask response and in the chat
            // bubble error path. Task 3 QA verified the prior raw
            // "informativeRefusalFailure" string was leaking to users.
            if underlying.contains("informativeRefusalFailure") {
                // Aligned 2026-05-04 with the weak-retrieval short-
                // circuit wording in AskPoseyChatViewModel — both the
                // "I have no chunks" path and the "AFM refused on the
                // chunks I have" path now point the user toward the
                // affordance that actually works (passage selection).
                return "I'm not finding a strong answer to that in the document. I do best when you select a sentence or passage you're curious about and ask me from there — try tapping a line in the reader, then asking again."
            }
            return "Posey couldn't answer that one. Try rephrasing the question or asking about a specific passage."
        }
    }

    /// Internal diagnostic detail for logs, NOT the user-facing string.
    /// Keep raw underlying codes here so debug builds can inspect them
    /// while production users see `errorDescription`.
    var diagnosticDetail: String {
        switch self {
        case .afmUnavailable:
            return "afmUnavailable"
        case .transient(let underlying):
            return "transient: \(underlying)"
        case .permanent(let underlying):
            return "permanent: \(underlying)"
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
        lines.append("- search — a WHERE/location question: the user mainly wants to know where in the document a specific named thing appears (a chapter, a section, a named passage). Canonical shapes: \"where is chapter 5\", \"where does the section about cetology start\", \"which chapter discusses Z\". Answer concisely with the location in prose (the part/chapter and a brief orienting phrase), not a long substantive treatment.")
        lines.append("- general — ANY question that wants a substantive answer about content, including interpretive, evaluative, comparative, thematic, descriptive, or summary questions. This is the default when in doubt. Even when the question uses verbs like \"find\", \"quote\", \"give me\", \"show me\", \"tell me about\", \"describe\", \"explain\", \"pick\", or contains the word \"passage\" / \"example\" / \"description\" — if the user wants the model to TELL them something about the content (rather than just point them at a location), it is general. Examples that are GENERAL despite their wording: \"find a passage that describes Ahab's leg\" (wants the description, not a page number), \"find me the most vivid description of the whale\" (wants the description), \"tell me about Ahab's character\" (wants substantive prose), \"quote a sentence that shows Ishmael's mood\" (wants a content selection with reasoning), \"describe how the narrator handles dialogue\" (wants analysis).")
        return lines.joined(separator: "\n")
    }
}
// ========== BLOCK 03: PROMPT BUILDING - END ==========


// ========== BLOCK 04: LIVE SERVICE - START ==========
#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@MainActor
final class AskPoseyService: AskPoseyStreaming, AskPoseySummarizing {

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
        // 2026-05-04: dropped 0.65 → 0.35. Polish at 0.65 was
        // ignoring the prompt's HARD RULES half the time —
        // metaphors, slang, recommendations leaking despite
        // explicit "FAILED:" examples. Lower temperature should
        // make AFM more rule-following at the cost of less voice
        // variation. Per Task 3 v2 QA, we'd rather have a
        // slightly more robotic Posey than a Posey that ignores
        // the rules and recommends the book.
        polishTemperature: Double = 0.35
    ) {
        self.model = model
        self.instructions = instructions
        self.groundedTemperature = groundedTemperature
        self.polishTemperature = polishTemperature
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

        // 2026-05-23 — Step 8g: if the user has selected an MLX
        // model, route through the LLMService facade instead of
        // AFM's LanguageModelSession. The MLX path is single-pass
        // (no grounded+polish two-call structure); the chunker /
        // retriever / Layer-1 framing all already work through
        // the shared prompt builder.
        // 2026-05-31 — answers route through `answerModel()`, which never
        // resolves to AFM (AFM is background-only now). The `if .mlx` branch
        // below therefore always wins; the AFM path that follows is inert,
        // reversible code kept for the day AFM returns as an answer engine.
        let activeModel = ModelCatalog.answerModel()
        if activeModel.source == .mlx {
            return try await streamProseResponseMLX(
                inputs: inputs,
                budget: budget,
                model: activeModel,
                onSnapshot: onSnapshot
            )
        }

        guard model.availability == .available else {
            throw AskPoseyServiceError.afmUnavailable
        }
        // Phase B: yield AFM to the user for the duration of this
        // streaming call (AFM is effectively single-stream on-device).
        NotificationCenter.default.post(name: .askPoseyAFMDidBegin, object: nil)
        defer {
            NotificationCenter.default.post(name: .askPoseyAFMDidEnd, object: nil)
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
            //
            // Extended 2026-05-30: `.guardrailViolation` is routed into
            // the SAME neutral-rephrasing retry as `.refusal`. AFM's
            // safety guardrail false-positives on ordinary literary
            // questions (e.g. "what did he say about her that was so
            // insulting?" on Pride & Prejudice trips it as "sensitive
            // or unsafe content"). `translate()` already groups
            // guardrailViolation WITH refusal as the same "safety
            // declined — user can rephrase" family; the auto-retry gate
            // should agree, so the app neutral-rephrases automatically
            // (verified on-device to clear the guardrail) instead of
            // punting the rephrase to the reader. Same belt-and-
            // suspenders typed+stringified detection as refusal.
            let shouldRetryNeutrally: Bool
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
                    case .refusal, .guardrailViolation:
                        return true
                    default:
                        return false
                    }
                }()
                let stringified = "\(g)"
                let lowered = stringified.lowercased()
                let stringContains = stringified.contains("refusal(")
                    || lowered.contains("refusal")
                    || lowered.contains("guardrail")
                shouldRetryNeutrally = switched || stringContains
                dbgLog("AskPosey: neutral-retry-detection switched=%@ stringContains=%@ stringified=%@",
                      String(describing: switched),
                      String(describing: stringContains),
                      stringified.prefix(120) as CVarArg)
            } else {
                let lowered = "\(originalError)".lowercased()
                shouldRetryNeutrally = lowered.contains("refusal(") || lowered.contains("guardrail")
            }

            if shouldRetryNeutrally {
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
                            case .refusal, .guardrailViolation: return true
                            default: return false
                            }
                        }()
                        let s = "\(r)"
                        let lowered = s.lowercased()
                        let stringContains = s.contains("refusal(")
                            || lowered.contains("refusal")
                            || lowered.contains("guardrail")
                        isRetryRefusal = switched || stringContains
                        dbgLog("AskPosey: retry neutral-retry-detection switched=%@ stringContains=%@ s=%@",
                              String(describing: switched),
                              String(describing: stringContains),
                              s.prefix(120) as CVarArg)
                    } else {
                        let lowered = "\(retryError)".lowercased()
                        isRetryRefusal = lowered.contains("refusal") || lowered.contains("guardrail")
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
                    // 2026-06-19 — preserve the A/B prompt variant across the
                    // context-overflow strip; dropping it here would silently
                    // answer the retry under `.current` even when the call
                    // began under `.rebalanced`, confounding the comparison.
                    promptVariant: inputs.promptVariant,
                    anchor: inputs.anchor,
                    surroundingContext: inputs.surroundingContext,
                    conversationHistory: [],
                    conversationSummary: nil,
                    documentChunks: [],
                    currentQuestion: inputs.currentQuestion,
                    documentTitle: inputs.documentTitle,
                    documentPlainText: inputs.documentPlainText,
                    // Preserve the spoiler firewall (Layer 1) across the
                    // context-overflow strip — dropping it here would leak on
                    // exactly the long-document case the firewall most matters.
                    spoilerProtectionActive: inputs.spoilerProtectionActive,
                    readerFurthestOffset: inputs.readerFurthestOffset
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
        _ = refusalShapeFinal  // referenced in restoration comment below; unused at runtime

        // 2026-05-04 — Polish call REMOVED (temporary). See DECISIONS.md
        // entry of the same date for the full reasoning, the voice
        // vision we're stepping back from, the failure modes
        // observed, both prompts preserved verbatim, the pipeline
        // architecture, and the revisit conditions. Short version:
        // AFM does not consistently honor the polish prompt's HARD
        // RULES (recommendations, metaphors, sycophant openers,
        // preamble announcements still leak in roughly half of
        // answers despite six rounds of iteration). Grounded is
        // reliable; polish is a coin flip. Net negative on quality.
        // Restore by re-enabling the polish branch below when AFM
        // (or its successor) can carry voice cleanly.
        //
        // The grounded call now streams to the user verbatim,
        // regardless of refusal shape. `polishTemperature`,
        // `AskPoseyPromptBuilder.polishInstructions`,
        // `AskPoseyPromptBuilder.polishPromptBody`, and the
        // `stripPolishPreamble` chain remain in the codebase as
        // inert reference for restoration.
        let accumulated = groundedFinal
        onSnapshot(groundedFinal)
        _ = polishTemperature  // silence unused-property warning; kept for restoration
        // RESTORATION REFERENCE — do not delete. To restore the
        // two-call pipeline, replace the two lines above with:
        //
        //     var accumulated = ""
        //     if refusalShapeFinal {
        //         accumulated = groundedFinal
        //         onSnapshot(groundedFinal)
        //     } else {
        //         do {
        //             let polishSession = LanguageModelSession(
        //                 model: model,
        //                 instructions: AskPoseyPromptBuilder.polishInstructions
        //             )
        //             let polishBody = AskPoseyPromptBuilder.polishPromptBody(
        //                 question: inputs.currentQuestion,
        //                 groundedDraft: groundedFinal
        //             )
        //             let stream = polishSession.streamResponse(
        //                 options: GenerationOptions(temperature: polishTemperature)
        //             ) { Prompt(polishBody) }
        //             for try await snapshot in stream {
        //                 accumulated = snapshot.content
        //                 onSnapshot(accumulated)
        //             }
        //         } catch is CancellationError {
        //             throw CancellationError()
        //         } catch {
        //             accumulated = groundedFinal
        //             onSnapshot(groundedFinal)
        //         }
        //     }

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
        // a prior turn we should accept) + document title + full
        // document plainText when available.
        //
        // 2026-05-27 — Added documentTitle + documentPlainText.
        // Without them, abstract questions ("what is this book for?")
        // retrieved thematic chunks but not metadata chunks, so when
        // the model correctly cited the author (e.g. "Lewis Carroll"
        // on Alice in Wonderland) the entity check flagged it as
        // ungrounded and the user got no answer at all. Verified the
        // failure mode on Alice EPUB with both NLContextual and Nomic.
        var haystack = ""
        if let title = inputs.documentTitle {
            haystack += " "; haystack += title
        }
        if let plainText = inputs.documentPlainText {
            haystack += " "; haystack += plainText
        }
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
        // 2026-05-27 — Include the current question. Without this,
        // the model echoing a phrase from the user's question (e.g.
        // "threatened violence" when the user asked about a book with
        // "threatened violence") gets flagged as ungrounded. The user
        // saying it counts as it being in the conversation.
        haystack += " "; haystack += inputs.currentQuestion
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
        // 2026-05-23 — Step 8f: inlined named-entity extraction
        // (used to live on DocumentEmbeddingIndex). NLTagger pass
        // captures person / place / organization names so the
        // anti-fabrication check below can verify each one appears
        // verbatim in the document.
        do {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = answer
            let opts: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
            tagger.enumerateTags(
                in: answer.startIndex..<answer.endIndex,
                unit: .word,
                scheme: .nameType,
                options: opts
            ) { tag, range in
                if let t = tag,
                   t == .personalName || t == .placeName || t == .organizationName {
                    // Lowercase to match `haystackLower.contains(entity)`
                    // below (haystack is lowercased once at the top).
                    // The pre-8f DocumentEmbeddingIndex.extractEntities
                    // helper lowercased — my inline replacement initially
                    // didn't, which made every NLTagger-flagged name
                    // (e.g. "Posey") fail the grounding check even when
                    // the document literally contained the word.
                    let token = String(answer[range])
                        .lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !token.isEmpty { candidates.insert(token) }
                }
                return true
            }
        }
        candidates.formUnion(extractQuotedStrings(from: answer))
        candidates.formUnion(extractTitleCasePhrases(from: answer))
        // 2026-05-16 (B10) — Versioned product / model names. NLTagger
        // typically doesn't tag "GPT-5" / "GPT-4" / "Claude-3" /
        // "LLaMA-2" as named entities; they slip past the title-case
        // phrase extractor too because they're one token. Without
        // catching them, AFM fabricates confidently-cited answers
        // about model versions the document never mentions (verified
        // on AI Book Collaboration RTF: 0 mentions of "GPT-5", answer
        // included "GPT-5 is a next-generation language model…[7][2]").
        candidates.formUnion(extractVersionedProductNames(from: answer))

        guard !candidates.isEmpty else { return nil }

        var ungrounded: Set<String> = []
        // 2026-05-14 (B-tier) — Trim trailing punctuation before
        // haystack comparison. Without this, a candidate like
        // `alice's adventures in wonderland,` (from a quoted-string
        // capture that grabbed a sentence-terminating comma) fails
        // to match the haystack's `alice's adventures in wonderland`
        // and the entire grounded answer gets flagged. The trimmed
        // form is also what we'd use to display the entity, so
        // normalizing the candidate is the right move.
        let trailingPunctuation = CharacterSet(charactersIn: ",.;:!?\"' \t\n\u{201C}\u{201D}\u{2018}\u{2019}")
        // 2026-05-27 — fallback grounding check.
        // Exact substring match misses two real failure modes:
        //   1. Word order is preserved but extra words sit between
        //      ("Alice in Wonderland" model output vs "Alice's
        //      Adventures in Wonderland" in document)
        //   2. Apostrophe normalization differences (model: "Samuel
        //      Gabriel Sons" vs document: "Sam'l Gabriel Sons & Company")
        // For multi-word entities (≥2 words), if all words in the entity
        // appear in the haystack (case-insensitive, with non-letter chars
        // stripped to handle the apostrophe case), accept the entity as
        // grounded. Single-word entities still require exact substring
        // match — the relaxed check is for multi-word proper nouns where
        // the brittleness matters most.
        let alnumScalars = CharacterSet.letters.union(.decimalDigits)
        let normalizedHaystackWords: Set<String> = Set(
            haystackLower
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.lowercased() }
                .filter { !$0.isEmpty }
        )
        _ = alnumScalars  // silence unused (reserved for future)

        for raw in candidates {
            let entity = raw.trimmingCharacters(in: trailingPunctuation)
            if entity.count < 4 { continue }   // ignore "AI", "Mr"
            if haystackLower.contains(entity) { continue }
            // Relaxed fallback for multi-word entities.
            let entityWords = entity
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.lowercased() }
                .filter { $0.count >= 2 }
            if entityWords.count >= 2 {
                let allWordsPresent = entityWords.allSatisfy { normalizedHaystackWords.contains($0) }
                if allWordsPresent { continue }
            }
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

    /// 2026-05-16 (B10) — Extract versioned product / model names.
    /// Patterns matched: `GPT-5`, `GPT 4`, `Claude 3`, `Claude-2.1`,
    /// `LLaMA-2`, `iPhone 17`, `Stable Diffusion 3`, `Gemini 1.5`.
    /// The pattern is intentionally tight: 2-12 letter uppercase
    /// run followed by an optional dash/space then a digit (with
    /// optional `.N` minor). Catches the common "fabricated model
    /// version" case from B10 testing without flagging legitimate
    /// English (which rarely has all-caps tokens followed by digits).
    private func extractVersionedProductNames(from text: String) -> Set<String> {
        var out = Set<String>()
        let patterns = [
            // ALL-CAPS-ACRONYM + optional dash/space + digit(s) + optional .digits
            #"\b([A-Z][A-Za-z]{1,11})[- ](\d+(?:\.\d+)?)\b"#,
        ]
        for pat in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat) else { continue }
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for m in matches where m.numberOfRanges >= 3 {
                let name = nsText.substring(with: m.range(at: 1))
                let ver = nsText.substring(with: m.range(at: 2))
                let combined = "\(name)-\(ver)".lowercased()
                let combined2 = "\(name) \(ver)".lowercased()
                out.insert(combined)
                out.insert(combined2)
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

    // ========== BLOCK MLX: MLX PROSE STREAMING - START ==========

    /// MLX path for `streamProseResponse`. Runs a single-pass
    /// generation through `LLMService.streamChat` rather than
    /// AFM's grounded+polish two-call structure (which is
    /// AFM-shaped — refusal-retry pattern doesn't apply to MLX
    /// models that don't have a refusal mode in the same form).
    ///
    /// 2026-05-23 — Step 8g.
    private func streamProseResponseMLX(
        inputs: AskPoseyPromptInputs,
        budget: AskPoseyTokenBudget,
        model: ModelConfiguration,
        onSnapshot: @MainActor @Sendable (String) -> Void
    ) async throws -> AskPoseyResponseMetadata {

        NotificationCenter.default.post(name: .askPoseyAFMDidBegin, object: nil)
        defer {
            NotificationCenter.default.post(name: .askPoseyAFMDidEnd, object: nil)
        }

        let output = AskPoseyPromptBuilder.build(inputs, budget: budget)
        let started = Date()

        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: output.instructions),
            ChatMessage(role: .user, content: output.renderedBody)
        ]

        var fullText = ""
        let stream = LLMService.shared.streamChat(
            messages: messages,
            model: model,
            options: LLMGenerationOptions(temperature: 0.2)
        )

        do {
            for try await snapshot in stream {
                fullText = snapshot
                onSnapshot(snapshot)
            }
        } catch {
            throw error
        }

        let elapsed = Date().timeIntervalSince(started)
        return AskPoseyResponseMetadata(
            finalText: fullText,
            promptTokenTotal: output.tokenBreakdown.totalIncludingScaffolding,
            breakdown: output.tokenBreakdown,
            droppedSections: output.droppedSections,
            chunksInjected: output.chunksInjected,
            fullPromptForLogging: output.combinedForLogging,
            inferenceDuration: elapsed
        )
    }

    // ========== BLOCK MLX: MLX PROSE STREAMING - END ==========

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
        guard !turns.isEmpty else { return "" }

        let summaryInstructions = """
        You are Posey, a reading companion. Summarize an earlier portion of \
        YOUR OWN conversation with the reader into a brief, faithful \
        FIRST-PERSON note — your recollection — so the rest of the conversation \
        can continue with shared context. Keep it short (3–6 sentences). Write \
        as "I" (you, Posey) and "you" (the reader): e.g. "You asked about X; I \
        pointed you to Y." Capture the topics discussed, any specific passages \
        or document sections referenced, and any commitments I made about what \
        I found. Never the third person; never call yourself "Posey" or the \
        reader "the user". Skip greetings and meta-talk. Never invent — only \
        summarize what actually happened.
        """

        var transcriptLines: [String] = []
        for turn in turns {
            // First-person framing in the transcript too ("You:" reader, "Me:"
            // Posey) so the model summarizes in the same voice it reads.
            let speaker = turn.role == .user ? "You" : "Me"
            transcriptLines.append("\(speaker): \(turn.content)")
        }
        let body = """
        Conversation to summarize:

        \(transcriptLines.joined(separator: "\n\n"))
        """

        // 2026-05-29 — PRIVACY FIX (#4). Route the summary through the
        // ACTIVE model via the unified LLMService dispatch, NOT a
        // hardcoded AFM `LanguageModelSession`. If a user downloaded an
        // on-device MLX model specifically for privacy, silently
        // summarizing via AFM in the background could reach Apple's
        // Private Cloud Compute (off-device) — quietly violating the
        // exact thing they chose MLX to get. The summarizer must respect
        // the model choice the same way the main answer does. (Also fixes
        // a voice inconsistency where an MLX user's answers were MLX but
        // their summaries were AFM.) 2026-05-31 — routes through
        // `answerModel()` (the MLX answer engine), NOT the `@Generable` aux
        // engine: summarization is free-text (AFM offers no guided-generation
        // advantage) and the summary holds the user's full conversation, so
        // keeping it on-device on MLX preserves the privacy guarantee.
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: summaryInstructions),
            ChatMessage(role: .user, content: body)
        ]
        let summarizerModel = ModelCatalog.answerModel()
        // Audit line — records which model generated the summary so the
        // privacy-respecting routing (#4) is observable in LOGS, not just
        // assumed. An MLX-for-privacy user should never see AFM here.
        dbgLog("AskPosey summary via model %@ (source=%@)",
               summarizerModel.id as NSString,
               summarizerModel.source.rawValue as NSString)
        var accumulated = ""
        do {
            let stream = LLMService.shared.streamChat(
                messages: messages,
                model: summarizerModel,
                options: LLMGenerationOptions(temperature: 0.2)
            )
            for try await snapshot in stream {
                accumulated = snapshot
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AskPoseyServiceError.permanent(underlyingDescription: "\(error)")
        }

        let rawSummary = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSummary.isEmpty else { return rawSummary }

        // 2026-05-29 — DECISION 2 ("Memory architecture: Posey is not
        // Hal"). Verify the summary against its verbatim source BEFORE
        // it enters the rolling memory. Each summary sentence is
        // embedded and scored by max cosine vs the turns being
        // summarized; sentences below threshold are DROPPED (keep-all
        // conservative when no embedder, or when filtering would empty
        // the summary). Binding the check here means EVERY generated
        // summary — initial OR a later re-compression — is fact-checked
        // at the point it is produced, so a hallucinated fact can't
        // silently take up residence in the conversation's long-term
        // memory and then be cited as if it were grounded.
        let verifier = AskPoseySummaryVerifier()
        let sources = turns.map { $0.content }
        let verified = verifier.filteredSummary(rawSummary, sources: sources)
        dbgLog("AskPosey summary verify: total=%d kept=%d dropped=%d canVerify=%@",
               verified.total, verified.kept, verified.dropped,
               (verifier.canVerify ? "yes" : "no") as NSString)
        for s in verified.droppedSentences {
            dbgLog("AskPosey summary DROPPED (cos=%.2f): %@",
                   s.maxCosine, s.text as NSString)
        }
        return verified.text
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
        You are Posey. Compress one exchange between you and the reader from a \
        reading-companion conversation into a brief, faithful FIRST-PERSON note \
        — your own memory of it — so a future turn has shared context without \
        re-reading the verbatim exchange.

        HARD RULES:
        1. Length: \(lengthGuidance) Do not exceed this.
        2. First person: you are "I" (Posey), the reader is "you". Write it as \
        your own recollection ("You asked about X; I explained Y."). Never the \
        third person, and never refer to yourself as "Posey" or the reader as \
        "the user".
        3. Faithful only — never invent specifics not in the exchange. \
        Better to drop a detail than to hallucinate one.
        4. No greetings, meta-talk, or quoting. Plain prose.
        5. Capture WHAT you were asked and WHAT you said in response. \
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
