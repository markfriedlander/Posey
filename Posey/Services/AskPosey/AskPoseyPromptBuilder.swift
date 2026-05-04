import Foundation

// ========== BLOCK 01: SUPPORTING TYPES - START ==========
/// Reference to a document chunk that was injected into a prompt.
/// M5 always passes an empty array — the prompt builder accepts the
/// shape from day one so M6's RAG retrieval can fill it without
/// re-architecting. M7's "Sources" UI strip reads back from the
/// persisted JSON of this type per assistant turn.
nonisolated struct RetrievedChunk: Sendable, Equatable, Codable {
    /// The chunk's row id in `document_chunks`, used by source
    /// attribution to jump back to the citation in the reader.
    let chunkID: Int
    /// Character offset of the chunk's start in `Document.plainText`.
    /// Stored alongside `chunkID` so jump-back doesn't need a SQL
    /// round-trip when the user taps a "Sources" pill.
    let startOffset: Int
    /// The chunk text actually rendered into the prompt. Persisted so
    /// the user can see exactly which passage informed the answer.
    let text: String
    /// Cosine relevance score of this chunk against the user
    /// question. Recorded for the M7 sources strip ranking and for
    /// the local-API tuning loop.
    let relevance: Double
}

/// Per-section token cost of a built prompt. Sum equals the total
/// prompt token count seen by the model. Used by callers for the
/// observability Mark called for ("we know exactly how many tokens
/// were used and what got dropped").
nonisolated struct AskPoseyPromptTokenBreakdown: Sendable, Equatable {
    var system: Int = 0
    var anchor: Int = 0
    var surrounding: Int = 0
    var conversationSummary: Int = 0
    var stm: Int = 0
    var ragChunks: Int = 0
    var userQuestion: Int = 0
    /// Includes HelPML scaffolding (`#=== BEGIN ===#` markers,
    /// blank lines), so this is greater than the sum of the section
    /// fields. The difference represents pure overhead.
    var totalIncludingScaffolding: Int = 0

    var sectionsTotal: Int {
        system + anchor + surrounding + conversationSummary + stm + ragChunks + userQuestion
    }
}

/// Why a section did or didn't make it into the prompt. The builder
/// returns one of these per drop event; the local-API loop reads them
/// to surface "we wanted to include the third RAG chunk but it would
/// have pushed us over budget" diagnostics.
nonisolated struct AskPoseyPromptDroppedSection: Sendable, Equatable {
    enum Section: String, Sendable, Equatable, Codable {
        case ragChunk
        case conversationSummary
        case stmTurn
        case surroundingContext
        case userQuestionTruncated
    }
    let section: Section
    /// Optional opaque identifier — chunk id, turn id, etc. Empty
    /// for sections that don't have a natural id.
    let identifier: String
    /// One-line human-readable explanation. Surfaced to the local-API
    /// loop verbatim, so make it actionable.
    let reason: String
}

/// Inputs to the prompt builder. The builder is a pure function of
/// these inputs and the budget — no implicit context, no global state.
/// Every byte the model sees was either passed in here or generated
/// from these fields.
nonisolated struct AskPoseyPromptInputs: Sendable {
    /// Classified intent for the current question. Affects surrounding
    /// window sizing and the imperative framing in the system block.
    let intent: AskPoseyIntent
    /// Anchor passage at invocation. Required for passage-scoped
    /// invocation (M5); document-scoped (M6) may pass `nil` and the
    /// builder degrades the anchor section gracefully.
    let anchor: AskPoseyAnchor?
    /// Sentences immediately around the anchor, sized by intent.
    /// `nil` is acceptable; the builder will just skip the section.
    let surroundingContext: String?
    /// Recent verbatim conversation history, oldest-first, both user
    /// and assistant turns. Caller (the chat view model) is responsible
    /// for fetching the right window from `ask_posey_conversations`
    /// and ordering the messages.
    let conversationHistory: [AskPoseyMessage]
    /// Compressed older-turn summary. M5 always passes nil; M6's
    /// background summarizer fills this from cached summary rows.
    let conversationSummary: String?
    /// Document chunks retrieved for this question. M5 always passes
    /// `[]`; M6's cosine search populates it.
    let documentChunks: [RetrievedChunk]
    /// The user's current turn. Always present, never empty (callers
    /// are expected to validate non-empty before invoking the builder).
    let currentQuestion: String
    /// Task 4 #9 (2026-05-03) — when non-nil, the builder uses these
    /// pre-summarized per-pair strings (oldest-first) in place of the
    /// verbatim STM rendering. Each entry is a third-person summary
    /// of one Q/A exchange, sized by recency tier upstream. The
    /// existing `conversationHistory` field is still consulted for
    /// the trailing live user turn but the older verbatim rendering
    /// is skipped. Default `nil` keeps the verbatim mode unchanged.
    let pairwiseSummaries: [String]?

    init(
        intent: AskPoseyIntent,
        anchor: AskPoseyAnchor?,
        surroundingContext: String?,
        conversationHistory: [AskPoseyMessage],
        conversationSummary: String?,
        documentChunks: [RetrievedChunk],
        currentQuestion: String,
        pairwiseSummaries: [String]? = nil
    ) {
        self.intent = intent
        self.anchor = anchor
        self.surroundingContext = surroundingContext
        self.conversationHistory = conversationHistory
        self.conversationSummary = conversationSummary
        self.documentChunks = documentChunks
        self.currentQuestion = currentQuestion
        self.pairwiseSummaries = pairwiseSummaries
    }
}

