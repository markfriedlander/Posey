import Foundation
import FoundationModels

// ========== BLOCK 01: LLM SERVICE FACADE - START ==========

/// Single dispatch point over the active LLM backend. Today
/// routes only `.appleFoundation` (live via `LanguageModelSession`);
/// Step 8g adds the `.mlx` adapter so Gemma / Qwen / Llama /
/// Dolphin route through the same surface without UI churn.
///
/// **Why a facade in 8d when only one backend is live?** Two
/// reasons. First, having `AskPoseyService` call `LLMService.shared`
/// once is far less work in 8g than refactoring every AFM call
/// site to add an MLX branch. Second, the per-model metadata
/// (`ModelConfiguration`) needs a single owner that knows about
/// streaming, error mapping, and lifecycle — that owner is here.
///
/// **What this facade is NOT in 8d.** It is NOT a replacement for
/// `AskPoseyService`'s two-call grounded-then-polish architecture.
/// That logic is Posey-specific and should stay in
/// `AskPoseyService` until proven model-portable. The facade
/// today exposes a generic `streamChat` for callers that want the
/// single-pass shape (e.g. 8g's `QueryExpansion` LLM call), and
/// AFM-specific `LanguageModelSession` access continues working
/// alongside.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8d). The chat-style facade lands; the per-model
/// adapters fill in during 8g.
final class LLMService: @unchecked Sendable {

    static let shared = LLMService()
    private init() {}

    // MARK: - Errors

    enum LLMError: LocalizedError {
        case modelUnavailable(modelID: String)
        case insufficientMemoryForTurn(modelID: String, promptTokens: Int, neededMB: Int, availableMB: Int)
        case generationFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable(let id):
                return "Model '\(id)' is not available on this device."
            case .insufficientMemoryForTurn(let id, let prompt, let needed, let avail):
                return "Not enough memory for this turn on \(id): prompt \(prompt) tokens would need ~\(needed)MB; only \(avail)MB available. Try a shorter conversation or a smaller model."
            case .generationFailed(let err):
                return "LLM generation failed: \(err.localizedDescription)"
            }
        }
    }

    // MARK: - Public surface

    /// Stream a single-pass chat response. `messages` follows the
    /// standard `{role, content}` shape rendered into whatever the
    /// model's tokenizer expects (AFM gets Instructions + Prompt;
    /// MLX models get a tokenizer-rendered chat template). Snapshots
    /// are cumulative strings (each yield contains the full text so
    /// far) — same shape as Hal's `generateChatResponseStream`.
    ///
    /// Use for: any single-pass LLM call (query expansion,
    /// summarization, classification). Ask Posey's grounded /
    /// polish two-call orchestration continues to live in
    /// `AskPoseyService` until proven portable across MLX models.
    func streamChat(
        messages: [ChatMessage],
        model: ModelConfiguration = ModelCatalog.current(),
        options: LLMGenerationOptions = .init()
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch model.source {
                    case .appleFoundation:
                        try await streamAFM(
                            messages: messages,
                            options: options,
                            continuation: continuation
                        )
                    case .mlx:
                        try await MLXService.shared.streamChat(
                            messages: messages,
                            model: model,
                            options: options,
                            continuation: continuation
                        )
                        // MLXService.streamChat finishes the
                        // continuation itself on success; no
                        // additional finish() needed here.
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - AFM adapter

    /// Wraps `LanguageModelSession` into the facade's chat shape.
    /// First message of role `.system` becomes Instructions; the
    /// last `.user` message becomes the Prompt. Intermediate
    /// messages (history) get concatenated into the prompt as
    /// labeled turns. Mirrors `AskPoseyService`'s session
    /// construction so behavior parity is preserved.
    @MainActor
    private func streamAFM(
        messages: [ChatMessage],
        options: LLMGenerationOptions,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let systemText = messages.first(where: { $0.role == .system })?.content ?? ""
        let userMessages = messages.filter { $0.role != .system }

        // Render history into a single prompt body so AFM's one-
        // user-prompt API can carry it. Last user message is rendered
        // raw at the end; earlier turns are wrapped with role labels
        // so the model can tell who said what.
        var promptBody = ""
        for (i, msg) in userMessages.enumerated() {
            let isLast = (i == userMessages.count - 1)
            if isLast {
                promptBody += msg.content
            } else {
                let label = msg.role == .user ? "USER" : "ASSISTANT"
                promptBody += "\(label): \(msg.content)\n\n"
            }
        }

        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: systemText
        )
        let stream = session.streamResponse(
            options: FoundationModels.GenerationOptions(temperature: options.temperature)
        ) { Prompt(promptBody) }

        for try await snapshot in stream {
            continuation.yield(snapshot.content)
        }
        continuation.finish()
    }
}

// ========== BLOCK 01: LLM SERVICE FACADE - END ==========


// ========== BLOCK 02: SUPPORTING TYPES - START ==========

/// One message in the facade's chat shape. Same shape as Hal's
/// `HalChatMessage` so the patterns transfer.
struct ChatMessage: Sendable, Equatable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
    }
    let role: Role
    let content: String
}

/// Generation knobs. Mirrors AFM's `LLMGenerationOptions` plus the
/// fields MLX needs (8g extends). Today exposes only `temperature`
/// since that's the only knob `AskPoseyService` adjusts.
struct LLMGenerationOptions: Sendable {
    var temperature: Double

    init(temperature: Double = 0.0) {
        self.temperature = temperature
    }
}

// ========== BLOCK 02: SUPPORTING TYPES - END ==========
