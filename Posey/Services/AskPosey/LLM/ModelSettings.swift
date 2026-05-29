import Foundation

// ========== BLOCK 01: MODEL SETTINGS - START ==========

/// Per-model tunable settings profile. Ported faithfully from Hal
/// Universal's `ModelSettings` (ModelCatalogService.swift). Each
/// `ModelConfiguration` ships with empirically-tuned `defaultSettings`;
/// CC adjusts these during per-model tuning to optimize each model's
/// behavior in Ask Posey's reading-companion role.
///
/// **Not user-exposed.** Per Mark's directive (2026-05-28): "Port the
/// per-model settings infrastructure. Do not expose it to users. CC
/// sets these values during tuning to optimize each model's
/// performance. Users never see them." There is no settings slider in
/// Posey bound to these fields — the values live entirely in the
/// catalog defaults plus the optional override JSON managed by
/// `ModelSettingsStore`.
///
/// Every field is `Optional` because:
///   1. New fields added later decode from older persisted data as nil →
///      no migration friction.
///   2. Overrides store deltas: a `nil` field on an override means "use
///      the model's default for this setting"; a non-nil field means
///      "this value was changed for this model."
///
/// 2026-05-28 — introduced as part of the faithful Hal model-management
/// port (task #1).
struct ModelSettings: Codable, Equatable, Sendable {

    /// Sampling temperature passed to generation.
    var temperature: Double?

    /// Per-token logit repetition penalty passed to
    /// `GenerateParameters.repetitionPenalty`. Hal sets 1.1 across all
    /// well-behaved MLX models — strong enough to discourage runaway
    /// "the the the" loops, gentle enough not to distort natural
    /// language. Nil for AFM (different generation path) and for models
    /// documented to misbehave with a penalty applied (Hal's Phi-4 case).
    var repetitionPenalty: Float?

    /// Context window the repetition penalty looks back over, passed to
    /// `GenerateParameters.repetitionContextSize`. Hal pairs every model
    /// that gets `repetitionPenalty: 1.1` with a 64-token context.
    var repetitionContextSize: Int?

    /// Maximum characters of retrieved RAG context to inject. Posey's
    /// budget math (`AskPoseyTokenBudget` / `ModelLimits`) is the primary
    /// driver today; this is the per-model ceiling CC can tune when a
    /// model handles more/less retrieved context gracefully.
    var maxRagSnippetsCharacters: Int?

    /// How many recent verbatim conversation turns to keep in the prompt.
    /// Hal's `effectiveMemoryDepth`. Scaled per model off the context
    /// window — bigger windows hold a deeper thread (AFM 4K → 3 turns;
    /// 128K → 6; 256K → 8). This is the lever the larger windows buy:
    /// more conversation memory, NOT more RAG (RAG budget is unchanged).
    /// Read by the prompt builder; bounds the STM section in addition to
    /// the token budget. nil → a context-window-derived default applies.
    var effectiveMemoryDepth: Int?

    /// Whether the model's Layer 1 (per-model framing) is prepended to
    /// the universal Layer 2 system prompt. The Layer 1 TEXT lives on
    /// `ModelConfiguration.layerOnePrompt` (read-only); this is just the
    /// per-model toggle for whether to USE it. Defaults to true (nil ==
    /// true at the read site). Mirrors Hal's `layerOnePromptEnabled`.
    var layerOnePromptEnabled: Bool?

    init(
        temperature: Double? = nil,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int? = nil,
        maxRagSnippetsCharacters: Int? = nil,
        effectiveMemoryDepth: Int? = nil,
        layerOnePromptEnabled: Bool? = nil
    ) {
        self.temperature = temperature
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.maxRagSnippetsCharacters = maxRagSnippetsCharacters
        self.effectiveMemoryDepth = effectiveMemoryDepth
        self.layerOnePromptEnabled = layerOnePromptEnabled
    }

    /// Overlay non-nil fields of `overrides` on top of `self`.
    /// Non-destructive: any nil field in `overrides` keeps `self`'s
    /// value. This is the "defaults + tuning changes" merge used by
    /// `ModelSettingsStore.effectiveSettings`.
    func merged(with overrides: ModelSettings) -> ModelSettings {
        ModelSettings(
            temperature: overrides.temperature ?? self.temperature,
            repetitionPenalty: overrides.repetitionPenalty ?? self.repetitionPenalty,
            repetitionContextSize: overrides.repetitionContextSize ?? self.repetitionContextSize,
            maxRagSnippetsCharacters: overrides.maxRagSnippetsCharacters ?? self.maxRagSnippetsCharacters,
            effectiveMemoryDepth: overrides.effectiveMemoryDepth ?? self.effectiveMemoryDepth,
            layerOnePromptEnabled: overrides.layerOnePromptEnabled ?? self.layerOnePromptEnabled
        )
    }
}

