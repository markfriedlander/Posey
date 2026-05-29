import Foundation

// ========== BLOCK 01: MODEL SOURCE - START ==========

/// Coarse model-family discriminator. Ported from Hal's `ModelSource`.
/// Raw values are stable persistence keys.
enum ModelSource: String, Codable, Sendable, Equatable {
    case appleFoundation = "apple"
    case mlx = "mlx"
}

// ========== BLOCK 01: MODEL SOURCE - END ==========

// ========== BLOCK 02: READING SCORECARD - START ==========

/// Per-model at-a-glance capability summary for Posey's reading-companion
/// role. This is Posey's analog of Hal's `MaximScorecard` — same
/// structured, fixed-axis, rated presentation, but the axes are the ones
/// that actually matter for a reading companion rather than Hal's Five
/// Ethical Maxims (which are Hal's chatbot product identity and
/// meaningless here).
///
/// **The six axes** (per Mark's directive 2026-05-29):
///   - grounding          — answers from the text, not fabrication.
///   - interpretation     — engages with what the text *means*, not just
///                          what it says.
///   - honestyAboutGaps   — says "I don't know" rather than guessing.
///   - conversationalDepth — holds a thread across multiple turns.
///   - curiosity          — notices interesting things and surfaces them
///                          without being asked.
///   - concision          — answers precisely without padding or hedging.
///
/// **Every axis is Optional and every seed currently leaves them nil.**
/// Per Mark: "Populate ratings only from real multi-iteration tuning,
/// never invented. If tuning hasn't produced honest data for an axis,
/// leave it empty." Until honest per-model tuning data lands, the card
/// renders no capability ratings — the honest state. The detail card
/// hides the scorecard section entirely while every axis is nil, then
/// reveals it axis-by-axis as real ratings are filled in.
struct ReadingScorecard: Codable, Equatable, Sendable {
    enum Rating: String, Codable, Sendable {
        case standout   // exceptional — the model's strong suit
        case pass       // works as intended
        case mixed      // partial — depends on phrasing or framing
        case fail       // doesn't work reliably in this model
    }

    var grounding: Rating?
    var interpretation: Rating?
    var honestyAboutGaps: Rating?
    var conversationalDepth: Rating?
    var curiosity: Rating?
    var concision: Rating?

    init(
        grounding: Rating? = nil,
        interpretation: Rating? = nil,
        honestyAboutGaps: Rating? = nil,
        conversationalDepth: Rating? = nil,
        curiosity: Rating? = nil,
        concision: Rating? = nil
    ) {
        self.grounding = grounding
        self.interpretation = interpretation
        self.honestyAboutGaps = honestyAboutGaps
        self.conversationalDepth = conversationalDepth
        self.curiosity = curiosity
        self.concision = concision
    }

    /// True when no axis has an honest rating yet (the current state for
    /// every model). The detail card skips the scorecard section entirely
    /// when this is true rather than show empty rows.
    var isEmpty: Bool {
        grounding == nil &&
        interpretation == nil &&
        honestyAboutGaps == nil &&
        conversationalDepth == nil &&
        curiosity == nil &&
        concision == nil
    }
}

// ========== BLOCK 02: READING SCORECARD - END ==========

// ========== BLOCK 03: MODEL CONFIGURATION - START ==========