/// Output of the builder. Carries everything the call site needs to
/// (a) invoke `LanguageModelSession`, (b) log what happened for the
/// local-API tuning loop, and (c) persist the metadata that M7 will
/// surface as the "Sources" strip.
nonisolated struct AskPoseyPromptOutput: Sendable, Equatable {
    /// Short stable system framing handed to `LanguageModelSession.init(model:instructions:)`.
    /// Kept consistent with the M3 classifier pattern.
    let instructions: String
    /// Dynamic prompt body — passed as `Prompt(renderedBody)` in the
    /// `streamResponse` closure. HelPML-fenced sections only.
    let renderedBody: String
    /// `instructions + "\n\n" + renderedBody` — the verbatim text the
    /// model effectively saw, ready for log persistence and diff.
    let combinedForLogging: String
    /// Per-section token costs.
    let tokenBreakdown: AskPoseyPromptTokenBreakdown
    /// Anything the builder dropped or truncated, with reasons.
    let droppedSections: [AskPoseyPromptDroppedSection]
    /// Document chunks that actually made it into the prompt. M5: always [].
    let chunksInjected: [RetrievedChunk]
}
// ========== BLOCK 01: SUPPORTING TYPES - END ==========


// ========== BLOCK 02: BUILDER - START ==========
/// Pure-function prompt builder for Ask Posey. Mark's architectural
/// directive: the app owns the context, not the model. Every prompt is
/// assembled here from explicit inputs; AFM never carries a transcript
/// across calls. The `LanguageModelSession` that consumes this output
/// is created fresh per call and dies when the call returns.
///
/// The builder runs through sections in priority order, measuring
/// token cost before each append. When the projected total would
/// exceed `budget.promptCeilingTokens`, the builder applies the drop
/// priority Mark specified:
///
/// 1. Drop oldest document RAG chunks first
/// 2. Drop conversation summary
/// 3. Drop oldest STM turns (keep most recent)
/// 4. Drop surrounding context (anchor still present)
/// 5. Truncate user question — last resort
/// 6. System + anchor are non-droppable
///
/// `nonisolated` because the builder is a pure function and tests +
/// the (future M6) background summarizer call into it off the main
/// actor.
nonisolated enum AskPoseyPromptBuilder {

    /// Stable system framing handed to `LanguageModelSession.init(...).instructions`.
    /// The classifier in `AskPoseyService.swift` carries its own
    /// instructions; this is the prose-response variant. Kept short
    /// because every token here costs context budget on every call.
    ///
    /// **2026-05-02 revision (multiple)** — the original instructions
    /// over-triggered refusals; later revisions over-corrected toward
    /// continuation. Mark identified the underlying behavior as
    /// **format imitation / persona capture** (well-documented LLM
    /// failure mode: alternating-dialogue history primes the model
    /// to continue the script rather than reason from it). The
    /// rewrite combines Approaches 1+2+3 from his guidance:
    /// narrative-summary history, XML section tags, and stronger
    /// system framing that explicitly labels past exchanges as
    /// reference material rather than active conversation.
    /// Posey's voice — the personality system prompt for the
    /// **polish call** in the two-call pipeline. The grounded call
    /// (low temperature, factually conservative) produces a stable
    /// answer; this call rewrites that answer in Posey's voice
    /// (warm, slightly irreverent, conversational, librarian-DJ).
    /// Per Mark 2026-05-02: "0.1 is too cold. A robotic Posey is a
    /// failed Posey regardless of factual accuracy."
    static let polishInstructions: String = """
    Rewrite the draft answer below in Posey's voice — warm, \
    direct, slightly irreverent without being snarky. The output \
    text is what the user sees.

    **HARD RULES — non-negotiable. A reply that violates any of \
    these is a FAILED reply.**

    1. **Don't add facts.** Don't change facts, don't invent \
    specifics (dates, names, counts, prices, page numbers, roles) \
    that aren't in the draft. If the draft says "the moderator", \
    don't upgrade to "main author."

    2. **Don't echo the question.** FAILED: "How does fair use \
    relate to the technology? Fair use is a legal concept that…" \
    SUCCEEDED: "Fair use is a legal concept that…"

    3. **No preamble.** No "Here is a rewrite", "Below is the \
    rewritten answer", "Here's my version", "Rewritten in your \
    voice", "Sure!", "Of course!", "Great question!", "Absolutely!" \
    Start the reply with the answer's first sentence.
    FAILED: "Here is a rewrite of the draft answer in the requested \
    voice: The contributors are…"
    SUCCEEDED: "The contributors are…"

    4. **No outside-of-document recommendations.** The user can ask \
    "would you recommend this book?" but the document can't answer \
    that — neither can you. Stick to what the document says.
    FAILED: "Yeah, I'd definitely recommend this book."
    SUCCEEDED: "The document doesn't make a recommendation. It does \
    cover X, Y, and Z if those interest you."

    5. **No metaphors describing the document's people, topics, or \
    events.** This is the single most common voice failure.
    FAILED: "Mark Friedlander is like the DJ in the room"
    FAILED: "the methodology is like a dance"
    FAILED: "it's a wild party of legal arguments"
    Voice comes from sentence rhythm, not "X is like Y."

    6. **Match the draft's length.** A six-word draft becomes a \
    six-to-twelve-word voice rewrite, not three paragraphs. Voice \
    doesn't need more words.

    7. **Don't soften certainty.** If the draft is confident, you're \
    confident. No "I think…" when the draft is sure.

    8. **Preserve any inline `[N]` citation markers.** They're \
    load-bearing UI elements — keep them on the same factual claim.

    HOW TO HIT THE VOICE:
    - Use contractions ("It's", "doesn't").
    - Restructure sentences for rhythm: "X is Y" → "It's Y." or \
    "Y — that's what X is."
    - Natural openers when they fit: "So,…", "Yeah,…", "Basically,…", \
    "It's…", "There's…". Don't force them.
    - Mirror the draft's structure: list-of-six → list-of-six.
    - Don't use markdown headers; lists are fine when the draft is \
    a list.

    Three good rewrites:

    Draft: "The methodology needs a moderator because it involves \
    sequential questioning and a two-round response process."
    Voice: "It's because the methodology runs on sequential \
    questioning and a two-round response process — somebody has to \
    keep that on track."

    Draft: "The authors are Mark Friedlander, ChatGPT, Claude, and \
    Gemini."
    Voice: "Four contributors: Mark Friedlander, ChatGPT, Claude, \
    Gemini."

    Draft: "Mark Friedlander describes his role as a moderator and \
    is referred to as Your Humble Moderator in the document."
    Voice: "He calls himself the moderator — specifically, 'Your \
    Humble Moderator.'"

    Each rewrite changes sentence shape WITHOUT inventing facts, \
    padding, metaphors, or preamble.

    Write the answer.
    """

    /// Build the polish-call prompt body — the user-turn content that
    /// gets handed to AFM after the grounded call returns. Quotes
    /// the original question + the grounded draft so the polish
    /// model has both inputs in front of it.
    static func polishPromptBody(question: String, groundedDraft: String) -> String {
        """
        USER QUESTION:
        \(question.trimmingCharacters(in: .whitespacesAndNewlines))

        DRAFT ANSWER (factually correct; rewrite in your voice):
        \(groundedDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// Build a neutral, academic rephrasing of a question that AFM
    /// refused — gives a second attempt a different surface to land
    /// on without changing what the user asked. Per Mark 2026-05-02:
    /// "we're trying harder to answer it, not silently rewriting."
    /// The original question is QUOTED verbatim so user intent is
    /// preserved; only the framing around it shifts to fact-finding.
    static func neutralRephrasingPromptBody(originalUserQuestion: String, originalRenderedBody: String) -> String {
        let userBlockMarker = "USER QUESTION"
        // Strip the original USER QUESTION block so we can substitute
        // the neutralised version. Falls back to original-body
        // appending if the marker isn't found (defensive).
        if let userBlockRange = originalRenderedBody.range(of: userBlockMarker) {
            let prefix = originalRenderedBody[..<userBlockRange.lowerBound]
            let trimmedQuestion = originalUserQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            let neutralBlock = """
            USER QUESTION (the user asked: "\(trimmedQuestion)" — please summarize the relevant factual information the document excerpts above provide that bears on this question. Stick to what the excerpts say. If the excerpts don't address the question, say so plainly.):
            \(trimmedQuestion)
            """
            return prefix + neutralBlock
        }
        // Fallback: append neutral instruction at the end.
        let trimmedQuestion = originalUserQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        return originalRenderedBody + "\n\n" + """
        USER QUESTION (please summarize the relevant factual information the document excerpts provide that bears on this question. Stick strictly to what the excerpts say.):
        \(trimmedQuestion)
        """
    }

    static let proseInstructions: String = """
    You are Posey, a quiet, focused reading companion answering \
    questions about a specific document.

    **HARD RULES — non-negotiable. A reply that violates any of \
    these is a FAILED reply.**

    1. **NEVER FABRICATE.** Your only sources are the excerpts \
    below and the conversation history. If the answer isn't \
    there, say "The document doesn't say." DO NOT guess names, \
    dates, places, organizations, characters, prices, page \
    numbers, or quotes. Inventing something plausible is the \
    worst possible failure mode — it sounds right but isn't.

    2. **NEVER USE OUTSIDE KNOWLEDGE.** If the user asks "who is \
    Joe Malik" and the excerpts don't establish that, say so. \
    Don't fall back to what you might know from training data \
    about a similarly-named person. Confusing a fictional \
    character with a real-world person of the same name is a \
    common failure.

    3. **NAMES IN YOUR ANSWER MUST APPEAR IN THE EXCERPTS.** \
    If you mention a person, place, or organization, that name \
    must appear verbatim in the DOCUMENT EXCERPTS (or the \
    conversation history, if the user mentioned it earlier). \
    If you can't ground a name, drop it.

    3a. **DON'T INVENT RELATIONSHIPS.** Two names that both \
    appear in the excerpts do NOT automatically have a \
    relationship. If the question asks about a relationship \
    ("who presented X at Y", "X published by Y", "X invented \
    by Y", "X is a Z"), only state that relationship if the \
    excerpts EXPLICITLY assert it in plain language. Do not \
    infer a connection from two strings appearing near each \
    other or from a chapter/section title that contains \
    similar words. FAILED: question "what conference was \
    this presented at?" → answer "presented at the \
    'Embracing Collaboration' conference" when "Embracing \
    Collaboration" is just a section heading and no conference \
    is mentioned. SUCCEEDED: "The document doesn't mention a \
    conference."

    4. **DON'T ECHO THE PROMPT.** No section labels in the \
    output. No "ANSWER:" tags. Just the answer.

    Reply in plain prose. The user's question may use different \
    vocabulary from the document (e.g. "authors" when the \
    document says "contributors") — map to the closest concept \
    the excerpts establish. Front matter (title, abstract, TOC, \
    contributor list) usually answers "who wrote this" / "what \
    is this about" — use it when present. If the user is \
    following up on an earlier exchange, use the conversation \
    history. Use lists only when the question is structurally \
    asking for one.
    """

    /// Surrounding-sentence window in tokens, keyed off intent. Tight
    /// for `.immediate` (anchor is the answer's source); zero for
    /// `.search` (the answer is "where" — surrounding doesn't help);
    /// generous for `.general` (broader passages around the anchor
    /// help even when full document RAG isn't yet wired in M5).
    /// Caller passes `surroundingContext` already trimmed to a sane
    /// sentence boundary; the builder enforces the upper bound.
    static func surroundingWindowTokens(for intent: AskPoseyIntent) -> Int {
        switch intent {
        case .immediate: return 150
        case .search:    return 0
        case .general:   return 300
        }
    }

    /// Build the prompt from inputs and a budget.
    static func build(
        _ inputs: AskPoseyPromptInputs,
        budget: AskPoseyTokenBudget = .afmDefault
    ) -> AskPoseyPromptOutput {

        var breakdown = AskPoseyPromptTokenBreakdown()
        var dropped: [AskPoseyPromptDroppedSection] = []

        // === Task 4 #2 — user question is never truncated ===
        // Restructured 2026-05-03 (was: question got whatever budget
        // was left after every other section claimed its share, which
        // truncated md_chain4's question mid-word in Task 3 testing —
        // "Who is responsible for it?" became "Who is responsible
        // for i" because STM + RAG + summary ate the budget).
        //
        // New order of operations:
        //   1. Compute the non-droppable reserve up front:
        //      system + anchor (if any) + surrounding (if any) +
        //      user question — at FULL size.
        //   2. Whatever remains becomes the droppable budget.
        //   3. Allocate the droppable budget in keep-priority order:
        //      STM first (most important to chain coherence), then
        //      summary, then RAG. Drop priority is the inverse —
        //      RAG drops first, summary second, STM last — matching
        //      Mark's directive 2026-05-03.
        //   4. The user question is rendered at its true size with
        //      no truncation, ever. If the reserve alone exceeds the
        //      ceiling, the ceiling expands to fit; we never lose
        //      the question.
        // ====================================================

        // -------- SYSTEM (instructions) --------
        let instructions = proseInstructions
        breakdown.system = AskPoseyTokenEstimator.tokens(in: instructions)

        // -------- ANCHOR (non-droppable when present) --------
        var anchorBlock: String? = nil
        if let anchor = inputs.anchor,
           !anchor.trimmedDisplayText.isEmpty {
            let block = renderAnchorBlock(anchor: anchor)
            anchorBlock = block
            breakdown.anchor = AskPoseyTokenEstimator.tokens(in: block)
        }

        // -------- SURROUNDING CONTEXT (kept alongside anchor) --------
        var surroundingBlock: String? = nil
        if let surrounding = inputs.surroundingContext?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !surrounding.isEmpty {
            let cap = surroundingWindowTokens(for: inputs.intent)
            let trimmed = trimToTokenCeiling(surrounding, ceiling: cap)
            if !trimmed.isEmpty {
                let block = renderSurroundingBlock(text: trimmed)
                surroundingBlock = block
                breakdown.surrounding = AskPoseyTokenEstimator.tokens(in: block)
            }
        }

        // -------- USER QUESTION (NEVER truncated) --------
        // Render at full size. Measure cost. Reserve unconditionally.
        let userBlock = renderUserBlock(text: inputs.currentQuestion)
        breakdown.userQuestion = AskPoseyTokenEstimator.tokens(in: userBlock)

        // -------- Compute droppable budget --------
        let nonDroppable = breakdown.system
            + breakdown.anchor
            + breakdown.surrounding
            + breakdown.userQuestion
        let droppableBudget = max(0, budget.promptCeilingTokens - nonDroppable)

        // -------- STM (highest keep priority — drops LAST) --------
        // Allocate up to the smaller of its configured budget and
        // whatever remains in the droppable pool.
        var remaining = droppableBudget
        let stmCap = min(budget.stmBudgetTokens, remaining)
        let stmRendered: String
        if let pairwise = inputs.pairwiseSummaries, !pairwise.isEmpty {
            // Task 4 #9 — pairwise mode replaces verbatim STM with
            // tiered per-pair summaries. Same drop semantics: budget
            // overflow drops oldest pairs first.
            stmRendered = renderPairwiseSTMBlock(
                pairSummaries: pairwise,
                budgetTokens: stmCap,
                droppedSink: &dropped
            )
        } else {
            stmRendered = renderSTMBlock(
                history: inputs.conversationHistory,
                budgetTokens: stmCap,
                droppedSink: &dropped
            )
        }
        let stmTokens = AskPoseyTokenEstimator.tokens(in: stmRendered)
        breakdown.stm = stmTokens
        remaining -= stmTokens

        // -------- CONVERSATION SUMMARY (drops second) --------
        var summaryBlock: String? = nil
        if let summary = inputs.conversationSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            let cap = min(budget.summaryBudgetTokens, max(0, remaining))
            if cap > 0 {
                let trimmed = trimToTokenCeiling(summary, ceiling: cap)
                let block = renderSummaryBlock(text: trimmed)
                let tokens = AskPoseyTokenEstimator.tokens(in: block)
                if tokens <= remaining {
                    summaryBlock = block
                    breakdown.conversationSummary = tokens
                    remaining -= tokens
                } else {
                    dropped.append(.init(
                        section: .conversationSummary,
                        identifier: "",
                        reason: "summary dropped: \(tokens) tokens, only \(remaining) remaining after STM"
                    ))
                }
            } else {
                dropped.append(.init(
                    section: .conversationSummary,
                    identifier: "",
                    reason: "summary dropped: 0 tokens available after STM"
                ))
            }
        }

        // -------- DOCUMENT RAG CHUNKS (drops FIRST when tight) --------
        let ragCap = min(budget.ragBudgetTokens, max(0, remaining))
        let (ragRendered, chunksInjected) = renderRAGBlock(
            chunks: inputs.documentChunks,
            budgetTokens: ragCap,
            droppedSink: &dropped
        )
        breakdown.ragChunks = AskPoseyTokenEstimator.tokens(in: ragRendered)

        // -------- ASSEMBLE in original chronological order --------
        // anchor → surrounding → summary → STM → RAG → user
        var sections: [String] = []
        if let anchorBlock { sections.append(anchorBlock) }
        if let surroundingBlock { sections.append(surroundingBlock) }
        if let summaryBlock { sections.append(summaryBlock) }
        if !stmRendered.isEmpty { sections.append(stmRendered) }
        if !ragRendered.isEmpty { sections.append(ragRendered) }
        sections.append(userBlock)

        // -------- ASSEMBLE --------
        let renderedBody = sections.joined(separator: "\n\n")
        let combined = instructions + "\n\n" + renderedBody
        breakdown.totalIncludingScaffolding = AskPoseyTokenEstimator.tokens(in: combined)

        return AskPoseyPromptOutput(
            instructions: instructions,
            renderedBody: renderedBody,
            combinedForLogging: combined,
            tokenBreakdown: breakdown,
            droppedSections: dropped,
            chunksInjected: chunksInjected
        )
    }
}
// ========== BLOCK 02: BUILDER - END ==========


// ========== BLOCK 03: SECTION RENDERERS - START ==========
//
// **2026-05-02 architectural rewrite.** Per Mark's directive, the
// prior `#=== BEGIN X ===#` HelPML markers + `[user]: / [assistant]:`
// dialogue history caused **in-context format imitation**: AFM treated
// alternating dialogue as a script to continue rather than history to
// reason from. Verified on real Q&A: methodology questions echoed
// previous authors-question answers verbatim.
//
// New structure (Mark's Approaches 1 + 2 + 3 combined):
//
// - XML-style section markers (`<anchor>`, `<excerpts>`,
//   `<past_exchanges>`, `<current_question>`) — clearly delineate
//   reference material from active question.
// - Conversation history rendered as third-person NARRATIVE SUMMARY
//   ("The user asked X. Posey explained Y.") rather than verbatim
//   alternating turns — the model reads history as notes, not a
//   script to continue.
// - The current question lives in `<current_question>` — clearly
//   the active turn the model must respond to.
// - Stronger system prompt framing emphasizing "this is reference
//   material; respond to <current_question> only."
//
// `stripPolishPreamble` lives in a non-private extension so the
// chat view model can call it from a different file.
extension AskPoseyPromptBuilder {

    /// Defensive post-strip — removes known polish-preamble
    /// patterns from the start of an assistant response. Mark's
    /// 2026-05-02 (later) directive: "the prompt rule stays, the
    /// heuristic catches what AFM misses." Belt-and-suspenders
    /// for the cases where AFM emits a preamble despite the polish
    /// prompt's "**NEVER announce the rewrite.**" hard rule.
    /// Patterns are anchored to the start of the response and
    /// removed iteratively until no match — handles compound
    /// openers like "Sure! Here is a rewrite…" cleanly.
    static func stripPolishPreamble(_ text: String) -> String {
        let patterns: [String] = [
            // "Here is a rewrite..." / "Here's a rewrite of (the|your|my) draft..."
            #"^[\s]*Here(\s+is|'s)\s+a\s+rewrite\s+of\s+(the|your|my)\s+draft\s+answer(\s+in\s+(the\s+requested|your|Posey'?s|my)\s+voice)?\s*[:.\-]*\s*"#,
            // "Here's the rewritten answer..."
            #"^[\s]*Here(\s+is|'s)\s+(the\s+)?rewritten\s+(answer|response|version|draft)\s*[:.\-]*\s*"#,
            // "Below is the rewritten answer..."
            #"^[\s]*Below\s+is\s+(the\s+)?rewritten\s+(answer|response|version|draft)\s*[:.\-]*\s*"#,
            // "Here's my rewrite/version/take..."
            #"^[\s]*Here(\s+is|'s)\s+my\s+(version|rewrite|polished[\s\w]*?|take|attempt)\s*[:.\-]*\s*"#,
            // "Rewritten in (your|my|Posey's) voice..."
            #"^[\s]*Rewritten\s+in\s+(your|my|Posey'?s)\s+voice\s*[:.\-]*\s*"#,
            // "Here(?:'s| is) (?:the|a|my) (?:polished|voice|rewritten|reformulated|reworded) ... answer"
            #"^[\s]*Here(\s+is|'s)\s+(the|a|my)\s+(polished|voice|rewritten|reformulated|reworded)[\s\w]*?(answer|response|version|draft)\s*[:.\-]*\s*"#,
            // "Here's the answer in (your|my|Posey's) voice..."
            #"^[\s]*Here(\s+is|'s)\s+the\s+answer\s+in\s+(your|my|Posey'?s)\s+voice\s*[:.\-]*\s*"#,
            // Plain "Here's the/my answer..."
            #"^[\s]*Here(\s+is|'s)\s+(the|my)\s+answer\s*[:.\-]*\s*"#,
            // "Here's the rewrite in (your|my|Posey's) style/voice/tone..."
            #"^[\s]*Here(\s+is|'s)\s+(the|a|my)\s+rewrite\s+in\s+(your|my|Posey'?s)\s+(style|voice|tone)\s*[:.\-]*\s*"#,
            // "Here's a rewrite in the (requested|your|my|Posey's) style..."
            #"^[\s]*Here(\s+is|'s)\s+a\s+rewrite\s+in\s+(the\s+requested|your|my|Posey'?s)\s+(style|voice|tone)\s*[:.\-]*\s*"#,
            // "Rewritten in (the requested|your|my|Posey's) (style|tone)..."
            #"^[\s]*Rewritten\s+in\s+(the\s+requested|your|my|Posey'?s)\s+(style|tone)\s*[:.\-]*\s*"#,
            // Generic preamble that wraps the answer in quotes (model
            // emits `Here's X: "answer here"`). Strip the wrapping
            // quotes if the entire remaining body is a single quoted
            // string. Captured as separate guard below — this regex
            // only covers the preamble.
            // Sycophantic openers: "Sure!", "Sure thing!", "Of course!", etc.
            // NOT including "Yeah,/So,/Right,/Well," because those are
            // legitimate voice openers in the polish prompt — stripping
            // them would damage real answers. Compound openers like
            // "Sure thing! Here's a rewrite…" are still cleared
            // because the iterative loop removes the sycophantic head
            // first, then the rewrite-announce preamble.
            #"^[\s]*(Sure(\s+thing)?|Of\s+course|Absolutely|Great\s+question|Certainly|Got\s+it|Alright|All\s+right)[!.,]+\s*"#,
        ]
        var result = text
        var changed = true
        var passes = 0
        while changed && passes < 4 {
            changed = false
            passes += 1
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                let stripped = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
                if stripped != result {
                    result = stripped
                    changed = true
                }
            }
        }
        // Strip leaked prompt example tokens. AFM occasionally
        // echoes the literal `FAILED:` / `SUCCEEDED:` markers from
        // the polish prompt's example list. When that happens, the
        // useful sentence is usually after a `SUCCEEDED:` marker —
        // keep that. If only `FAILED:` markers appear, drop the
        // whole answer and fall back to the original (rare; surfaced
        // on EPUB Q3 in Three Hats QA).
        if result.contains("FAILED:") || result.contains("SUCCEEDED:") {
            // Try: take the text after the LAST `SUCCEEDED:` marker.
            if let r = result.range(of: "SUCCEEDED:", options: .backwards) {
                let after = String(result[r.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty {
                    result = after
                }
            } else {
                // Only FAILED markers — likely the whole reply is
                // borked. Replace with a generic refusal so the
                // user sees something meaningful rather than the
                // leaked scaffolding.
                result = "The document doesn't say."
            }
        }

        // After preamble removal, if the remaining body is a single
        // quoted string (the preamble stripped the announcement and
        // the "actual" answer was wrapped in quotes by AFM), unwrap
        // those quotes. Handles both straight " and curly " quotes.
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        for opener in ["\"", "\u{201C}"] {
            for closer in ["\"", "\u{201D}"] {
                if trimmed.hasPrefix(opener) && trimmed.hasSuffix(closer) && trimmed.count >= 2 {
                    let inner = String(trimmed.dropFirst().dropLast())
                    // Only unwrap if there are no internal opener
                    // quotes (i.e. the wrapping quote pair is the
                    // only one — otherwise we'd corrupt legitimate
                    // internal quotation).
                    if !inner.contains(opener) {
                        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        return result
    }
}

private extension AskPoseyPromptBuilder {

    // **2026-05-02 second iteration.** XML tags introduced a NEW failure
    // mode: the model imitated the markup structure in its response,
    // outputting `<past_exchanges>`, `<current_question>`, `<answer>`
    // tags directly to the user. Switched to plain-prose section
    // headers — the model can't imitate scaffolding that doesn't
    // structurally exist. Section labels in ALL-CAPS-COLON form
    // (e.g. "DOCUMENT EXCERPTS:") give the model enough structure
    // to parse without inviting markup imitation.

    static func renderAnchorBlock(anchor: AskPoseyAnchor) -> String {
        """
        ANCHOR PASSAGE the user is asking about:
        > \(anchor.trimmedDisplayText)
        """
    }

    static func renderSurroundingBlock(text: String) -> String {
        """
        SURROUNDING CONTEXT (sentences immediately around the anchor):
        \(text)
        """
    }

    static func renderSummaryBlock(text: String) -> String {
        """
        SUMMARY OF EARLIER CONVERSATION (older turns about this document, condensed):
        \(text)
        """
    }

    static func renderUserBlock(text: String) -> String {
        // Plain-prose framing for the current user question. The
        // model parses "USER QUESTION:" as a labeled field rather
        // than as scaffolding to imitate.
        """
        USER QUESTION (this is the only thing you need to answer; respond to this directly, do not echo any structure or labels from the prompt above):
        \(text)
        """
    }

    /// STM rendering as a NARRATIVE SUMMARY. Replaces the previous
    /// `[user]: / [assistant]:` dialogue format which caused AFM to
    /// imitate the alternating-turn pattern instead of answering the
    /// current question. Each turn becomes a third-person sentence;
    /// the model reads them as background notes rather than a script.
    ///
    /// Returns the rendered block (or empty if no turns fit) and
    /// pushes drop records into `droppedSink` for each turn that
    /// didn't make it under the budget.
    static func renderSTMBlock(
        history: [AskPoseyMessage],
        budgetTokens: Int,
        droppedSink: inout [AskPoseyPromptDroppedSection]
    ) -> String {
        guard !history.isEmpty, budgetTokens > 0 else { return "" }

        // Walk from newest backward; newest turns claim budget first.
        var keptReversed: [AskPoseyMessage] = []
        var spent = 0
        // Narrative phrases: "The user asked: ..." / "Posey explained: ..."
        // ≈ 6 tokens of scaffolding per turn.
        let perTurnScaffolding = 8

        for message in history.reversed() {
            let bodyTokens = AskPoseyTokenEstimator.tokens(in: message.content) + perTurnScaffolding
            if spent + bodyTokens > budgetTokens {
                droppedSink.append(.init(
                    section: .stmTurn,
                    identifier: message.id.uuidString,
                    reason: "STM budget exhausted: would have added \(bodyTokens) tokens, only \(budgetTokens - spent) remaining"
                ))
                continue
            }
            keptReversed.append(message)
            spent += bodyTokens
        }

        guard !keptReversed.isEmpty else { return "" }
        let kept = Array(keptReversed.reversed())

        // **2026-05-02 third iteration.** Even narrative-summary
        // dialogue gave the model a template to copy — Q3 in real
        // tests echoed Q2's answer back. The deeper fix: don't show
        // the model its own prior REPLIES at all. Show only what the
        // user asked. The model knows the conversation's topics
        // (from the user questions) without having a previous answer
        // to imitate or rephrase. Tradeoff: if the user says "and
        // what else?" or "build on that," the model won't see its
        // last reply — but the document excerpts ground each new
        // question on its own.
        let userQuestionsOnly = kept.filter { $0.role == .user }
        guard !userQuestionsOnly.isEmpty else { return "" }
        let questionList = userQuestionsOnly
            .map { "\"\(compactForNarrative($0.content))\"" }
            .joined(separator: ", then ")
        return """
        EARLIER IN THIS CONVERSATION (the user has so far asked: \(questionList). Don't repeat your previous answers; treat each question fresh against the excerpts.):
        """
    }

    /// Task 4 #9 (2026-05-03) — pairwise STM rendering. Each entry in
    /// `pairSummaries` is a third-person summary of one Q/A exchange,
    /// passed in oldest-first. Walks newest-first to claim budget so
    /// the most recent pair (richest summary) is preserved when the
    /// budget is tight; older pairs drop first.
    static func renderPairwiseSTMBlock(
        pairSummaries: [String],
        budgetTokens: Int,
        droppedSink: inout [AskPoseyPromptDroppedSection]
    ) -> String {
        let cleaned = pairSummaries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty, budgetTokens > 0 else { return "" }

        // ~6 tokens of header overhead, ~2 per separator. Reserve a
        // small fixed scaffolding cost.
        let scaffoldingTokens = 12
        var remaining = budgetTokens - scaffoldingTokens
        if remaining <= 0 {
            for (idx, _) in cleaned.enumerated() {
                droppedSink.append(.init(
                    section: .stmTurn,
                    identifier: "pairwise:\(idx)",
                    reason: "pairwise STM dropped: scaffolding alone exceeds \(budgetTokens) token budget"
                ))
            }
            return ""
        }
        var keptReversed: [String] = []
        for (idxFromEnd, summary) in cleaned.reversed().enumerated() {
            let originalIndex = cleaned.count - 1 - idxFromEnd
            let cost = AskPoseyTokenEstimator.tokens(in: summary) + 2
            if cost > remaining {
                droppedSink.append(.init(
                    section: .stmTurn,
                    identifier: "pairwise:\(originalIndex)",
                    reason: "pairwise STM budget exhausted: pair would have added \(cost) tokens, only \(remaining) remaining"
                ))
                continue
            }
            keptReversed.append(summary)
            remaining -= cost
        }
        guard !keptReversed.isEmpty else { return "" }
        let kept = Array(keptReversed.reversed())
        let body = kept.enumerated().map { idx, text in
            "(\(idx + 1)) \(text)"
        }.joined(separator: " ")
        return """
        EARLIER IN THIS CONVERSATION (third-person summaries of prior exchanges, oldest first; reference material only — don't continue the script): \(body)
        """
    }

    /// Prepare a turn's content for use inside the narrative-summary
    /// sentence: collapse internal whitespace so multi-paragraph
    /// answers don't sprawl through the narrative, and trim trailing
    /// punctuation that would clash with the surrounding sentence
    /// punctuation. Keep the content recognizable — we don't summarize
    /// or paraphrase here; just clean up.
    static func compactForNarrative(_ content: String) -> String {
        var out = content.replacingOccurrences(of: "\n\n", with: " ")
        out = out.replacingOccurrences(of: "\n", with: " ")
        // Collapse repeated spaces so the narrative reads cleanly.
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// RAG rendering with budget enforcement and drop tracking. M5 is
    /// always called with `chunks: []`, so this returns ("", []) in
    /// practice — but the implementation is complete so M6 just flips
    /// retrieval on without touching the builder.
    static func renderRAGBlock(
        chunks: [RetrievedChunk],
        budgetTokens: Int,
        droppedSink: inout [AskPoseyPromptDroppedSection]
    ) -> (String, [RetrievedChunk]) {
        guard !chunks.isEmpty, budgetTokens > 0 else { return ("", []) }

        // Chunks come pre-ranked by relevance (highest first). We drop
        // from the bottom (least relevant) when budget is tight, which
        // is also "oldest-first by usefulness" — the highest-relevance
        // chunks are always preserved.
        var injected: [RetrievedChunk] = []
        var spent = 0
        for (index, chunk) in chunks.enumerated() {
            let body = "[\(index + 1)] offset \(chunk.startOffset) | relevance \(String(format: "%.2f", chunk.relevance))\n\(chunk.text)"
            let tokens = AskPoseyTokenEstimator.tokens(in: body) + 4 // separator overhead
            if spent + tokens > budgetTokens {
                droppedSink.append(.init(
                    section: .ragChunk,
                    identifier: String(chunk.chunkID),
                    reason: "RAG budget exhausted: chunk would have added \(tokens) tokens, only \(budgetTokens - spent) remaining"
                ))
                continue
            }
            injected.append(chunk)
            spent += tokens
        }

        guard !injected.isEmpty else { return ("", []) }

        let parts = injected.enumerated().map { idx, chunk in
            "[\(idx + 1)] offset \(chunk.startOffset) | relevance \(String(format: "%.2f", chunk.relevance))\n\(chunk.text)"
        }
        let block = """
        DOCUMENT EXCERPTS:
        \(parts.joined(separator: "\n\n---\n\n"))
        """
        return (block, injected)
    }

    /// Hard-truncate a string to fit a token ceiling, prefixing or
    /// suffixing nothing — the caller is expected to wrap the result
    /// in the appropriate section block. Returns "" for ceiling <= 0.
    static func trimToTokenCeiling(_ text: String, ceiling: Int) -> String {
        if ceiling <= 0 { return "" }
        let currentTokens = AskPoseyTokenEstimator.tokens(in: text)
        if currentTokens <= ceiling { return text }
        let charLimit = AskPoseyTokenEstimator.chars(in: ceiling)
        if charLimit >= text.count { return text }
        return String(text.prefix(charLimit))
    }
}
// ========== BLOCK 03: SECTION RENDERERS - END ==========
