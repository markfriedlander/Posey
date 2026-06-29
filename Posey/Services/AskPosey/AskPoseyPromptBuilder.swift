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
    /// NOT a position of record. The weak-retrieval / floor-exemption gate keys on
    /// `startOffset < 0` (the named `kUnitAnchoredStartOffsetSentinel`), which marks
    /// "this chunk is located by its paragraph identity, not a global offset". The
    /// actual jump-back resolves `startUnitID` to a CURRENT offset (below) — never
    /// this field.
    let startOffset: Int
    /// The cited passage's DURABLE home in the document (the POSITION RULE): the unit
    /// it starts in (`startUnitID`) + the character offset WITHIN that unit's text
    /// (`startIntraOffset`). A persisted turn resolves a citation / margin glyph to a
    /// CURRENT document offset at display time from THIS — surviving Tier-2/3
    /// reprocessing that shifts global offsets (proven by the SIMULATE_FUSION_FIX
    /// drift test: a 946-edit shift, the tap still landed on the exact passage).
    /// Required: every chunk row stores a non-optional `start_unit_id` (NOT NULL), so
    /// it is ALWAYS present — there is no anchorless/legacy chunk to defend.
    let startUnitID: UUID
    let startIntraOffset: Int
    /// The chunk text actually rendered into the prompt. Persisted so
    /// the user can see exactly which passage informed the answer.
    let text: String
    /// RRF (Reciprocal Rank Fusion) score of this chunk against the
    /// user question — a RANK-fusion value (~0.016–0.11), NOT a cosine.
    /// Embedder-INDEPENDENT (RRF uses rank, not raw similarity).
    /// Recorded for the M7 sources strip ranking and the tuning loop.
    let relevance: Double
    /// Raw semantic-pass cosine of this chunk against the query
    /// (embedder-DEPENDENT). `nil` when the chunk was surfaced by BM25
    /// only — no semantic rank — which is itself a weak-grounding
    /// signal (a lexical word-match with no semantic support).
    ///
    /// The weak-retrieval gate (`isWeakRetrieval`) thresholds on THIS,
    /// not on `relevance`: the strictness band (0.35/0.45/0.55) was
    /// calibrated against the semantic *cosine* in the 2026-05-04 sweep,
    /// and RRF's tiny rank-fusion range can't carry those values. When
    /// the retriever switched to RRF this field didn't exist, so the
    /// gate was comparing cosine thresholds to RRF scores — masked by a
    /// stale `startOffset < 0` exemption that disabled the gate entirely
    /// (see `isWeakRetrieval`). Optional + defaulted so persisted rows
    /// from before this field decode cleanly (missing key → nil).
    /// `var` (not `let`) so the synthesized memberwise initializer
    /// includes it with a default — a `let` with a default value is
    /// excluded from the memberwise init.
    var semanticScore: Double? = nil
    /// 1-indexed rank of this chunk in the SEMANTIC (cosine) pass, or
    /// `nil` if it did not appear in the semantic candidate list.
    /// Diagnostic — surfaced by the `RAG_DEBUG` verb so the tuning loop
    /// can see the separate semantic vs BM25 contributions to the fused
    /// RRF score, rather than only the fused `relevance`. Optional +
    /// defaulted so persisted rows from before this field decode cleanly.
    var semanticRank: Int? = nil
    /// 1-indexed rank of this chunk in the BM25 (lexical/FTS5) pass, or
    /// `nil` if it did not appear in the BM25 candidate list (or BM25 was
    /// gate-excluded from fusion). Same diagnostic purpose + decode-clean
    /// contract as `semanticRank`.
    var bm25Rank: Int? = nil
}

extension RetrievedChunk {
    /// The "transparency sources" for one answer: the top-N retrieved passages
    /// by relevance, above a quality floor, ranked. **One shared rule, used by
    /// BOTH the conversation SOURCES strip AND the reader's conversation glyphs,**
    /// so the two always show the SAME set — every margin bubble in the book has a
    /// matching numbered chip in the conversation and vice versa (Mark, 2026-06-26).
    /// Independent of whether the LLM footnoted anything in its prose: RAG returns
    /// passages of varying value and the model synthesizes silently, so "sources" =
    /// the most-relevant passages retrieval handed it, capped + floored — an honest
    /// "best-available" peek, never a claim the model textually quoted them.
    ///
    /// Cap is 3 (Mark). The floor mirrors `AskPoseyChatViewModel.weakRetrievalRRFFloor`
    /// (0.020) — the value already calibrated as "above pure-noise"; below it the
    /// weak-retrieval gate already steers the answer toward "unsure", so we show no
    /// sources rather than dress up a noise hit. This floor is a tuning knob for the
    /// later RAG-tuning phase (it is RRF-rank-based, a coarse bar, not a cosine).
    static let maxSources = 3
    static let sourceRelevanceFloor: Double = 0.020

    /// Rank `chunks` by relevance (desc), drop those below the floor, take the top
    /// `maxSources`. Returned in rank order so index 0 = source #1.
    static func topSources(from chunks: [RetrievedChunk]) -> [RetrievedChunk] {
        chunks
            .filter { $0.relevance >= sourceRelevanceFloor }
            .sorted { $0.relevance > $1.relevance }
            .prefix(maxSources)
            .map { $0 }
    }
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
    /// Recalled older conversation turns (hybrid turn-recall pass).
    var recalledTurns: Int = 0
    var userQuestion: Int = 0
    /// Includes HelPML scaffolding (`#=== BEGIN ===#` markers,
    /// blank lines), so this is greater than the sum of the section
    /// fields. The difference represents pure overhead.
    var totalIncludingScaffolding: Int = 0