// ========== BLOCK 01: MODEL SETTINGS - END ==========

// ========== BLOCK 02: MODEL SETTINGS STORE - START ==========

/// Persistence layer for per-model settings overrides. Ported from
/// Hal's `ModelSettingsStore`. Manages a `[modelID: ModelSettings]`
/// dictionary where each entry holds *only the deltas* from that
/// model's catalog defaults.
///
/// **Read path (the one Posey uses today):** `effectiveSettings(for:)`
/// returns the model's `defaultSettings` overlaid with any persisted
/// overrides. `MLXService` reads `repetitionPenalty` /
/// `repetitionContextSize` from this at generation time.
///
/// **Override write path (dormant until Posey adds tuning UI/verbs):**
/// `setOverride` / `resetOverrides` / `setLayerOnePromptEnabled` persist
/// CC-set tuning deltas. There is intentionally NO user-facing surface
/// bound to these — per Mark's directive the values are CC-tuned only.
/// Hal's @AppStorage snapshot/apply bridge (which synced live settings
/// sliders) is deliberately NOT ported: Posey has no such sliders, so
/// porting the bridge would be porting UI plumbing for UI that doesn't
/// exist. The infrastructure that matters — defaults + overrides +
/// effective merge — is here and complete.
///
/// 2026-05-28 — introduced as part of the faithful Hal model-management
/// port (task #1).
final class ModelSettingsStore: @unchecked Sendable {
    static let shared = ModelSettingsStore()

    private let userDefaultsKey = "askPosey.modelSettingsOverridesV1"
    private let lock = NSLock()

    private init() {}

    // MARK: - Persistence

    private func loadOverrides() -> [String: ModelSettings] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: ModelSettings].self, from: data)) ?? [:]
    }

    private func saveOverrides(_ dict: [String: ModelSettings]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    // MARK: - Public API

    /// Look up persisted overrides for a model. Returns an empty
    /// `ModelSettings` (all nil) if none exist.
    func overrides(for modelID: String) -> ModelSettings {
        lock.lock(); defer { lock.unlock() }
        return loadOverrides()[modelID] ?? ModelSettings()
    }

    /// Effective settings = catalog defaults overlaid with overrides.
    /// Anything missing from both ends up nil; callers handle nil by
    /// falling back to a generation-time default.
    func effectiveSettings(for model: ModelConfiguration) -> ModelSettings {
        let defaults = model.defaultSettings ?? ModelSettings()
        return defaults.merged(with: overrides(for: model.id))
    }

    /// Persist a full override record for a model (CC tuning path).
    func setOverride(_ settings: ModelSettings, for modelID: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = loadOverrides()
        dict[modelID] = settings
        saveOverrides(dict)
        dbgLog("MODEL-SETTINGS: set override for %@", modelID)
    }

    /// Clear all overrides for `modelID`, falling back to pure catalog
    /// defaults on next read.
    func resetOverrides(for modelID: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = loadOverrides()
        dict.removeValue(forKey: modelID)
        saveOverrides(dict)
        dbgLog("MODEL-SETTINGS: reset overrides for %@", modelID)
    }

    /// Set just the Layer-1 toggle for a model, preserving other
    /// override fields. Mirrors Hal's `setLayerOnePromptEnabled`.
    func setLayerOnePromptEnabled(_ enabled: Bool, for modelID: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = loadOverrides()
        var current = dict[modelID] ?? ModelSettings()
        current.layerOnePromptEnabled = enabled
        dict[modelID] = current
        saveOverrides(dict)
        dbgLog("MODEL-SETTINGS: layerOnePromptEnabled=%@ for %@", enabled ? "true" : "false", modelID)
    }

    /// Whether Layer-1 framing should be applied for this model.
    /// Defaults to true when unset. Read by the prompt builder.
    func isLayerOnePromptEnabled(for model: ModelConfiguration) -> Bool {
        effectiveSettings(for: model).layerOnePromptEnabled ?? true
    }
}

// ========== BLOCK 02: MODEL SETTINGS STORE - END ==========
