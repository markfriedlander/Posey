import Foundation

// ========== BLOCK 01: MODEL CATALOG (SELECTION NAMESPACE) - START ==========

/// Non-isolated selection + lookup namespace over the **approved** model
/// set. This is the routing surface every Ask Posey service reads from
/// (`current()`, `model(id:)`) — it is deliberately not `@MainActor` so
/// `LLMService`, `AskPoseyPromptBuilder`, and `AskPoseyService` can read
/// the active model from any isolation context without hopping actors.
///
/// The richer catalog surface — HuggingFace community fetch, three-tier
/// context-window detection, license acceptance, live download-state
/// reconciliation — lives in `ModelCatalogService` (`@MainActor`
/// `ObservableObject`), the UI-facing singleton. The two are
/// complementary, mirroring Hal, where selection lives on the chat view
/// model and the catalog machinery lives on `ModelCatalogService`.
///
/// **Approved-only.** `all` / `model(id:)` resolve against
/// `ModelConfiguration.allApproved` (AFM + curated). Community models
/// exist in `ModelCatalogService.availableModels` but are never
/// selectable here — only models Mark has approved route through Ask
/// Posey. Adding a model to the UI is a one-line change to
/// `ModelConfiguration.curatedSeeds`, not an architectural one.
///
/// 2026-05-28 — slimmed to a pure selection namespace as part of the
/// faithful Hal model-management port (task #1). The model seeds and the
/// `ModelConfiguration` shape moved to `ModelConfiguration.swift`.
enum ModelCatalog {

    /// UserDefaults key under which the user's model choice is persisted.
    static let defaultsKey = "askPosey.selectedModelID"

    // MARK: - Convenience aliases (forward to ModelConfiguration statics)

    static var appleFoundation: ModelConfiguration { .appleFoundation }
    static var gemma4_E2B: ModelConfiguration { .gemma4_E2B }
    static var qwen35_2B: ModelConfiguration { .qwen35_2B }
    static var llama32_3B: ModelConfiguration { .llama32_3B }
    static var dolphin30_3B: ModelConfiguration { .dolphin30_3B }

    /// Approved models, in display order (AFM first, then curated MLX).
    static var all: [ModelConfiguration] { ModelConfiguration.allApproved }

    // MARK: - Lookup + selection

    /// Look up an approved model by id. nil if the id isn't approved;
    /// callers fall back to `appleFoundation`.
    static func model(id: String) -> ModelConfiguration? {
        all.first(where: { $0.id == id })
    }

    /// Resolve the user's selected model. Reads `defaultsKey`; falls back
    /// to AFM if unset or not an approved id. Always returns a valid
    /// configuration.
    static func current() -> ModelConfiguration {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? appleFoundation.id
        return model(id: raw) ?? appleFoundation
    }

    /// The model that writes reader-facing Ask Posey **answers**. 2026-05-31:
    /// AFM is no longer an answer engine (it's hidden from the picker and used
    /// only for background `@Generable` tasks). This always resolves to a
    /// downloaded MLX model and never AFM — the user's selection when that's a
    /// downloaded MLX model, otherwise the first downloaded MLX model. The
    /// Ask Posey unlock gate guarantees ≥1 MLX model is present, so this
    /// resolves to a real model whenever Ask Posey is reachable. Answer
    /// generation and its token budget route through here; the AFM answer path
    /// in `AskPoseyService.streamProseResponse` becomes unreachable as a
    /// result (kept as inert, reversible code).
    static func answerModel() -> ModelConfiguration {
        let selected = current()
        if selected.source == .mlx, MLXModelDownloader.shared.isModelDownloaded(selected.id) {
            return selected
        }
        return all.first { $0.source == .mlx && MLXModelDownloader.shared.isModelDownloaded($0.id) }
            ?? selected
    }

    /// The model that runs background **`@Generable` tasks** — intent
    /// classification and query expansion (RAPTOR summaries + metadata call
    /// AFM directly). 2026-05-31: prefer AFM, whose guided generation forces
    /// reliable structured output MLX lacks. Falls back to the MLX answer
    /// model when AFM isn't available (a no-Apple-Intelligence device that
    /// unlocked with Nomic + MLX) — those tasks degrade to free-text rather
    /// than break.
    ///
    /// NOTE: conversation **summarization** deliberately does NOT use this —
    /// it routes through `answerModel()` (MLX) instead. It's free-text (not
    /// `@Generable`, so AFM gives it nothing) and it carries the user's full
    /// conversation, so keeping it on the on-device MLX model preserves the
    /// privacy guarantee a privacy-motivated MLX user chose (the #4 decision,
    /// `dadefb2`). AFM's only exposure here is the short intent query.
    ///
    /// Decoupled from `answerModel()` so the answer engine and the background
    /// engine are independent — the background engine is itself swappable the
    /// day we want a privacy-guaranteed alternative to AFM/`@Generable`.
    static func auxModel() -> ModelConfiguration {
        if AskPoseyAvailability.current.isAvailable { return appleFoundation }
        return answerModel()
    }

    /// True when the model is selectable in this build. Every approved
    /// model is available; MLX models download on first use (or via the
    /// explicit gated Download button in the picker).
    static func isAvailable(_ model: ModelConfiguration) -> Bool {
        switch model.source {
        case .appleFoundation: return true
        case .mlx:             return true
        }
    }
}

// ========== BLOCK 01: MODEL CATALOG (SELECTION NAMESPACE) - END ==========
