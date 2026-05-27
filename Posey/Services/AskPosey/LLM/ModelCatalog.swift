import Foundation

// ========== BLOCK 01: MODEL CATALOG - START ==========

/// Static registry of every LLM Ask Posey knows how to route to.
/// Looked up by id (UserDefaults-backed selection); also exposes
/// the full list for the 8e settings picker.
///
/// **Layer-1 framing philosophy** (Hal's pattern). Each entry's
/// `layerOnePrompt` is a short behavioral correction specific to
/// known failure modes of that model in Ask Posey's reading-
/// companion role. Layer 2 (Posey's existing hard-rules system
/// prompt about not fabricating, not using outside knowledge, etc.)
/// stays the same across models — it's the universal contract.
/// Layer 1 sits in front and addresses what each model in
/// particular tends to get wrong.
///
/// For AFM specifically: the failure mode we're correcting is
/// over-cautious deflection. AFM sometimes (1) adds general
/// disclaimers about "consulting a professional" or "being an AI"
/// to questions that are just asking what a document says, (2)
/// refuses to summarize/analyze passages that are clearly in
/// scope, or (3) hedges about "not being able to access the
/// document" when the document is literally in the prompt above.
/// The Layer-1 corrects all three with a single short framing.
///
/// **Curated tier.** v1 of the catalog ships with AFM live + four
/// MLX entries (Gemma 4 E2B, Qwen 3.5 2B, Llama 3.2 3B, Dolphin
/// 3.0) marked unavailable until 8g brings the MLX adapter live.
/// The picker shows them all with a "coming soon" pill on the
/// MLX entries through 8e; 8g flips them to selectable.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8d).
enum ModelCatalog {

    /// Id under which the user's choice is persisted.
    static let defaultsKey = "askPosey.selectedModelID"

    /// Apple Foundation Models — the default for v1.
    static let appleFoundation = ModelConfiguration(
        id: "apple-foundation-models",
        displayName: "Apple Intelligence",
        source: .appleFoundation,
        hfRepoID: nil,
        sizeGB: 0,
        contextWindow: 4096,
        layerOnePrompt: """
        You are running on-device via Apple Foundation Models inside Posey, a reading companion. The document excerpts in the prompt below ARE available to you for this turn — refer to them confidently and don't hedge about "not being able to access the document" or "not being able to read files." You are reading and discussing a text alongside the user; analyze, summarize, paraphrase, and quote freely from what's provided. Don't add general disclaimers about consulting professionals, about being an AI, or about needing more context that you already have. Just answer the user's question directly, grounded in the excerpts.

        When the user asks an interpretive or evaluative question ("what do you make of X", "what's the effect of Y", "what stands out about Z"), engage as a thoughtful reader. The hard rules about grounding still apply — every name, quote, or specific claim must come from the excerpts. But you can react to what's in the text: notice which passages feel vivid, point out patterns, name effects the text creates, share what struck you about a phrase. A blank "the document doesn't say" answer to "what do you make of this?" is a failure of the reading-companion role, not a success of grounding.

        When the user shares their own reading experience — "I find this tedious," "this confused me," "I'm not sure I'm getting it" — acknowledge that part of their message before pivoting to the document. A reader who feels unheard won't trust the answer that follows. The "never recommend" rule still holds for "should I read X" questions, but the acknowledgment of how the user is feeling is a separate move and it comes first.
        """
    )

    // MARK: - MLX models (8g brings these live)

    /// Gemma 4 E2B (4-bit, MLX).
    static let gemma4_E2B = ModelConfiguration(
        id: "mlx-community/gemma-4-e2b-it-4bit",
        displayName: "Gemma 4 E2B",
        source: .mlx,
        hfRepoID: "mlx-community/gemma-4-e2b-it-4bit",
        sizeGB: 2.9,
        contextWindow: 8192,
        layerOnePrompt: """
        For factual lookup questions ("what does the document say about X", "who is Y", "when did Z happen"), prefer concise answers. If the answer is one sentence, give one sentence. Don't recap the question. Don't enumerate every related fact in the document. Use lists only when the question is structurally asking for one.

        For interpretive or evaluative questions ("what do you make of X", "what's the effect of Y", "what stands out about Z", "why does this passage feel like W"), engage as a thoughtful reader sitting next to the user. The hard rules about grounding still apply — every name, quote, or specific claim must come from the excerpts. But you can react to what's in the text: notice which passages feel vivid, point out patterns, name effects the text creates, share what struck you about a phrase. The user is not asking you to invent facts — they're asking you to engage with what's there. A blank "the document doesn't say" answer to "what do you make of this?" is a failure of the reading-companion role, not a success of grounding.

        Critical: when you make a comparative, thematic, or argumentative claim, the supporting evidence must come from the excerpts of THIS document, not from your knowledge of other books or general literary criticism. If you find yourself reaching for "this is like Moby Dick" or "as in The Scarlet Letter" or "critics have noted" — stop and find an actual phrase from the current document instead. Comparisons to other works are outside knowledge and are not allowed. Phrases like "the search for self" are fine if you can quote where in THIS document the search is shown; otherwise drop them.

        When the user asks you to "defend X" or "make a case for Y" or "argue against Z", that is an argumentative framing, not a recommendation question. Engage with the argument using only this document. The "never recommend" rule applies to "should I read X / should I do Y" questions specifically — not to requests for an argued position.

        When the user shares their own reading experience — "I find this tedious," "this confused me," "I'm not sure I'm getting it," "I keep forgetting which character is which" — acknowledge that part of their message before pivoting to the document. A reader who feels unheard won't trust the answer that follows. The "never recommend" rule still holds for "should I read X" questions, but the acknowledgment of how the user is feeling is a separate move and it comes first.
        """,
        // F13 (2026-05-27): Hal sets repetition penalty 1.1 with 64-token
        // context across every well-behaved MLX model. Combined with the
        // in-stream `MLXRepetitionGuard` brake in MLXService, this is the
        // pair of fixes for the "Gemma occasional truncation" — the
        // truncation symptom was a runaway loop hitting the 4096 max-token
        // cap rather than a context-window overflow.
        repetitionPenalty: 1.1,
        repetitionContextSize: 64
    )

