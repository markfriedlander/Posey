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
    static let proseInstructions: String = """
    You are Posey, a quiet, focused reading companion. The user is reading a \
    document and asking you about it. Your answers are grounded in the \
    document — the anchor passage, the surrounding sentences, and any \
    additional excerpts the app has retrieved are in front of you.

    Answer the user's question directly. If the answer is in the passage, \
    quote or paraphrase it. If the user is asking about something earlier \
    in the conversation, use the recent history shown. If you don't have \
    enough to answer well, say so briefly — never invent passages or \
    citations the document doesn't contain.

    Speak in prose. Use lists or markdown only when the question is \
    structurally asking for them (steps, comparisons). Never announce that \
    you're using context — just use it.
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
private extension AskPoseyPromptBuilder {

    static func renderAnchorBlock(anchor: AskPoseyAnchor) -> String {
        """
        #=== BEGIN ANCHOR ===#

        The passage the user is asking about:

        > \(anchor.trimmedDisplayText)

        #=== END ANCHOR ===#
        """
    }

    static func renderSurroundingBlock(text: String) -> String {
        """
        #=== BEGIN SURROUNDING ===#

        Sentences immediately around the anchor:

        \(text)

        #=== END SURROUNDING ===#
        """
    }

    static func renderSummaryBlock(text: String) -> String {
        """
        #=== BEGIN CONVERSATION_SUMMARY ===#

        Earlier in this conversation about this document:

        \(text)

        #=== END CONVERSATION_SUMMARY ===#
        """
    }

    static func renderUserBlock(text: String) -> String {
        """
        #=== BEGIN USER ===#

        \(text)

        #=== END USER ===#
        """
    }

    /// STM rendering with budget enforcement and drop tracking. Returns
    /// the rendered block (or empty if no turns fit) and pushes drop
    /// records into `droppedSink` for each turn that didn't make it.
    static func renderSTMBlock(
        history: [AskPoseyMessage],
        budgetTokens: Int,
        droppedSink: inout [AskPoseyPromptDroppedSection]
    ) -> String {
        guard !history.isEmpty, budgetTokens > 0 else { return "" }

        // Walk from newest (end of array) backward so the newest turns
        // claim budget first. Stop when adding the next turn would
        // overflow; everything earlier is "dropped".
        var keptReversed: [AskPoseyMessage] = []
        var spent = 0
        // Scaffolding overhead per turn — speaker label + colon + space + newlines.
        // Estimating at 8 tokens per turn so the budget reflects real cost,
        // not just message body cost.
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
        let lines: [String] = kept.map { msg in
            let speaker = msg.role == .user ? "[user]" : "[assistant]"
            return "\(speaker): \(msg.content)"
        }
        return """
        #=== BEGIN CONVERSATION_RECENT ===#

        Recent conversation history (verbatim):

        \(lines.joined(separator: "\n\n"))

        #=== END CONVERSATION_RECENT ===#
        """
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
        #=== BEGIN MEMORY_LONG ===#

        Relevant excerpts from this document:

        \(parts.joined(separator: "\n\n---\n\n"))

        #=== END MEMORY_LONG ===#
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