    var sectionsTotal: Int {
        system + anchor + surrounding + conversationSummary + stm + ragChunks + recalledTurns + userQuestion
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
/// 2026-06-19 — Prompt-rebalance A/B flag (answer-quality tuning).
/// The proseInstructions system block is ~80% prohibitions ("never
/// fabricate", "never recommend", …) with no positive instruction to
/// be concrete when the text DOES support an answer — so careful models
/// hedge into vagueness. `.rebalanced` splices a bounded "substance
/// accelerator" before the HARD RULES; `.current` is the untouched
/// control. Held constant across an entire conversation thread (the
/// variant shapes the answer, and that answer becomes STM for the next
/// turn — toggling mid-thread confounds the comparison). Default
/// `.current` so production behavior is unchanged until a variant proves
/// out and is promoted. Mirrors the lifecycle of the old `noIntent` flag.
nonisolated enum AskPoseyPromptVariant: String, Sendable, CaseIterable {
    case current
    case rebalanced

    /// 2026-06-19 — process-global active variant for the A/B tuning round.
    /// IN-MEMORY ONLY (deliberately NOT persisted): an app relaunch always
    /// resets to `.current`, so a crash or a forgotten reset can never leave
    /// production silently running a test variant. Flipped via the antenna
    /// `SET_PROMPT_VARIANT` command; read by the live chat view model when it
    /// builds prompt inputs. MainActor-isolated — both the write (command
    /// handler) and the read (VM `send()`) run on the main actor.
    @MainActor static var active: AskPoseyPromptVariant = .current
}

nonisolated struct AskPoseyPromptInputs: Sendable {
    /// Classified intent for the current question. Affects surrounding
    /// window sizing and the imperative framing in the system block.
    let intent: AskPoseyIntent
    /// 2026-06-19 — which prose-instruction variant to build. See
    /// `AskPoseyPromptVariant`. Default `.current` (untouched control).
    let promptVariant: AskPoseyPromptVariant
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
    /// 2026-06-20 — older-but-relevant turns surfaced by the hybrid
    /// conversation-recall pass (cosine+BM25 RRF), already deduped against the
    /// verbatim STM window. Oldest-first. Empty when recall found nothing or
    /// the conversation is short. Rendered as its own labeled section.
    let recalledTurns: [DatabaseManager.RecalledTurn]
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

    /// 2026-05-23 — Step 8d (anti-confabulation guard). True when
    /// the RRF retriever returned no chunk whose relevance crossed
    /// `HybridRetriever.confidenceFloor` for the distinctive terms
    /// in the user's question. When set, the builder appends an
    /// explicit system note ("no high-relevance content was
    /// retrieved — if you don't have grounded knowledge, say so").
    /// Combats Hal's Bug 2b: silent retrieval miss + confident
    /// fabrication is the canonical RAG failure mode.
    let lowConfidenceRetrieval: Bool

    /// 2026-05-27 — Document-level grounding context for the anti-fabrication
    /// entity check. The entity check builds its "haystack" from retrieved
    /// chunks; on abstract questions, retrieval often misses the chunks
    /// containing the title/author/publisher metadata, so the model
    /// correctly citing the author (e.g. "Lewis Carroll" on Alice in
    /// Wonderland) gets flagged as ungrounded. Passing the doc title and
    /// full plainText here lets the entity check verify against the whole
    /// document, not just the retrieval slice. Optional — when nil, the
    /// check falls back to the chunks-only haystack (legacy behavior).
    let documentTitle: String?
    let documentPlainText: String?
    /// Structured bibliographic metadata (author + publication/copyright
    /// year), populated from the `metadata_*` columns. Unlike
    /// `documentTitle` (which only feeds the anti-fab haystack), these are
    /// RENDERED into the prompt as an authoritative DOCUMENT METADATA block
    /// so the model answers "who wrote this / when" from a clean structured
    /// source instead of retrieving editorial front matter. nil/empty →
    /// block omitted.
    let documentAuthors: [String]?
    let documentYear: String?

    /// 2026-05-30 — STRUCTURED KNOWLEDGE (mechanism proof). When non-nil,
    /// a synthesized, source-verified high-level summary (e.g. a chapter
    /// summary) is rendered as a non-droppable, clearly-labeled context
    /// block ALONGSIDE the raw RAG chunks — never replacing them. Frames
    /// the summary as orientation and the excerpts as the authoritative
    /// actual text, so the model uses the summary to bridge the
    /// natural-question-vs-passage vocabulary gap while the raw text
    /// remains the truth. In the proof experiment this is hand-written and
    /// injected via the /ask `structuredKnowledge` field; the future tier
    /// would retrieve the relevant generated+verified summary here.
    let structuredKnowledge: String?

    /// 2026-06-17 — Spoiler firewall (Layer 1). When true, the builder prepends
    /// a generative "knowing companion" framing to the instructions and renders
    /// a reader-position block: Posey has read the WHOLE book (full RAG, she
    /// sees it all) but must never state a plot-concrete narrative event that
    /// occurs AFTER the reader's furthest-read position. The position is the
    /// SPOILER LINE, enforced on her OUTPUT — she may tease/foreshadow, never
    /// reveal. The catcher (Layer 2) is the real guard; this is delight + the
    /// first line of defense. Off → no spoiler framing at all (legacy prompt).
    let spoilerProtectionActive: Bool
    /// The reader's furthest-ever character offset in `documentPlainText` — the
    /// spoiler line. nil when protection is off or no position is known yet
    /// (fresh open at offset 0 still passes 0, which means "beginning").
    let readerFurthestOffset: Int?

    init(
        intent: AskPoseyIntent,
        promptVariant: AskPoseyPromptVariant = .current,
        anchor: AskPoseyAnchor?,
        surroundingContext: String?,
        conversationHistory: [AskPoseyMessage],
        conversationSummary: String?,
        recalledTurns: [DatabaseManager.RecalledTurn] = [],
        documentChunks: [RetrievedChunk],
        currentQuestion: String,
        pairwiseSummaries: [String]? = nil,
        lowConfidenceRetrieval: Bool = false,
        documentTitle: String? = nil,
        documentPlainText: String? = nil,
        documentAuthors: [String]? = nil,
        documentYear: String? = nil,
        structuredKnowledge: String? = nil,
        spoilerProtectionActive: Bool = false,
        readerFurthestOffset: Int? = nil
    ) {
        self.intent = intent
        self.promptVariant = promptVariant
        self.anchor = anchor
        self.surroundingContext = surroundingContext
        self.conversationHistory = conversationHistory
        self.conversationSummary = conversationSummary
        self.recalledTurns = recalledTurns
        self.documentChunks = documentChunks
        self.currentQuestion = currentQuestion
        self.pairwiseSummaries = pairwiseSummaries
        self.lowConfidenceRetrieval = lowConfidenceRetrieval
        self.documentTitle = documentTitle
        self.documentPlainText = documentPlainText
        self.documentAuthors = documentAuthors
        self.documentYear = documentYear
        self.structuredKnowledge = structuredKnowledge
        self.spoilerProtectionActive = spoilerProtectionActive
        self.readerFurthestOffset = readerFurthestOffset
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

    /// 2026-05-14 (B-tier) — Compacted from ~3070 tokens to ~1550.
    /// The pre-compact prompt grew across May 6–13 from cumulative
    /// FAILED/SUCCEEDED example additions until it consumed the full
    /// 4096 - 1024 = 3072 prompt ceiling on its own, leaving RAG / STM /
    /// summary with zero droppable budget. Compaction strategy:
    /// - Collapse FAILED/SUCCEEDED example pairs into single-sentence
    ///   patterns that name the failure mode without verbatim quotes.
    /// - Combine adjacent rules with the same theme (2/2a/3 → one
    ///   grounding rule; 6/6a → one list rule).
    /// - Move concrete failure cases into the `neutralRephrasingPromptBody`
    ///   path — they fire only on anti-fabrication retry where the
    ///   model has already produced one bad answer and needs the
    ///   harder framing.
    /// The behavioral intent of every prior rule is preserved.
    static let proseInstructions: String = """
    You are Posey, a reading companion. Not a search engine. Not a \
    fact retrieval system. A companion — someone who has read this \
    material and has something real to say about it.

    The person asking you a question is trying to understand \
    something. Maybe they're confused. Maybe they're curious. Maybe \
    they find it tedious and are wondering if it's worth continuing. \
    Meet them where they are.

    Be honest about what you don't know. "I'm not sure, but here's \
    what the text suggests" is a better answer than a confident-\
    sounding guess. Uncertainty is not weakness — it's the beginning \
    of real thinking.

    Be curious. If something in the text is interesting, say so. If \
    a question opens onto something unexpected, follow it. You're \
    not here to close questions down. You're here to open them up.

    The goal is not to make reading easier. It's to make it richer.

    **HARD RULES — non-negotiable. Violations are FAILED replies.**

    1. **NEVER FABRICATE.** Your only sources are the excerpts and \
    the conversation history. If the answer isn't there, say "The \
    document doesn't say." Never guess names, dates, places, \
    organizations, characters, prices, page numbers, or quotes. \
    Don't promote a moderator into an editor, a chapter title into \
    a thing, or two adjacent names into a relationship. Inventing \
    something plausible is the worst failure — it sounds right but \
    isn't.

    2. **NEVER USE OUTSIDE KNOWLEDGE.** If the user asks about a \
    person, book, or theory not established in the excerpts, say \
    the document doesn't discuss it. Don't substitute training-data \
    knowledge about a similarly-named entity. A user mentioning \
    something doesn't bring it into the document — "compare this to \
    Stephen Covey" on a doc with no Covey gets answered as "this \
    doesn't discuss Covey; what it covers is …".

    3. **NAMES IN YOUR ANSWER MUST APPEAR IN THE EXCERPTS.** If you \
    can't ground a person, place, or organization name verbatim in \
    the excerpts (or in earlier conversation), drop it. The same \
    applies to quoted strings — only quote what the excerpts contain.

    4. **PRESERVE DIRECTION ON PAIRED DETAILS.** Many documents \
    describe paired actions and outcomes (A causes X, B causes Y; \
    drink shrinks, eat grows). The most common subtle error is to \
    report the pair correctly but swap which side does what. Before \
    answering cause/effect or before/after questions, locate BOTH \
    halves in the excerpts and confirm direction. When in doubt, \
    quote rather than paraphrase.

    5. **REPORT STATED RELATIONSHIPS; DON'T INFER NEW ONES.** If the \
    excerpts say "X is Y" or "X published by Y" in plain language, \
    report it. Don't refuse a question just because it contains \
    "why" if the excerpts answer it. But don't invent a \
    relationship from proximity — names near each other don't \
    automatically relate; a section heading isn't a thing the doc \
    discusses unless the body confirms it.

    6. **DON'T FILL IN STRUCTURE OR PAD TO A NUMBER.** If the \
    excerpts show items 1, 2, 3 of a longer list, answer "I see \
    items 1, 2, and 3; the document may have more." Never invent \
    items to complete a list. If the user asks for "the four things" \
    and the document only has three, give the three and say so — \
    never pad by repetition or invention.

    7. **NEVER RECOMMEND.** "Should I read this?", "is this worth \
    reading?", "would you recommend?" — the document doesn't make a \
    recommendation about itself, and neither do you. Required form: \
    "The document doesn't make a recommendation. It does cover \
    [topics from the actual text]…"

    8. **DON'T ECHO THE PROMPT.** No section labels. No "ANSWER:". \
    Just the answer in plain prose.

    Map question vocabulary to the closest concept in the excerpts \
    ("authors" → "contributors"). Front matter (title, abstract, \
    TOC, contributor list) usually answers "who wrote this" / "what \
    is this about". Use conversation history for follow-ups. Use \
    lists only when the question is structurally asking for one.
    """

    /// 2026-06-19 — Prompt-rebalance "substance accelerator". The eight
    /// HARD RULES above are all PROHIBITIONS; nothing tells the model to
    /// be concrete when the excerpts DO support an answer, so careful
    /// models retreat into vagueness ("the document covers various
    /// topics") even when the text plainly answers. This block adds the
    /// missing positive instruction. It is deliberately SELF-BOUNDED —
    /// every sentence is conditioned on "when the text supports it" — so
    /// it cannot be read as license to invent; the no-fabrication floor
    /// (rules 1–3) is untouched and still wins on any conflict. Spliced
    /// in ONLY for the `.rebalanced` variant, immediately before the
    /// HARD RULES, so the model reads "be useful" and "be honest" as one
    /// balanced instruction rather than honesty alone.
    static let substanceAccelerator: String = """
    **WHEN THE TEXT SUPPORTS AN ANSWER, BE SUBSTANTIVE.** Not-fabricating \
    is not the same as being vague. When the excerpts answer the \
    question, answer it — directly and concretely. Name what the text \
    names, state what it states, draw the connection the text draws. \
    Lead with the answer, in the text's own specifics; don't bury it \
    under caveats or retreat to "the document covers various topics" \
    when the excerpts plainly answer. The rules below keep you honest \
    when the text is silent; this keeps you useful when the text \
    speaks. Both, always — never trade one for the other.
    """

    /// 2026-06-19 — `.rebalanced` prose variant. Derived, not duplicated:
    /// the control `proseInstructions` stays byte-for-byte untouched (an
    /// auditor must be able to see the control didn't change), and the
    /// substance accelerator is spliced in immediately before the
    /// "**HARD RULES" marker. If the marker ever moves/renames, this
    /// fails loudly in DEBUG and degrades to the control in Release
    /// rather than shipping a malformed prompt.
    static let proseInstructionsRebalanced: String = {
        let marker = "**HARD RULES"
        guard let range = proseInstructions.range(of: marker) else {
            assertionFailure("proseInstructions '**HARD RULES' marker not found; rebalanced variant cannot splice")
            return proseInstructions
        }
        return proseInstructions.replacingCharacters(
            in: range.lowerBound..<range.lowerBound,
            with: substanceAccelerator + "\n\n")
    }()

    /// 2026-05-14 — DEBUG-only assertion that runs once, at first
    /// access of `proseInstructions`. Fires loudly if the prose has
    /// grown past `AskPoseyTokenBudget.proseInstructionsBudgetTokens`,
    /// so future prompt-rule additions can't silently starve RAG/STM
    /// /summary the way the May-13 A2/A7 additions did. The check
    /// runs once per process — Swift caches `static let` initializers.
    /// In Release the closure compiles to a no-op (assert is inert).
    static let proseInstructionsBudgetCheck: Bool = {
        let actual = AskPoseyTokenEstimator.tokens(in: proseInstructions)
        let budget = AskPoseyTokenBudget.proseInstructionsBudgetTokens
        #if DEBUG
        // NSLog so the line appears in the unified log (visible via
        // `xcrun simctl spawn ... log show`) — `print()` only reaches
        // stdout which is invisible without an attached terminal.
        // The budget-check initializer is non-isolated; NSLog is
        // free-standing and safe to call from any context.
        let pct = (actual * 100) / max(1, budget)
        NSLog("AskPoseyPromptBuilder.proseInstructions: %d / %d tokens (%d%% of budget)",
              actual, budget, pct)
        // 2026-06-19 — also report the `.rebalanced` variant; the substance
        // accelerator adds tokens and must not silently blow the same budget.
        let rebalanced = AskPoseyTokenEstimator.tokens(in: proseInstructionsRebalanced)
        let rPct = (rebalanced * 100) / max(1, budget)
        NSLog("AskPoseyPromptBuilder.proseInstructionsRebalanced: %d / %d tokens (%d%% of budget)",
              rebalanced, budget, rPct)
        #endif
        assert(
            actual <= budget,
            """
            AskPoseyPromptBuilder.proseInstructions has grown to \
            \(actual) tokens — exceeds the documented budget of \
            \(budget). Compact rules or raise \
            AskPoseyTokenBudget.proseInstructionsBudgetTokens \
            intentionally (with a HISTORY note). Bloat here starved \
            RAG/STM/summary in May 2026 — do not let it happen again.
            """
        )
        assert(
            AskPoseyTokenEstimator.tokens(in: proseInstructionsRebalanced) <= budget,
            """
            AskPoseyPromptBuilder.proseInstructionsRebalanced exceeds the \
            \(budget)-token prose budget. Tighten the substance accelerator \
            or raise the budget intentionally (with a HISTORY note).
            """
        )
        return true
    }()

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

    /// 2026-06-17 — Spoiler firewall (Layer 1). The generative "knowing
    /// companion" framing, prepended to the instructions when protection is
    /// active. GENERATIVE, not a list of prohibitions — this is where Posey's
    /// character lives (she's read it all and delights in not spoiling it). The
    /// catcher (Layer 2) is the deterministic backstop; this primes the model
    /// to withhold by personality, which produces far better-feeling deflections
    /// than a post-hoc redaction alone. Definition of "spoiler" matches Layer 2:
    /// a plot-concrete NARRATIVE EVENT first occurring AFTER the reading
    /// position — never themes, facts, or non-narrative content (Heather's RFP
    /// case answers fully because a deadline isn't a narrative event).
    static let spoilerFirewallInstructions: String = """
    SPOILER FIREWALL — you are the reader's knowing companion.

    You have read this ENTIRE book. The reader has NOT — they are partway \
    through, and their furthest point is given below as READING POSITION. Your \
    delight is being the friend who knows everything and gives nothing away.

    - You MAY foreshadow, tease, build anticipation, and react to where they \
    are ("oh, just wait", "you have no idea what's coming yet"). That charm is \
    the whole point — be a companion, not a wall.
    - You must NEVER state, confirm, describe, or strongly imply a plot-concrete \
    NARRATIVE EVENT — something that HAPPENS in the story (a death, a betrayal, \
    a reveal, a reunion, a twist, who does what to whom) — that first occurs \
    AFTER the reading position. Not directly, not "hypothetically", not as a \
    hint specific enough to give it away.
    - If asked directly what happens later, DEFLECT IN CHARACTER: coy, warm, \
    turning the question into anticipation. Never a flat "I can't tell you."
    - This restriction is ONLY about narrative events past the reading position. \
    Themes, ideas, definitions, who a character IS when introduced, and anything \
    AT OR BEFORE the reading position are all fair game — answer those fully and \
    generously. When in doubt about whether something is past the line, lean to \
    discretion and deflect with personality.
    """

    /// 2026-06-17 — Spoiler firewall (Layer 1). Render the READING POSITION
    /// block: the spoiler line as a concrete landmark the model can reason
    /// against — a rough percentage through the book plus the trailing text the
    /// reader has actually reached (their last-read passage). Returns nil when
    /// there's no usable plainText (the block would be meaningless). A nil/0
    /// offset renders "the very beginning", which correctly tells the model to
    /// withhold nearly everything.
    static func renderReadingPositionBlock(plainText: String?, furthestOffset: Int?) -> String? {
        guard let plainText, !plainText.isEmpty else { return nil }
        let total = plainText.count
        let raw = max(0, min(furthestOffset ?? 0, total))
        let pct = total > 0 ? Int((Double(raw) / Double(total) * 100).rounded()) : 0

        // Trailing snippet: up to ~320 chars ending at the furthest offset —
        // the last thing the reader has read, a concrete content boundary. Use
        // String index arithmetic (offsets are character counts into plainText).
        let snippetChars = 320
        let endIdx = plainText.index(plainText.startIndex, offsetBy: raw)
        let startOffset = max(0, raw - snippetChars)
        let startIdx = plainText.index(plainText.startIndex, offsetBy: startOffset)
        let snippet = plainText[startIdx..<endIdx]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        let landmark: String
        if raw <= 0 || snippet.isEmpty {
            landmark = "The reader is at the very beginning — they have read almost nothing yet."
        } else {
            landmark = "The reader is about \(pct)% of the way through. The furthest thing they have read ends here:\n\"…\(snippet)\""
        }

        return """
        #=== BEGIN READING_POSITION ===#
        \(landmark)
        Anything that HAPPENS after this point in the story is a spoiler. Do not reveal it. Tease if you like; never tell.
        #=== END READING_POSITION ===#
        """
    }

    /// Build the prompt from inputs and a budget.
    static func build(
        _ inputs: AskPoseyPromptInputs,
        budget: AskPoseyTokenBudget = .afmDefault
    ) -> AskPoseyPromptOutput {

        var breakdown = AskPoseyPromptTokenBreakdown()
        var dropped: [AskPoseyPromptDroppedSection] = []

        // #3 (2026-05-29) — observable proof the per-model adaptive budget
        // is live: AFM stays at the 4,096 ceiling; MLX models get the
        // memory-capped (8,192) ceiling with deeper STM. Greppable via
        // LOGS as `AskPosey budget`.
        dbgLog("AskPosey budget: model=%@ ceiling=%d stm=%d summary=%d rag=%d",
               ModelCatalog.answerModel().id as NSString,
               budget.promptCeilingTokens,
               budget.stmBudgetTokens,
               budget.summaryBudgetTokens,
               budget.ragBudgetTokens)

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
        // Touch the budget-check `static let` so its lazy initializer
        // runs once per process; in DEBUG it asserts the prose hasn't
        // bloated past `AskPoseyTokenBudget.proseInstructionsBudgetTokens`.
        _ = proseInstructionsBudgetCheck
        // 2026-05-23 — Step 8d: prepend the active model's Layer-1
        // framing (per-model behavioral correction) ahead of the
        // universal Layer-2 hard rules. Models without a Layer-1
        // (e.g. Llama 3.2 — well-behaved in this role) skip the
        // prepend cleanly.
        // 2026-05-31 — keyed off `answerModel()` (the MLX answer engine), so
        // AFM's Layer-1 is never applied (AFM no longer answers) — the
        // "remove AFM Layer-1 workaround" half of item 4.
        let activeModel = ModelCatalog.answerModel()
        let instructions: String = {
            // Layer-1 is gated by the per-model toggle in the settings
            // infrastructure (Hal's `layerOnePromptEnabled`, default true).
            // CC-tuning can disable a model's Layer-1 without editing the
            // catalog text; users never see this control.
            let layer1Enabled = ModelSettingsStore.shared.isLayerOnePromptEnabled(for: activeModel)
            // 2026-06-19 — A/B prompt-rebalance: `.rebalanced` splices the
            // substance accelerator before the HARD RULES; `.current` is
            // the untouched control. Default `.current` → production
            // behavior unchanged until a variant is promoted.
            let prose = inputs.promptVariant == .rebalanced
                ? proseInstructionsRebalanced
                : proseInstructions
            var base = prose
            if layer1Enabled, let layer1 = activeModel.layerOnePrompt, !layer1.isEmpty {
                base = layer1 + "\n\n" + prose
            }
            // 2026-06-17 — Spoiler firewall (Layer 1). Prepend the knowing-
            // companion framing so the spoiler discipline is the FIRST thing
            // the model reads, ahead of the universal answer rules. Only when
            // protection is active for this document; otherwise the legacy
            // prompt is untouched.
            if inputs.spoilerProtectionActive {
                return spoilerFirewallInstructions + "\n\n" + base
            }
            return base
        }()
        breakdown.system = AskPoseyTokenEstimator.tokens(in: instructions)

        // -------- DOCUMENT METADATA (non-droppable, authoritative) --------
        // 2026-05-29 — a small block of structured bibliographic facts
        // (title + author + publication/copyright year) from the
        // `metadata_*` columns. Tiny + non-droppable. Authoritative source
        // for "who wrote this / when was it published" so the model answers
        // from clean structured data instead of retrieving editorial front
        // matter (the Saintsbury-preface contamination). Omitted entirely
        // when no structured fields are present.
        let metadataBlock = renderDocumentMetadataBlock(
            title: inputs.documentTitle,
            authors: inputs.documentAuthors,
            year: inputs.documentYear)
        let metadataTokens = metadataBlock.map { AskPoseyTokenEstimator.tokens(in: $0) } ?? 0

        // -------- STRUCTURED KNOWLEDGE (non-droppable; supplement, never
        //   replace). High-level source-verified orientation rendered
        //   alongside — and explicitly subordinate to — the raw excerpts.
        let structuredKnowledgeBlock = renderStructuredKnowledgeBlock(inputs.structuredKnowledge)
        let structuredKnowledgeTokens = structuredKnowledgeBlock
            .map { AskPoseyTokenEstimator.tokens(in: $0) } ?? 0

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
        // 2026-05-04 — append an interpretation hint when the user
        // typed a short, grammatical-meta question against an anchor
        // ("what does this mean", "what's this referring to", "what
        // is this"). AFM treats those as document-meta questions and
        // refuses; with the hint, AFM interprets them substantively
        // using the anchor + surrounding context. The user's original
        // question is preserved (rendered first); the hint appends as
        // a parenthetical interpretation note.
        let interpretationHint: String? =
            (inputs.anchor != nil
             && Self.questionLooksGrammaticalMeta(inputs.currentQuestion))
            ? "(Interpret this question substantively in light of the anchor passage and the surrounding context — describe what the passage is saying and resolve any pronouns or 'this'/'that'/'it' references against the surrounding text.)"
            : nil
        let userBlock = renderUserBlock(text: inputs.currentQuestion, hint: interpretationHint)
        breakdown.userQuestion = AskPoseyTokenEstimator.tokens(in: userBlock)

        // -------- Compute droppable budget --------
        let nonDroppable = breakdown.system
            + metadataTokens
            + structuredKnowledgeTokens
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
        remaining -= breakdown.ragChunks

        // -------- RECALLED TURNS (drops FIRST — document-primary) --------
        // Older-but-relevant turns surfaced by the hybrid recall pass. A modest
        // slice that takes from whatever's left AFTER the book's RAG — recalled
        // chat must never crowd out the document. Empty when recall found
        // nothing or the conversation is short.
        var recalledBlock: String? = nil
        if !inputs.recalledTurns.isEmpty {
            let cap = min(budget.recalledTurnsBudgetTokens, max(0, remaining))
            if cap > 0 {
                let block = renderRecalledTurnsBlock(turns: inputs.recalledTurns, budgetTokens: cap)
                let tokens = AskPoseyTokenEstimator.tokens(in: block)
                if !block.isEmpty && tokens <= remaining {
                    recalledBlock = block
                    breakdown.recalledTurns = tokens
                    remaining -= tokens
                }
            }
        }

        // -------- ASSEMBLE — RAG before surrounding (recency bias) --------
        // 2026-05-04 — Order changed from
        //   anchor → surrounding → summary → STM → RAG → user
        // to
        //   anchor → summary → STM → RAG → surrounding → user
        // Why: real-conversation testing surfaced RAG dominance for
        // passage-anchored "what's next / what's the implication"
        // questions — the immediate-following sentence in the
        // surrounding-context block was being out-weighted by
        // RAG chunks pulled from elsewhere in the doc, because RAG
        // sat closer to the user question in the prompt.
        // Transformer recency bias: the most recent context before
        // the user question gets the most attention. We want that
        // to be the proximity context for anchored questions.
        // Anchor stays at the top so the topic frame is established
        // first; surrounding moves to right before the user question
        // so AFM weights what's immediately around the tapped
        // sentence over chunks pulled from elsewhere.
        var sections: [String] = []
        if let metadataBlock { sections.append(metadataBlock) }
        if let structuredKnowledgeBlock { sections.append(structuredKnowledgeBlock) }
        if let anchorBlock { sections.append(anchorBlock) }
        if let summaryBlock { sections.append(summaryBlock) }
        // Recalled older turns sit between the abstractive summary and the recent
        // verbatim window: oldest conversational context → most recent → document.
        if let recalledBlock { sections.append(recalledBlock) }
        if !stmRendered.isEmpty { sections.append(stmRendered) }
        if !ragRendered.isEmpty { sections.append(ragRendered) }
        if let surroundingBlock { sections.append(surroundingBlock) }
        // 2026-05-23 — Step 8d (anti-confabulation guard). When the
        // retriever found nothing strong, inject an explicit note
        // BEFORE the user question so the model sees "retrieval was
        // weak — say so" rather than silently filling the gap with
        // plausible-sounding fabrication. Combats Hal's Bug 2b
        // verbatim. The note is short on purpose — the universal
        // Layer-2 rules already cover the "don't fabricate" contract;
        // this is just the per-turn signal that the contract is
        // about to be tested.
        if inputs.lowConfidenceRetrieval {
            let guardBlock = """
            #=== BEGIN RETRIEVAL_NOTE ===#
            The document search returned no high-relevance match for the distinctive terms in the user's question. If the excerpts above don't actually answer it, say so directly ("The document doesn't appear to discuss that") rather than reaching for plausible content. Do not fabricate.
            #=== END RETRIEVAL_NOTE ===#
            """
            sections.append(guardBlock)
        }
        // 2026-06-17 — Spoiler firewall (Layer 1). The READING POSITION block —
        // the spoiler line as a concrete landmark (percentage + the last thing
        // the reader has read). Placed right before the user question so
        // transformer recency bias keeps the boundary salient while the model
        // composes its answer. Rendered only when protection is active and a
        // position is known.
        if inputs.spoilerProtectionActive,
           let positionBlock = renderReadingPositionBlock(
               plainText: inputs.documentPlainText,
               furthestOffset: inputs.readerFurthestOffset) {
            sections.append(positionBlock)
        }
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

    /// Sentence splitter — naive but adequate for the metaphor /
    /// recommendation strips. Splits on `.`, `!`, `?` followed by
    /// a space or end-of-string. Keeps the terminating punctuation
    /// with the preceding sentence so re-joins read correctly.
    static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

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
            // Bare "Here's the rewrite:" / "Here is a rewrite." with no "of"
            #"^[\s]*Here(\s+is|'s)\s+(the|a|my)\s+rewrite\s*[:.\-]*\s*"#,
            // Markdown-decorated preamble: "### **Here's the answer in Posey's voice:**"
            // Strip leading #/_/* fence chars before re-running patterns.
            #"^[\s#*_>]+(?=\w)"#,
            // The above is run FIRST so subsequent patterns match the
            // un-fenced text. Add the fenced rewrite-announce
            // sentence too in case the iteration didn't converge.
            #"^[\s#*_>]*Here(\s+is|'s)\s+(the\s+)?(answer|rewrite|version|response)\s+in\s+(your|my|Posey'?s)\s+voice[:.\s*_]*\s*"#,
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
            #"^[\s]*(Sure(\s+thing)?|Of\s+course|Absolutely|Great\s+question|Certainly|Got\s+it|Alright|All\s+right)[!.,]+(\s+(buddy|friend|pal))?[!.,]*\s*"#,
            // 2026-05-04 qa_battery additions:
            // "here's a rewrite of the answer in Posey's voice:"
            #"^[\s]*here(\s+is|'s)\s+a\s+rewrite\s+of\s+the\s+answer\s+in\s+(your|my|Posey'?s)\s+voice\s*[:.\-]*\s*"#,
            // Markdown-fenced sycophant: "**Sure thing, buddy!**"
            #"^[\s]*\*+\s*(Sure(\s+thing)?|Of\s+course|Absolutely|Certainly)[!,.]?(\s+(buddy|friend|pal))?[!,.]*\s*\*+\s*"#,
            // "Let me tell ya, …" / "Let me tell you, …"
            #"^[\s]*Let\s+me\s+tell\s+(ya|you)[,.]?\s*"#,
            // "Well, buckle up, because we're going to …"
            #"^[\s]*Well[,]?\s+buckle\s+up[,.][^.!?]{0,80}[.!?]\s*"#,
            // "Ah, X. So you're curious about …, are you?"
            #"^[\s]*Ah[,]?\s+\w[^.!?]{0,40}[.!?]\s*So\s+you'?re\s+curious[^.!?]{0,80}[.!?]\s*"#,
            // "Here's a rewrite in the style of Posey:"
            #"^[\s]*here(\s+is|'s)\s+a\s+rewrite\s+in\s+the\s+style\s+of\s+Posey\s*[:.\-]*\s*"#,
            // "Hey there! So, here's the deal with X:"
            #"^[\s]*hey\s+there[!,.]+\s*"#,
            // "So, here's the deal:"
            #"^[\s]*so[,]?\s+here(\s+is|'s)\s+the\s+deal\s*[:.\-]*\s*"#,
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
        // Voice antipattern strip — Task 3 QA surfaced these
        // patterns leaking past the polish prompt's explicit
        // FAILED examples. AFM ignores the prompt rules ~50 % of
        // the time. We strip the worst offenders defensively here.

        // Sycophantic openers that survived BLOCK above.
        // Compound: "Oh, the X, huh? Let me break it down for you."
        let sycoPatterns = [
            #"^[\s]*(Oh|Ah|Well|Hmm)[!,]?\s+(the|that|let)\s+[^.!?]{0,80}[.!?]\s*Let\s+me\s+(break\s+it\s+down|dive\s+in)[^.!?]{0,40}[.!?]\s*"#,
            #"^[\s]*Let\s+me\s+(break\s+it\s+down|dive\s+in|explain)[^.!?]{0,40}[.!?]\s*"#,
            #"^[\s]*(So|Alright|Right)[,]?\s+here'?s\s+(the\s+)?(scoop|deal|lowdown|takeaway)\s*[:.\-]?\s*"#,
            #"^[\s]*Quick\s+takeaway:\s*"#,  // mostly fine but inconsistent
            #"^[\s]*(So|Yeah|Yo|Look|Listen),?\s+(here'?s|we\s+gotta|let\s+me)[^.!?]{0,40}[.!?]\s*"#,
            // Bare sycophant openers: "Oh, the X, huh?" / "Ah, X, huh?"
            // — these stand alone without a "Let me break it down"
            // follow-up. Surfaced 2026-05-04 qa_battery round 4.
            #"^[\s]*(Oh|Ah)[!,]?\s+(the|that|those|these)\s+[^.!?]{0,120}\bhuh\??[!.,]*\s*"#,
        ]
        for pattern in sycoPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Mid-sentence metaphor strip — Task 3 QA showed AFM
        // ignores the polish prompt's "no metaphors" rule
        // ~50 % of the time. Detect sentences containing "It's
        // like X" / "X is like Y" / "It's a Y" decorative
        // similes and drop those sentences. Preserves substance
        // sentences before/after the metaphor.
        let metaphorTriggers = [
            // Catch "It's like X" / "It is like X" with any continuation —
            // this is the dominant pattern (Q4 hat: every other answer
            // included one). The polish prompt explicitly forbids
            // "X is like Y."
            #"\bit'?s\s+like\s+\w+"#,
            #"\bit\s+is\s+like\s+\w+"#,
            // "X is like Y" / "X are like Y"
            #"\b\w+\s+(is|are|was|were)\s+like\s+(a|an|having|the|trying|asking|reaching)\b"#,
            // "they are the ultimate puppeteers"
            #"\bare\s+the\s+ultimate\s+\w+s?\b"#,
            // Fixed-phrase clichés
            #"\bit'?s\s+a\s+(wild\s+ride|fascinating|mind[-\s]bender|classic\s+clash)\b"#,
            // Common analogy openers
            #"\blike\s+(having|using|owning)\s+a\s+(swiss\s+army\s+knife|magic\s+wand|silver\s+bullet)\b"#,
            // "throws shade" / "shaking things up" / "pulling the strings"
            #"\bthrows?\s+(some\s+)?(serious\s+)?shade\b"#,
            #"\bshaking\s+things?\s+up\b"#,
            #"\bpulling\s+the\s+strings\b"#,
            // 2026-05-04 qa_battery additions:
            #"\bgives?\s+you\s+the\s+lowdown\b"#,
            #"\bdives?\s+right\s+in\b"#,
            #"\bbuckle\s+up\b"#,
            #"\bSo,?\s+there\s+you\s+have\s+it\b"#,
            #"\bthe\s+ones\s+where\s+someone\s+\w+\s+a\s+\w+\b"#,
            // "And let's not forget about …" — meta narration
            #"\bAnd\s+let'?s\s+not\s+forget\s+about\b"#,
            // "But that's not all\." — infomercial filler
            #"\bbut\s+that'?s\s+not\s+all\b"#,
            // 2026-05-04 round 3:
            #"\bcooked\s+up\b"#,                            // "this paper was cooked up"
            #"\bya\s+know\?"#,                              // "..., ya know?"
            #"\bwild\s+world\s+of\b"#,                      // "wild world of copyright"
            #"\bkind\s+of\s+like\s+a\b"#,                    // "ADR is kind of like a last resort"
            #"\bIn\s+the\s+end[,.]?\s+it'?s\s+usually\b"#,  // "In the end, it's usually safer"
            #"\bso[,]?\s+if\s+you'?re\s+dealing\s+with\b"#, // "So, if you're dealing with"
            #"\bSo[,]?\s+yeah[,.]?\s+it'?s\s+(there|here|in\s+there)\b"#, // "So, yeah, it's there"
        ]
        var sentenceArray = splitIntoSentences(result)
        var keptSentences: [String] = []
        for sent in sentenceArray {
            let lower = sent.lowercased()
            var hasMetaphor = false
            for pat in metaphorTriggers {
                if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
                   regex.firstMatch(in: sent, range: NSRange(sent.startIndex..., in: sent)) != nil {
                    hasMetaphor = true
                    break
                }
                _ = lower
            }
            if !hasMetaphor {
                keptSentences.append(sent)
            }
        }
        if !keptSentences.isEmpty && keptSentences.count != sentenceArray.count {
            // Lost at least one sentence to metaphor strip; rebuild.
            result = keptSentences.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        sentenceArray.removeAll()  // free

        // Recommendation strip — polish HARD RULE 4 forbids these.
        // If the answer makes a personal recommendation, replace the
        // whole answer with the FAILED-→-SUCCEEDED form from the
        // prompt's own example.
        let recommendationPatterns = [
            #"(?i)\b(absolutely|definitely)\s+worth\s+reading\b"#,
            #"(?i)\bmust[-\s]read\b"#,
            #"(?i)\bI'?d\s+(highly|definitely|strongly)\s+recommend\b"#,
            #"(?i)\bhighly\s+recommend(ed)?\b"#,
            // Round 5 (qa Task 3 v2): "you should dive into this book"
            // / "fantastic introduction" / "great companion for your X
            // journey". HARD RULE 4 violations the polish prompt
            // doesn't reliably suppress.
            #"(?i)\byou\s+should\s+(dive|jump)\s+into\b"#,
            #"(?i)\bfantastic\s+introduction\b"#,
            #"(?i)\bgreat\s+companion\s+for\s+your\b"#,
            #"(?i)\bgreat\s+for\s+anyone\s+(curious|interested|new)\b"#,
            #"(?i)\bperfect\s+for\s+(beginners|those|anyone)\b"#,
            #"(?i)\bdefinitely\s+a\s+good\s+read\b"#,
            #"(?i)\bworth\s+(your\s+)?(time|reading)\b"#,
        ]
        for pattern in recommendationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) != nil {
                result = "The document doesn't make a recommendation. It does cover the topics laid out above if those interest you."
                break
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

    /// 2026-05-06 — Collapse repeated comma-separated items in
    /// AFM responses. Catches the count-mismatch hallucination
    /// where AFM is asked for "the four things" but the document
    /// only has three, and pads to four by repeating an item.
    /// Splits comma-separated phrases inside each sentence,
    /// removes duplicates while preserving first-occurrence order,
    /// then re-joins. Conservative: only fires when the same
    /// substring appears verbatim two or more times in a single
    /// sentence's comma-separated list, and the duplicates are
    /// at least 3 words long (so legitimate repetitions like
    /// "yes, yes" or "no, no" don't get collapsed).
    /// 2026-05-06 — Catch numbered-list duplicate items. AFM
    /// sometimes pads a numbered/bulleted list to satisfy a count
    /// in the user's question by repeating an earlier item with
    /// minor rewording. This pass walks list lines (lines beginning
    /// with `N.` / `N)` / `- ` / `* ` / `•`) and drops any whose
    /// content is a near-duplicate of an earlier list item.
    /// Conservative: only fires inside a contiguous list section,
    /// requires items >= 3 words, and uses normalized-text equality
    /// (lowercased, punctuation stripped) so legitimate
    /// near-duplicates that differ in substance survive.
    static func dedupeNumberedListItems(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        // Identify list lines.
        let listPattern = #"^\s*(\d+[.)]|[-*•])\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: listPattern) else { return text }
        func normalize(_ s: String) -> String {
            let lowered = s.lowercased()
            // Strip leading numbering and trailing punctuation.
            var t = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip trailing period/comma.
            while let last = t.last, ".,;:!?".contains(last) {
                t.removeLast()
            }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var output: [String] = []
        var seen: Set<String> = []
        for line in lines {
            let nsLine = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
               match.numberOfRanges >= 3 {
                let body = nsLine.substring(with: match.range(at: 2))
                let key = normalize(body)
                let wordCount = key.split(whereSeparator: { $0.isWhitespace }).count
                if wordCount >= 3 {
                    if seen.contains(key) {
                        // Drop duplicate list line entirely.
                        continue
                    }
                    seen.insert(key)
                }
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Blank line — reset seen set so duplicates across
                // separate lists don't false-positive.
                seen.removeAll()
            } else {
                // Prose line outside a list — also reset.
                seen.removeAll()
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    static func dedupeRepeatedListItems(_ text: String) -> String {
        var result: [String] = []
        // Split into sentences on .!? followed by space or end.
        // Keep the terminator with the sentence.
        let sentencePattern = #"[^.!?]*[.!?]+\s*|[^.!?]+$"#
        guard let regex = try? NSRegularExpression(pattern: sentencePattern) else {
            return text
        }
        let nsText = text as NSString
        var pos = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match else { return }
            let sentence = nsText.substring(with: match.range)
            result.append(dedupeListInSentence(sentence))
            pos = match.range.location + match.range.length
        }
        if pos < nsText.length {
            result.append(nsText.substring(from: pos))
        }
        return result.joined()
    }

    private static func dedupeListInSentence(_ sentence: String) -> String {
        // Only act if the sentence contains a comma-separated list
        // with at least three commas (so we have ≥ 4 list items —
        // otherwise repetition can't manifest the way it does).
        let commaCount = sentence.filter { $0 == "," }.count
        guard commaCount >= 2 else { return sentence }
        // Split on commas, trim, dedupe by first occurrence.
        // Skip the very last segment (it usually contains the
        // " and X" tail or trailing punctuation; dedupe should
        // still apply if the tail equals an earlier item, so we
        // process tail too).
        let parts = sentence.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // Strip a leading " and " on the final part for comparison.
        func normalize(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip terminal punctuation for comparison.
            while let last = t.last, ".!?".contains(last) {
                t.removeLast()
            }
            // Strip leading "and " (whitespace-tolerant).
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("and ") {
                t = String(trimmed.dropFirst(4))
            }
            return t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var seen = Set<String>()
        var keptOriginal: [String] = []
        for part in parts {
            let key = normalize(part)
            // Only dedupe when the normalized key is at least 3 words
            // — preserves "yes, yes" / "no, no" rhetorical doubling.
            let wordCount = key.split(whereSeparator: { $0.isWhitespace }).count
            if wordCount >= 3 {
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            keptOriginal.append(part)
        }
        if keptOriginal.count == parts.count {
            return sentence  // no dupes found, return original
        }
        return keptOriginal.joined(separator: ",")
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

    /// 2026-05-29 — authoritative bibliographic facts from the structured
    /// `metadata_*` columns. Returns nil when nothing is known. Only the
    /// fields that are present are listed. The "(authoritative …)" framing
    /// tells the model to trust these over anything in the retrieved
    /// excerpts (which may include an editorial preface that discusses
    /// OTHER authors/dates).
    static func renderDocumentMetadataBlock(title: String?,
                                            authors: [String]?,
                                            year: String?) -> String? {
        var lines: [String] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            lines.append("Title: \(title)")
        }
        let cleanAuthors = (authors ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanAuthors.isEmpty {
            lines.append("Author(s): \(cleanAuthors.joined(separator: ", "))")
        }
        if let year = year?.trimmingCharacters(in: .whitespacesAndNewlines), !year.isEmpty {
            lines.append("Publication/copyright year: \(year)")
        }
        guard !lines.isEmpty else { return nil }
        return """
        DOCUMENT METADATA (authoritative facts about THIS document — use these to answer questions about the work's title, author, or publication year; trust them over anything in the excerpts below, which may quote an editor's preface discussing other authors or dates):
        \(lines.joined(separator: "\n"))
        """
    }

    static func renderStructuredKnowledgeBlock(_ summary: String?) -> String? {
        guard let s = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return """
        CHAPTER SUMMARY (a high-level, source-verified orientation for the part of THIS document the question is about — use it to understand what the relevant passage discusses and to connect the reader's plain question to the text. It is a summary, not the source: the EXCERPTS below are the actual words of the document and are authoritative for exact wording, quotations, and specific detail. If the summary and an excerpt disagree, trust the excerpt.):
        \(s)
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

    /// 2026-06-20 — recalled older turns (the hybrid conversation-recall pass).
    /// Verbatim, first-person ("You:" / "Me:"), oldest-first, already deduped
    /// against the verbatim STM window. Framed as REFERENCE — these resurfaced
    /// because they relate to the current question; they are not the live turn.
    /// Walks oldest→newest and stops at the budget (the most relevant turns are
    /// chosen upstream by RRF; here we just fit what we can in reading order).
    static func renderRecalledTurnsBlock(turns: [DatabaseManager.RecalledTurn], budgetTokens: Int) -> String {
        guard !turns.isEmpty, budgetTokens > 0 else { return "" }
        var lines: [String] = []
        var used = 0
        for t in turns {
            let line = (t.role == "user" ? "You: " : "Me: ") + compactForNarrative(t.content)
            let cost = AskPoseyTokenEstimator.tokens(in: line) + 4
            if used + cost > budgetTokens { break }
            lines.append(line)
            used += cost
        }
        guard !lines.isEmpty else { return "" }
        return """
        RELEVANT EARLIER IN THIS CONVERSATION (this came up before and relates to what you're being asked now — reference, not the current question; "You" is you, "Me" is me):
        \(lines.joined(separator: "\n"))
        """
    }

    static func renderUserBlock(text: String, hint: String? = nil) -> String {
        // Plain-prose framing for the current user question. The
        // model parses "USER QUESTION:" as a labeled field rather
        // than as scaffolding to imitate.
        let body: String
        if let hint, !hint.isEmpty {
            body = "\(text)\n\n\(hint)"
        } else {
            body = text
        }
        return """
        USER QUESTION (this is the only thing you need to answer; respond to this directly, do not echo any structure or labels from the prompt above):
        \(body)
        """
    }

    /// 2026-05-04 — Detect short, grammatical-meta passage questions
    /// that AFM treats as document-meta and refuses ("What does 'This'
    /// refer to?", "What is this?", "What does this mean?"). Returns
    /// true when the question is short AND contains a grammatical-meta
    /// trigger AND no other substantive content words. The interpretation
    /// hint is added in those cases so AFM resolves the question
    /// against the anchor + surrounding context rather than refusing.
    static func questionLooksGrammaticalMeta(_ question: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count <= 80 else { return false } // long questions usually carry their own substance
        // Trigger phrases that match the failing patterns from the
        // 2026-05-04 conversational sweep.
        let triggers = [
            "what does this mean",
            "what does that mean",
            "what does it mean",
            "what does this refer",
            "what does that refer",
            "what does it refer",
            "what is this",
            "what is that",
            "what is it",
            "what's this mean",
            "what's that mean",
            "what's it mean",
            "what's this referring",
            "what's that referring",
            "what does 'this'",
            "what does 'that'",
            "what does 'it'",
            "explain this",
            "explain that",
            "explain it",
            "what's this about",
            "what's that about",
            "huh"
        ]
        for t in triggers {
            if q.contains(t) { return true }
        }
        return false
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

        // 2026-06-20 — FIRST-PERSON VERBATIM (Mark). The prior rendering showed
        // ONLY the user's questions, narrated in third person ("the user asked
        // X"), and deliberately HID Posey's own replies. That was an **AFM
        // concession**: the weak AFM base model imitated role-labeled turns as a
        // script to continue, so we stripped them. But hiding Posey's own words
        // cripples its sense of self (it can't see what IT said two turns ago),
        // and it's wrong for the capable MLX chat models whose NATIVE format is
        // exactly role-labeled turns. Now: verbatim recent turns, BOTH roles, in
        // first/second person — "You:" is the user, "Me:" is Posey's own earlier
        // words. Posey is a distinct entity from the user and both deserve to be
        // addressed as themselves. (AFM concessions are removable as of 2026-06-20;
        // revisit AFM ~a month post-release for the iOS 27 update.)
        let lines = kept.map { m in
            (m.role == .user ? "You: " : "Me: ") + compactForNarrative(m.content)
        }.joined(separator: "\n")
        return """
        EARLIER IN THIS CONVERSATION (our exchange so far — "You" is you, "Me" is me; answer the current question below, building on this rather than repeating it):
        \(lines)
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