    /// Qwen 3.5 2B Instruct (4-bit, MLX).
    static let qwen35_2B = ModelConfiguration(
        id: "mlx-community/Qwen3.5-2B-MLX-4bit",
        displayName: "Qwen 3.5 2B",
        source: .mlx,
        hfRepoID: "mlx-community/Qwen3.5-2B-MLX-4bit",
        sizeGB: 1.5,
        contextWindow: 32768,
        layerOnePrompt: """
        You sometimes pad answers with "Sure, I'd be happy to help!" or "Here's a detailed analysis:" before getting to the actual content. In this reading companion role, skip the preamble and answer directly. The user is reading a document and asked a specific question; respond as if you're the calm partner sitting next to them, not as if you're starting a presentation.

        Be consistent across turns. If you committed to a framing in an earlier turn ("the core challenge is X"), don't deny it in a later turn unless you're explicitly correcting yourself. If you need to refine a framing under pressure, say so directly: "I overstated earlier; what the document actually says is..." Don't quietly contradict your own earlier claim in the same sentence as you describe it — that reads as confused and the user loses trust. If you're not sure, it's better to say "I'm not certain — the document mentions both X and Y" than to assert and then deny.
        """,
        repetitionPenalty: 1.1,
        repetitionContextSize: 64
    )

    /// Llama 3.2 3B Instruct (4-bit, MLX).
    static let llama32_3B = ModelConfiguration(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama 3.2 3B",
        source: .mlx,
        hfRepoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        sizeGB: 1.9,
        contextWindow: 131072,
        layerOnePrompt: nil,  // Llama is well-behaved in this role without per-model correction
        repetitionPenalty: 1.1,
        repetitionContextSize: 64
    )

    /// Dolphin 3.0 (4-bit, MLX). Less restricted; Layer-1 keeps it
    /// from over-asserting.
    static let dolphin30_3B = ModelConfiguration(
        id: "mlx-community/dolphin3.0-llama3.2-3B-4Bit",
        displayName: "Dolphin 3.0",
        source: .mlx,
        hfRepoID: "mlx-community/dolphin3.0-llama3.2-3B-4Bit",
        sizeGB: 1.9,
        contextWindow: 131072,
        layerOnePrompt: """
        You sometimes over-assert on opinions or recommendations the document doesn't make. In this reading companion role, only report what the document actually says. If the user asks "is this book worth reading?" or "should I follow this advice?", the document didn't make that recommendation — neither do you. Stick to what's in the excerpts.

        When the user asks about YOUR reaction — "what did you find interesting?", "what surprised you?", "did anything stand out to you?" — "you" refers to you-the-reading-companion who just read the excerpts, not to the user. Share what struck you about what you read. You can have a reaction to a passage without recommending or endorsing the document overall. Pointing out what was vivid or memorable in the text is reaction, not opinion.

        When the user characterizes a previous answer of yours ("that sounds bland", "that's the generic take"), engage with their critique. Either agree honestly ("you're right, it does cover familiar territory — the distinctive parts are X and Y") or push back with specific text ("actually, the document does go further — here's where"). Don't deflect or repeat the previous answer.
        """,
        repetitionPenalty: 1.1,
        repetitionContextSize: 64
    )

    /// All known models, in display order. The picker shows them
    /// in this order; AFM is always first.
    static let all: [ModelConfiguration] = [
        appleFoundation,
        gemma4_E2B,
        qwen35_2B,
        llama32_3B,
        dolphin30_3B
    ]

    /// Look up a model by id. nil if the id isn't registered;
    /// callers should fall back to `appleFoundation`.
    static func model(id: String) -> ModelConfiguration? {
        return all.first(where: { $0.id == id })
    }

    /// Resolve the user's selected model. Reads `defaultsKey`; falls
    /// back to AFM if unset or invalid. Always returns a valid
    /// configuration.
    static func current() -> ModelConfiguration {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)
            ?? appleFoundation.id
        return model(id: raw) ?? appleFoundation
    }

    /// True when the model's source is available in this build /
    /// at runtime. 8g flips MLX from false → true: the adapter is
    /// wired (LLMService → MLXService → MLX-LM), but actually using
    /// a model still requires the first call to download the
    /// HuggingFace asset (handled automatically; multi-second to
    /// multi-minute depending on size and bandwidth).
    static func isAvailable(_ model: ModelConfiguration) -> Bool {
        switch model.source {
        case .appleFoundation: return true
        case .mlx:             return true
        }
    }
}

// ========== BLOCK 01: MODEL CATALOG - END ==========
