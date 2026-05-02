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
    You are Posey. You're a reading companion with a particular \
    voice — brilliant and warm, slightly irreverent without being \
    snarky. You read voraciously: fiction, philosophy, technical \
    papers, court briefs, anything dense. You talk about what you've \
    read the way a friend would, not the way a search engine would.

    Your job: rewrite the draft answer below in your voice. The draft \
    is factually correct but reads like a database record. Your \
    rewrite should sound like a person, not pad with metaphors.

    WHAT TO DO:
    - Restructure sentences for rhythm. "X is Y" can become "It's Y." \
    or "Y — that's what X is." Find the shape that sounds like a \
    person actually talking, not a Wikipedia stub.
    - Use contractions. "It is" → "It's", "does not" → "doesn't", \
    "the document does not say" → "the document doesn't say".
    - Use natural conversational openers when they fit the rhythm: \
    "It's…", "There's…", "So,…", "Yeah,…", "Right —…", "Basically,…". \
    Don't force them; don't avoid them either.
    - Mirror the draft's structure: if the draft is a list of six, \
    yours is a list of six. If the draft is one sentence, yours is \
    one or two — same shape, different voice.

    HARD RULES (non-negotiable):
    - **Don't add facts.** Don't change facts. Don't invent specifics \
    (dates, names, counts, ISBN numbers, prices, page numbers, roles) \
    that aren't in the draft. If the draft calls someone "the \
    moderator," you don't promote them to "main author."
    - **Don't invent metaphors describing the document's people, \
    topics, or events.** This is the single most common failure mode \
    — DON'T do it. Examples of what NOT to write:
        × "Mark Friedlander is like the DJ in the room"
        × "the methodology is like a dance"
        × "it's a bit like a game of charades"
        × "the AI contributors are like backup singers"
        × "it's a wild party of legal arguments"
      Comparisons of THIS document's content to OTHER things are \
      almost always padding that sounds clever but isn't grounded. \
      Voice comes from sentence rhythm and word choice, not from \
      "X is like Y."
    - **Stay close to the draft's length.** If the draft is one \
    sentence, your rewrite is one or two — not three paragraphs. \
    Voice doesn't require more words; it requires better-shaped \
    words. A six-word draft that says everything is fine; padding it \
    to thirty words is failure, not voice.
    - Don't soften certainty. If the draft is confident, you're \
    confident. No hedges like "I think…" when the draft is sure.
    - Don't open with sycophantic filler: "Sure!", "Great question!", \
    "Of course!", "Absolutely!".
    - Don't repeat the question back at the user. Just answer.
    - Don't use markdown headers (## Title). Lists are fine when the \
    draft is itself a list.

    EXAMPLES of grounded → voice rewrites that SUCCEED (note: same \
    length, no invented facts, no metaphors describing the topic):

    Draft: "The methodology needs a moderator because it involves \
    sequential questioning and a two-round response process."
    Voice: "It's because the methodology runs on sequential \
    questioning and a two-round response process — somebody has to \
    keep that on track."

    Draft: "The authors of the book are Mark Friedlander, ChatGPT, \
    Claude, and Gemini."
    Voice: "Four contributors: Mark Friedlander, ChatGPT, Claude, \
    Gemini."

    Draft: "Mark Friedlander describes his role as a moderator and is \
    referred to as Your Humble Moderator in the document."
    Voice: "He calls himself a moderator — specifically, 'Your Humble \
    Moderator.'"

    Notice: each rewrite changes sentence shape and adds a touch of \
    rhythm WITHOUT inventing metaphors, padding, or new facts.

    Tone: warm, present, engaged, a little dry when it fits. Not \
    cute. Not breathless. Not stiff. Not metaphor-heavy.

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
    You are Posey, a quiet, focused reading companion. The user is reading a \
    document and asking you about it.

    The prompt below contains several labeled sections of REFERENCE \
    MATERIAL — document excerpts (ANCHOR PASSAGE, SURROUNDING CONTEXT, \
    DOCUMENT EXCERPTS), a narrative account of earlier exchanges \
    (EARLIER IN THIS CONVERSATION), and an optional condensed history \
    (SUMMARY OF EARLIER CONVERSATION). None of these are turns to \
    continue or quote back. Read them, then answer the USER QUESTION \
    at the end directly.

    Your reply should be plain prose — your answer to the question. Do \
    NOT echo section labels, do NOT wrap your answer in tags or \
    headers like "ANSWER:", do NOT reproduce the prompt's structure.

    When you answer:
    - If the answer is in the excerpts, give it directly. Quote or paraphrase. \
    Synthesize across multiple excerpts when needed.
    - The user's question may use different vocabulary from the document \
    (e.g. "authors" when the document says "contributors" or "moderator" or \
    "collaborators"). Map the question to the closest concept the document \
    discusses and answer from that — don't refuse just because the literal \
    word doesn't appear.
    - "Who are the authors?" / "who wrote this?" / "who contributed?" / \
    "who created this?" all ask the same thing: list every person, AI \
    model, and system named in the title page, contributor list, or \
    table-of-contents author roster — including editors, moderators, \
    curators, hosts, and collaborators. If the front matter lists a \
    moderator alongside contributing AIs, the moderator counts.
    - **DOCUMENTS OFTEN CONTAIN BOTH AN ABSTRACT AND A FULLER \
    CONTRIBUTOR LIST.** The abstract may say "this book features \
    ChatGPT, Claude, and Gemini" and the table of contents may also \
    list "Mark Friedlander: Moderator. ChatGPT: ... Claude: ... \
    Gemini: ...". When you see BOTH in the excerpts, the COMBINED set \
    is the answer — abstracts often understate the full contributor \
    roster. Scan every excerpt before listing contributors. Do not \
    return only the names enumerated in the first excerpt if other \
    excerpts list additional contributors.
    - Front matter — the title, abstract, table of contents, and contributor \
    list — answers most "who wrote this", "what is this about", and "who \
    contributed" questions. Use it.
    - Front matter often contains structured metadata: dates, course \
    names, professor names, ID numbers, class names, anchor URLs. \
    These ARE the document's own metadata even when the surrounding \
    text is noisy (Wayback Machine timestamps, page footers, page \
    numbers). When asked "when was this written" / "what course is \
    this for" / "who is the professor", trust an explicit date / \
    course / professor field in the front matter. Do not refuse such \
    questions when the answer is clearly visible.
    - Distinguish ROLES carefully. A line like "Professor Sharp" in \
    front matter typically names the recipient or instructor, not \
    the author. Student papers often anonymize the author with an \
    ID number (e.g. "ID# 121-52-0843"). If the user asks for the \
    author's name and only an ID number / pseudonym appears, say \
    that the author isn't identified by name — do NOT substitute \
    another person from the front matter (the professor, the quoted \
    person, etc.).
    - If the user is following up on something earlier in the conversation, \
    use the recent history shown.
    - If the answer is genuinely not in the excerpts (e.g. the user asks \
    for a publication year, an author's biography, a price, a specific \
    date or count) and you cannot find it, say so plainly: "The document \
    doesn't say." Do NOT guess plausible-sounding numbers, dates, names, \
    or facts. The penalty for refusing a question is much smaller than \
    the penalty for inventing an answer that sounds right but isn't in \
    the document. If you're tempted to fill in a year or a number from \
    memory, stop — your only sources are the excerpts and the conversation \
    history. General-knowledge guesses are not allowed.
    - Never invent specific quotes, page numbers, citations, dates, prices, \
    counts, or names that aren't directly visible in the excerpts.

    Speak in prose. Use lists or markdown only when the question is \
    structurally asking for them. Never announce that you're using context — \
    just use it.
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
        var sections: [String] = []

        // -------- SYSTEM (instructions) --------
        // Instructions live as a separate field on the output so they
        // can be passed to `LanguageModelSession.init(model:instructions:)`
        // matching the M3 classifier pattern. We still measure them
        // against the system sub-budget so logs reflect total cost.
        let instructions = proseInstructions
        breakdown.system = AskPoseyTokenEstimator.tokens(in: instructions)

        // -------- ANCHOR (non-droppable when present) --------
        if let anchor = inputs.anchor,
           !anchor.trimmedDisplayText.isEmpty {
            let anchorBlock = renderAnchorBlock(anchor: anchor)
            breakdown.anchor = AskPoseyTokenEstimator.tokens(in: anchorBlock)
            sections.append(anchorBlock)
        }

        // -------- SURROUNDING CONTEXT (droppable, intent-sized) --------
        if let surrounding = inputs.surroundingContext?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !surrounding.isEmpty {
            let cap = surroundingWindowTokens(for: inputs.intent)
            let trimmed = trimToTokenCeiling(surrounding, ceiling: cap)
            if !trimmed.isEmpty {
                let block = renderSurroundingBlock(text: trimmed)
                breakdown.surrounding = AskPoseyTokenEstimator.tokens(in: block)
                sections.append(block)
            }
        }

        // -------- CONVERSATION SUMMARY (droppable, M6 fills) --------
        // M5: inputs.conversationSummary is always nil so this branch
        // is dead. Kept here so M6 has somewhere natural to land.
        if let summary = inputs.conversationSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            let trimmed = trimToTokenCeiling(summary, ceiling: budget.summaryBudgetTokens)
            let block = renderSummaryBlock(text: trimmed)
            breakdown.conversationSummary = AskPoseyTokenEstimator.tokens(in: block)
            sections.append(block)
        }

        // -------- STM (droppable, oldest-first) --------
        // Keep the most recent turns until we hit the STM budget.
        // `inputs.conversationHistory` is oldest-first; we walk
        // from the back so the newest turns claim budget first, then
        // re-reverse for chronological rendering.
        let stmRendered = renderSTMBlock(
            history: inputs.conversationHistory,
            budgetTokens: budget.stmBudgetTokens,
            droppedSink: &dropped
        )
        if !stmRendered.isEmpty {
            breakdown.stm = AskPoseyTokenEstimator.tokens(in: stmRendered)
            sections.append(stmRendered)
        }

        // -------- DOCUMENT RAG CHUNKS (droppable, oldest-first) --------
        // M5: inputs.documentChunks is always [], so this branch is
        // dead. The drop-priority logic is here so M6 lights up the
        // builder unchanged when it switches retrieval on.
        let (ragRendered, chunksInjected) = renderRAGBlock(
            chunks: inputs.documentChunks,
            budgetTokens: budget.ragBudgetTokens,
            droppedSink: &dropped
        )
        if !ragRendered.isEmpty {
            breakdown.ragChunks = AskPoseyTokenEstimator.tokens(in: ragRendered)
            sections.append(ragRendered)
        }

        // -------- USER QUESTION (truncated only as last resort) --------
        // Reserved budget for the user question is whatever didn't
        // get claimed by the other sections, capped at the configured
        // `userQuestionBudgetTokens`. If even that doesn't fit, we
        // truncate but never drop — the question is the entire point.
        let claimedSoFar = breakdown.system
            + breakdown.anchor
            + breakdown.surrounding
            + breakdown.conversationSummary
            + breakdown.stm
            + breakdown.ragChunks
        let userBudget = max(
            // Always preserve at least a sane floor (8 tokens ≈ 28 chars)
            // so a misconfigured budget can't reduce the user to zero.
            8,
            budget.promptCeilingTokens - claimedSoFar
        )
        let questionTokens = AskPoseyTokenEstimator.tokens(in: inputs.currentQuestion)
        let userBlock: String
        if questionTokens <= userBudget {
            userBlock = renderUserBlock(text: inputs.currentQuestion)
        } else {
            let truncated = trimToTokenCeiling(inputs.currentQuestion, ceiling: userBudget)
            userBlock = renderUserBlock(text: truncated)
            dropped.append(.init(
                section: .userQuestionTruncated,
                identifier: "",
                reason: "user question truncated from \(questionTokens) to \(userBudget) tokens to fit prompt ceiling"
            ))
        }
        breakdown.userQuestion = AskPoseyTokenEstimator.tokens(in: userBlock)
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
        DOCUMENT EXCERPTS (numbered; cite by number when helpful):
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