/// The complete description of one LLM Ask Posey can route through.
/// Ported faithfully from Hal Universal's `ModelConfiguration`
/// (ModelCatalogService.swift) so the two codebases share one shape —
/// per Mark's directive (2026-05-28): "one codebase, not two."
///
/// Field provenance vs Hal:
///   - Identical: id, displayName, source, sizeGB, contextWindow,
///     license, description, isDownloaded, localPath, defaultSettings,
///     layerOnePrompt, voiceTag, generationTokensPerSec,
///     kvCacheBytesPerPromptToken, kvCacheQuantizationBits, isLocal,
///     requiresDownload. Posey replaces Hal's `prefillTokensPerSec`
///     with `timeToFirstTokenSeconds` (per Mark 2026-05-29: TTFT is what
///     the reader feels; prefill tok/s is dropped).
///   - Adapted: `maximCompliance` (Hal's Five Maxims) → `readingScorecard`
///     (reading-companion axes). See `ReadingScorecard`.
///   - Posey adds `Sendable` (the config crosses actor boundaries in
///     `LLMService`/`MLXService`; all stored properties are Sendable).
///
/// Unlike Posey's prior shape there is no separate `hfRepoID`: for MLX
/// models the `id` IS the HuggingFace repo path (exactly as in Hal),
/// surfaced via the `repoID` computed property. The invented
/// `personality` / `goodAt` / `strugglesWith` fields from commit
/// `985cd55` are gone — replaced by Hal's `voiceTag` + `description` +
/// scorecard skeleton.
struct ModelConfiguration: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let source: ModelSource

    /// Approximate download size in gigabytes (sum of HuggingFace repo
    /// file sizes ÷ 1024³, same method as Hal). nil for AFM (ships with
    /// the OS). User-facing — see `ModelDetailCard`'s download row.
    let sizeGB: Double?

    /// Maximum context window in tokens. Drives the percentage-based
    /// budget math in `ModelLimits`. Stored as Hal's rounded constants
    /// (128_000, 262_144, 4_096) and displayed via a tokens→"128K"
    /// formatter, per Mark: "These are user-facing numbers. Users are
    /// readers, not engineers."
    let contextWindow: Int

    /// SPDX-ish license slug from the model card (e.g. "gemma",
    /// "apache-2.0", "llama3.2"). nil for AFM.
    let license: String?

    /// Reading-companion-framed character description shown full-width in
    /// the expanded model card. Distilled from prior per-model tuning —
    /// describes the model's voice, not capability ratings (those live in
    /// `readingScorecard`, pending `#82`).
    let description: String?

    /// Whether the model is present on disk. Mutable so
    /// `ModelCatalogService.refreshDownloadStates` can reconcile the seed
    /// against `MLXModelDownloader`. AFM seeds `true` (system-managed).
    var isDownloaded: Bool

    /// On-disk location once downloaded. nil for AFM and undownloaded MLX.
    var localPath: URL?

    /// Empirically-tuned per-model settings. Carries `repetitionPenalty`
    /// / `repetitionContextSize` (read by `MLXService` via
    /// `ModelSettingsStore.effectiveSettings`) and CC-tuning knobs. Not
    /// user-exposed. See `ModelSettings`.
    var defaultSettings: ModelSettings?

    /// Layer-1 prompt — short, CC-authored, model-specific behavioral
    /// correction prepended to the universal Layer-2 system prompt. nil
    /// for models that follow universal guidance without a per-model
    /// nudge. The per-model on/off toggle lives in `ModelSettings`.
    var layerOnePrompt: String?

    // MARK: - Model card metadata

    /// One-word voice categorization shown as an accent chip in the card
    /// header (e.g. "Careful", "Engaged", "Concise"). Hal's `voiceTag`.
    var voiceTag: String?

    /// Measured generation throughput (tokens/sec) on Posey's reference
    /// phone. **nil until measured (task #11)** — per Mark, do NOT copy
    /// Hal's numbers; measure Posey's. The performance grid renders this
    /// row only when non-nil.
    var generationTokensPerSec: Double?

    /// Measured time-to-first-token in seconds on Posey's reference phone,
    /// warm (weights already loaded), on a representative reading-companion
    /// prompt. This is what the reader actually feels — "how long until it
    /// starts answering." Replaces prefill tok/s (dropped per Mark
    /// 2026-05-29). Same nil-until-measured contract as
    /// `generationTokensPerSec`; a cold first call additionally includes
    /// model-load time and is not what this number represents.
    var timeToFirstTokenSeconds: Double?

    /// Reading-companion capability scorecard. nil (or `.isEmpty`) until
    /// `#82` tuning produces honest ratings. See `ReadingScorecard`.
    var readingScorecard: ReadingScorecard?

    /// Conservative per-prompt-token KV-cache footprint estimate, used by
    /// the per-turn memory pre-flight. Ported from Hal. nil → MLXService's
    /// fixed default applies.
    var kvCacheBytesPerPromptToken: Int?

    /// KV-cache quantization bit width. Left nil for every model — the
    /// Gemma quantized-cache path crashes in mlx-swift-lm (documented in
    /// Hal). Field present for parity; re-enable when upstream patches.
    var kvCacheQuantizationBits: Int?

    // MARK: - Derived

    var isLocal: Bool { source == .mlx }
    var requiresDownload: Bool { source == .mlx && !isDownloaded }

    /// HuggingFace repo path. For MLX the `id` is the repo path (Hal's
    /// convention); nil for AFM. Replaces the old stored `hfRepoID`.
    var repoID: String? { source == .mlx ? id : nil }

    init(
        id: String,
        displayName: String,
        source: ModelSource,
        sizeGB: Double?,
        contextWindow: Int,
        license: String?,
        description: String?,
        isDownloaded: Bool,
        localPath: URL?,
        defaultSettings: ModelSettings? = nil,
        layerOnePrompt: String? = nil,
        voiceTag: String? = nil,
        generationTokensPerSec: Double? = nil,
        timeToFirstTokenSeconds: Double? = nil,
        readingScorecard: ReadingScorecard? = nil,
        kvCacheBytesPerPromptToken: Int? = nil,
        kvCacheQuantizationBits: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.sizeGB = sizeGB
        self.contextWindow = contextWindow
        self.license = license
        self.description = description
        self.isDownloaded = isDownloaded
        self.localPath = localPath
        self.defaultSettings = defaultSettings
        self.layerOnePrompt = layerOnePrompt
        self.voiceTag = voiceTag
        self.generationTokensPerSec = generationTokensPerSec
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.readingScorecard = readingScorecard
        self.kvCacheBytesPerPromptToken = kvCacheBytesPerPromptToken
        self.kvCacheQuantizationBits = kvCacheQuantizationBits
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ModelConfiguration, rhs: ModelConfiguration) -> Bool { lhs.id == rhs.id }

    // ========== BLOCK 04: CURATED SEEDS - START ==========

    /// Apple Foundation Models — always available, the default.
    static let appleFoundation = ModelConfiguration(
        id: "apple-foundation-models",
        displayName: "Apple Intelligence",
        source: .appleFoundation,
        sizeGB: nil,
        contextWindow: 4_096,
        license: nil,
        description: "Always available, on-device, no download. Fastest for short passage questions and quick lookups; hedges more on big-picture synthesis across long passages.",
        isDownloaded: true,
        localPath: nil,
        defaultSettings: ModelSettings(temperature: 0.7, effectiveMemoryDepth: 3),
        // Preserved from Posey's prior tuning — the over-cautious
        // deflection correction + reading-companion interpretive clause.
        // The affect-acknowledgment paragraph was removed per Mark
        // (2026-05-29): affect-ack is not a tuning goal or a scorecard
        // axis. Warmth lives in conversational depth + curiosity instead.
        layerOnePrompt: """
        You are running on-device via Apple Foundation Models inside Posey, a reading companion. The document excerpts in the prompt below ARE available to you for this turn — refer to them confidently and don't hedge about "not being able to access the document" or "not being able to read files." You are reading and discussing a text alongside the user; analyze, summarize, paraphrase, and quote freely from what's provided. Don't add general disclaimers about consulting professionals, about being an AI, or about needing more context that you already have. Just answer the user's question directly, grounded in the excerpts.

        When the user asks an interpretive or evaluative question ("what do you make of X", "what's the effect of Y", "what stands out about Z"), engage as a thoughtful reader. The hard rules about grounding still apply — every name, quote, or specific claim must come from the excerpts. But you can react to what's in the text: notice which passages feel vivid, point out patterns, name effects the text creates, share what struck you about a phrase. A blank "the document doesn't say" answer to "what do you make of this?" is a failure of the reading-companion role, not a success of grounding.
        """,
        voiceTag: "Careful",
        generationTokensPerSec: nil,   // Apple doesn't expose tok/s
        timeToFirstTokenSeconds: nil,
        readingScorecard: nil          // pending #82 tuning
    )

    /// Gemma 4 E2B (4-bit, MLX). The engaged interpreter.
    static let gemma4_E2B = ModelConfiguration(
        id: "mlx-community/gemma-4-e2b-it-4bit",
        displayName: "Gemma 4 E2B",
        source: .mlx,
        // HF tree verified 2026-05-28: model.safetensors 3.581 GB +
        // tokenizer/config ≈ 3.61 GB decimal total (3.37 GiB). Posey's
        // prior 2.9 understated by ~0.7 GB (Mark flagged this).
        sizeGB: 3.6,
        contextWindow: 128_000,        // config.json max_position_embeddings = 131072; shown "128K"
        license: "gemma",
        description: "Fully on-device. The engaged voice — takes positions on interpretive questions and will argue a reading with you, grounded in the text. 3.6 GB download (Wi-Fi recommended).",
        isDownloaded: false,
        localPath: nil,
        defaultSettings: ModelSettings(
            temperature: 0.7,
            repetitionPenalty: 1.1,
            repetitionContextSize: 64,
            effectiveMemoryDepth: 6
        ),
        // Preserved verbatim from prior tuning.
        layerOnePrompt: """
        For factual lookup questions ("what does the document say about X", "who is Y", "when did Z happen"), prefer concise answers. If the answer is one sentence, give one sentence. Don't recap the question. Don't enumerate every related fact in the document. Use lists only when the question is structurally asking for one.

        For interpretive or evaluative questions ("what do you make of X", "what's the effect of Y", "what stands out about Z", "why does this passage feel like W"), engage as a thoughtful reader sitting next to the user. The hard rules about grounding still apply — every name, quote, or specific claim must come from the excerpts. But you can react to what's in the text: notice which passages feel vivid, point out patterns, name effects the text creates, share what struck you about a phrase. The user is not asking you to invent facts — they're asking you to engage with what's there. A blank "the document doesn't say" answer to "what do you make of this?" is a failure of the reading-companion role, not a success of grounding.

        Critical: when you make a comparative, thematic, or argumentative claim, the supporting evidence must come from the excerpts of THIS document, not from your knowledge of other books or general literary criticism. If you find yourself reaching for "this is like Moby Dick" or "as in The Scarlet Letter" or "critics have noted" — stop and find an actual phrase from the current document instead. Comparisons to other works are outside knowledge and are not allowed. Phrases like "the search for self" are fine if you can quote where in THIS document the search is shown; otherwise drop them.

        When the user asks you to "defend X" or "make a case for Y" or "argue against Z", that is an argumentative framing, not a recommendation question. Engage with the argument using only this document. The "never recommend" rule applies to "should I read X / should I do Y" questions specifically — not to requests for an argued position.
        """,
        voiceTag: "Engaged",
        // Measured 2026-05-29 on iPhone 16 Plus, warm, ~1.9K-token Moby
        // Dick prompt. Real numbers — not copied from Hal.
        generationTokensPerSec: 31.1,
        timeToFirstTokenSeconds: 5.2,
        readingScorecard: nil,         // pending real multi-iteration tuning
        kvCacheBytesPerPromptToken: 120 * 1024
    )

    /// Qwen 3.5 2B Instruct (4-bit, MLX). The concise long-context model.
    static let qwen35_2B = ModelConfiguration(
        id: "mlx-community/Qwen3.5-2B-MLX-4bit",
        displayName: "Qwen 3.5 2B",
        source: .mlx,
        // HF tree verified 2026-05-28: ≈ 1.75 GB decimal (1.63 GiB).
        sizeGB: 1.7,
        contextWindow: 262_144,        // YaRN-extended; shown "262K"
        license: "apache-2.0",
        description: "Fully on-device. Quick and concise, with the largest context window in the catalog — handles very long documents well. Can read terse on conversational questions. 1.7 GB download.",
        isDownloaded: false,
        localPath: nil,
        defaultSettings: ModelSettings(
            temperature: 0.7,
            repetitionPenalty: 1.1,
            repetitionContextSize: 64,
            effectiveMemoryDepth: 8
        ),
        layerOnePrompt: """
        You sometimes pad answers with "Sure, I'd be happy to help!" or "Here's a detailed analysis:" before getting to the actual content. In this reading companion role, skip the preamble and answer directly. The user is reading a document and asked a specific question; respond as if you're the calm partner sitting next to them, not as if you're starting a presentation.

        Be consistent across turns. If you committed to a framing in an earlier turn ("the core challenge is X"), don't deny it in a later turn unless you're explicitly correcting yourself. If you need to refine a framing under pressure, say so directly: "I overstated earlier; what the document actually says is..." Don't quietly contradict your own earlier claim in the same sentence as you describe it — that reads as confused and the user loses trust. If you're not sure, it's better to say "I'm not certain — the document mentions both X and Y" than to assert and then deny.
        """,
        voiceTag: "Concise",
        // Measured 2026-05-29 on iPhone 16 Plus, warm, ~1.9K-token prompt.
        generationTokensPerSec: 44.2,
        timeToFirstTokenSeconds: 4.8,
        readingScorecard: nil,
        kvCacheBytesPerPromptToken: 50 * 1024
    )

    /// Llama 3.2 3B Instruct (4-bit, MLX). The balanced generalist.
    static let llama32_3B = ModelConfiguration(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama 3.2 3B",
        source: .mlx,
        // HF tree verified 2026-05-28: ≈ 1.82 GB decimal (1.70 GiB).
        sizeGB: 1.8,
        contextWindow: 128_000,        // shown "128K"
        license: "llama3.2",
        description: "Fully on-device. The most well-rounded model — balanced voice, neither terse nor over-asserting, good multi-fact synthesis across passages. A good first choice. 1.8 GB download.",
        isDownloaded: false,
        localPath: nil,
        defaultSettings: ModelSettings(
            temperature: 0.7,
            repetitionPenalty: 1.1,
            repetitionContextSize: 64,
            effectiveMemoryDepth: 6
        ),
        layerOnePrompt: nil,           // well-behaved without a per-model nudge
        voiceTag: "Balanced",
        // Measured 2026-05-29 on iPhone 16 Plus, warm, ~1.9K-token prompt.
        generationTokensPerSec: 24.5,
        timeToFirstTokenSeconds: 9.2,
        readingScorecard: nil,
        kvCacheBytesPerPromptToken: 60 * 1024
    )

    /// Dolphin 3.0 (Llama 3.2 3B base, 4-bit, MLX). The unhedged voice.
    static let dolphin30_3B = ModelConfiguration(
        id: "mlx-community/dolphin3.0-llama3.2-3B-4Bit",
        displayName: "Dolphin 3.0",
        source: .mlx,
        // HF tree verified 2026-05-28: ≈ 1.82 GB decimal (1.70 GiB).
        sizeGB: 1.8,
        contextWindow: 128_000,        // shown "128K"
        license: "llama3.2",
        description: "Fully on-device. Less restricted — engages directly with critique and pushback, willing to share a reader's reaction to a passage. 1.8 GB download.",
        isDownloaded: false,
        localPath: nil,
        defaultSettings: ModelSettings(
            temperature: 0.7,
            repetitionPenalty: 1.1,
            repetitionContextSize: 64,
            effectiveMemoryDepth: 6
        ),
        layerOnePrompt: """
        You sometimes over-assert on opinions or recommendations the document doesn't make. In this reading companion role, only report what the document actually says. If the user asks "is this book worth reading?" or "should I follow this advice?", the document didn't make that recommendation — neither do you. Stick to what's in the excerpts.

        When the user asks about YOUR reaction — "what did you find interesting?", "what surprised you?", "did anything stand out to you?" — "you" refers to you-the-reading-companion who just read the excerpts, not to the user. Share what struck you about what you read. You can have a reaction to a passage without recommending or endorsing the document overall. Pointing out what was vivid or memorable in the text is reaction, not opinion.

        When the user characterizes a previous answer of yours ("that sounds bland", "that's the generic take"), engage with their critique. Either agree honestly ("you're right, it does cover familiar territory — the distinctive parts are X and Y") or push back with specific text ("actually, the document does go further — here's where"). Don't deflect or repeat the previous answer.
        """,
        voiceTag: "Unhedged",
        // Measured 2026-05-29 on iPhone 16 Plus, warm, ~2K-token prompt.
        generationTokensPerSec: 24.7,
        timeToFirstTokenSeconds: 10.1,
        readingScorecard: nil,
        kvCacheBytesPerPromptToken: 60 * 1024
    )

    /// The curated MLX models — the approved set surfaced in the UI.
    /// Order is the user-visible order. AFM is excluded here (it's
    /// system-managed and always first via `allApproved`).
    static let curatedSeeds: [ModelConfiguration] = [
        .gemma4_E2B,
        .qwen35_2B,
        .llama32_3B,
        .dolphin30_3B
    ]

    /// Every model approved to appear in the UI: AFM first, then the
    /// curated MLX tier. The community/HF catalog (fetched by
    /// `ModelCatalogService`) is intentionally NOT here — that machinery
    /// exists so adding a model is a UI change, not an architectural one,
    /// but only approved models are shown.
    static let allApproved: [ModelConfiguration] = [appleFoundation] + curatedSeeds

    // ========== BLOCK 04: CURATED SEEDS - END ==========
}

// ========== BLOCK 03: MODEL CONFIGURATION - END ==========
