import Foundation

// ========== BLOCK 01: MODEL CONFIGURATION - START ==========

/// The complete description of one LLM Posey can route Ask Posey
/// through. One value type holds everything `LLMService` and the
/// prompt builder need to dispatch + frame + budget. Mirrors Hal
/// Universal's `ModelConfiguration` shape so the patterns transfer
/// cleanly when MLX-LM models come online in Step 8g.
///
/// Two model sources today:
///   - `.appleFoundation` — `LanguageModelSession` (the system AFM).
///     The only live source in 8d.
///   - `.mlx` — MLX-LM via `mlx-swift-examples` and per-model
///     tokenizers. Scaffolding only in 8d; live in 8g (Gemma,
///     Qwen, Llama, Dolphin).
///
/// Per-model `layerOnePrompt` is the short CC-authored behavioral
/// correction Hal calls "Layer 1." Layer 2 is the user-editable
/// system prompt (Posey's existing system prompt is the Layer 2
/// today; the user-editable surface arrives later). Layer 1 is
/// model-specific, hard-cap 400 tokens enforced at build time
/// (the catalog ships with values under the cap by construction;
/// changes get caught by the unit test added in 8e).
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8d).
struct ModelConfiguration: Sendable, Equatable, Identifiable {

    enum Source: String, Sendable, Equatable, Codable {
        case appleFoundation
        case mlx
    }

    /// Stable identifier used as the UserDefaults selection key
    /// and as the storage key on the conversation table. HuggingFace
    /// repo path for MLX models; `"apple-foundation-models"` for AFM.
    let id: String

    /// Display name shown in the model picker + chat bubble footer.
    let displayName: String

    /// Where this model runs.
    let source: Source

    /// HuggingFace repo path for MLX models. nil for AFM (no
    /// download path — system-provided).
    let hfRepoID: String?

    /// Approximate on-disk model size in gigabytes. Shown in the
    /// picker so users see what they're committing to. AFM ships
    /// with the OS so this is 0.
    let sizeGB: Double

    /// Maximum context window in tokens. Drives the percentage-
    /// based budget math in `ModelLimits` so a 4096-window AFM
    /// and a 131072-window Llama scale identically.
    let contextWindow: Int

    /// Layer-1 prompt — short, CC-authored, model-specific behavioral
    /// correction prepended to the universal Layer-2 system prompt.
    /// Nil for models that follow universal guidance without needing
    /// a per-model nudge. Hard cap 400 tokens (~1600 chars).
    let layerOnePrompt: String?

    /// Per-token logit repetition penalty passed to
    /// `GenerateParameters.repetitionPenalty`. Hal sets 1.1 across all
    /// well-behaved MLX models — strong enough to discourage runaway
    /// "the the the" loops, gentle enough not to distort natural
    /// language phrasing. Nil for AFM (different generation path) and
    /// for models documented to misbehave with a penalty applied
    /// (Hal's Phi-4 case; not relevant in Posey's catalog).
    ///
    /// Note on KV-cache quantization (NOT ported from Hal): Hal exposes
    /// a `kvCacheQuantizationBits` field but leaves it nil for every
    /// model. Setting it to 4 for Gemma 4 E2B (the only natural
    /// candidate) crashes — Gemma4Text.swift in mlx-swift-lm calls
    /// `MLXFast.scaledDotProductAttention` directly with raw tensors
    /// instead of routing through `attentionWithCacheUpdate`, so it
    /// can't consume the quantized cache. Confirmed empirically by Hal
    /// (see Hal Universal ModelCatalogService.swift:643-666). Field
    /// omitted here per CLAUDE.md's "no future-format abstractions"
    /// rule — re-add when mlx-swift-lm patches the Gemma path.
    let repetitionPenalty: Float?

    /// Context window the repetition penalty looks back over, passed to
    /// `GenerateParameters.repetitionContextSize`. Hal pairs every model
    /// that gets `repetitionPenalty: 1.1` with a 64-token context.
    let repetitionContextSize: Int?

    /// One short user-facing sentence describing the model's character
    /// and best-fit usage, shown in the model picker beneath the
    /// display name. Drawn from the per-model tuning experience and
    /// the Layer-1 prompts — distilled to a single line so the user
    /// can pick a model on character rather than on size + context-
    /// window numbers alone. Not user-editable; ships with the catalog.
    let personality: String

    init(
        id: String,
        displayName: String,
        source: Source,
        hfRepoID: String?,
        sizeGB: Double,
        contextWindow: Int,
        layerOnePrompt: String?,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int? = nil,
        personality: String
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.hfRepoID = hfRepoID
        self.sizeGB = sizeGB
        self.contextWindow = contextWindow
        self.layerOnePrompt = layerOnePrompt
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.personality = personality
    }
}

// ========== BLOCK 01: MODEL CONFIGURATION - END ==========
