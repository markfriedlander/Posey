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
        You sometimes generate dense, multi-paragraph answers when the user asked for a short one. In this reading companion role, prefer concise answers. If the question is "what does the document say about X" and the answer is one sentence, give one sentence. Don't recap the question. Don't enumerate every related fact in the document — answer what was asked. Use lists only when the question is structurally asking for one.
        """
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
        """
    )

    /// Llama 3.2 3B Instruct (4-bit, MLX).
    static let llama32_3B = ModelConfiguration(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama 3.2 3B",
        source: .mlx,
        hfRepoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        sizeGB: 1.9,
        contextWindow: 131072,
        layerOnePrompt: nil  // Llama is well-behaved in this role without per-model correction
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
        """
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
