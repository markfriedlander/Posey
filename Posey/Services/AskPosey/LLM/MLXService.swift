import Foundation
@preconcurrency import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
@preconcurrency import MLXHuggingFace
@preconcurrency import HuggingFace
@preconcurrency import Tokenizers

// ========== BLOCK 01: MLX SERVICE - START ==========

/// MLX adapter for `LLMService`. Loads MLX-LM models from
/// HuggingFace via the `#hubDownloader()` macro, prepares chat-
/// template-formatted inputs via each model's tokenizer, and
/// streams generation back to the caller.
///
/// Implemented as an `actor` so shared state (container cache,
/// load-in-flight set, progress map) is mutated safely from
/// async contexts without the NSLock-in-async warnings Swift 6
/// promotes to errors.
///
/// **Per-model isolation.** One `ModelContainer` per model id,
/// cached on the actor. Switching models doesn't unload the
/// previous one (reload cost is multi-second on real hardware
/// and the user likely switches back). An LRU eviction pass can
/// come later if memory pressure proves a real issue.
///
/// **Per-turn memory pre-flight.** Hal's pattern: load-time check
/// covers model weights; KV cache grows with prompt size and
/// can cross iOS's dirty-memory cliff on a long-prompt turn even
/// after a successful load. Multiply prompt tokens × per-model
/// KV bytes-per-token, add scratch + safety margins, refuse the
/// turn cleanly with a friendly error if
/// `os_proc_available_memory()` says we can't afford it.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8g).
actor MLXService {

    static let shared = MLXService()

    private var containers: [String: ModelContainer] = [:]
    /// Last-load progress fraction per model id. Used by the
    /// picker UI to render in-flight downloads.
    private var loadProgressByID: [String: Double] = [:]
    /// True between load start and load completion, per model id.
    /// Prevents the same model from being loaded twice if a second
    /// turn fires before the first load returns.
    private var loadInFlight: Set<String> = []

    /// Conservative per-token KV cache estimate when the model
    /// config doesn't specify one (Hal calibrated these per model;
    /// we inherit Gemma E2B's 80 KB as a sensible upper bound for
    /// the unknown case).
    private let kvBytesPerTokenDefault = 80 * 1024

    // MARK: - Public surface

    /// Snapshot of load progress for `modelID` in `[0, 1]`. nil
    /// when no load has been attempted. Read by the picker UI.
    func progress(for modelID: String) -> Double? {
        return loadProgressByID[modelID]
    }

    /// True if the named model's container is loaded and ready.
    func isLoaded(modelID: String) -> Bool {
        return containers[modelID] != nil
    }

    /// Stream a chat response from the named model. Loads the
    /// container on first use (lazy, blocking the first call).
    /// Yields cumulative-text snapshots — each yield contains the
    /// full response so far.
    func streamChat(
        messages: [ChatMessage],
        model: ModelConfiguration,
        options: LLMGenerationOptions,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard model.source == .mlx, let repoID = model.hfRepoID else {
            throw LLMService.LLMError.modelUnavailable(modelID: model.id)
        }

        let container = try await loadContainerIfNeeded(modelID: model.id, repoID: repoID)

        let chatMessages: [Chat.Message] = messages.map { msg in
            switch msg.role {
            case .system:    return .system(msg.content)
            case .user:      return .user(msg.content)
            case .assistant: return .assistant(msg.content)
            }
        }

        MLX.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))

        let userInput = UserInput(
            chat: chatMessages,
            additionalContext: ["enable_thinking": false]
        )
        let lmInput = try await container.prepare(input: userInput)
        let promptTokenCount = lmInput.text.tokens.size

        // Per-turn pre-flight.
        let kvNeeded = Int64(promptTokenCount) * Int64(kvBytesPerTokenDefault)
        let scratchBytes: Int64 = 200 * 1024 * 1024
        let safetyBytes: Int64 = 200 * 1024 * 1024
        let neededBytes = kvNeeded + scratchBytes + safetyBytes
        let availableBytes = Int64(os_proc_available_memory())
        if availableBytes > 0 && availableBytes < neededBytes {
            let neededMB = Int(neededBytes / (1024 * 1024))
            let availableMB = Int(availableBytes / (1024 * 1024))
            throw LLMService.LLMError.insufficientMemoryForTurn(
                modelID: model.id,
                promptTokens: promptTokenCount,
                neededMB: neededMB,
                availableMB: availableMB
            )
        }

        let parameters = GenerateParameters(
            maxTokens: 4096,
            temperature: Float(options.temperature)
        )

        let stream = try await container.generate(input: lmInput, parameters: parameters)
        var fullText = ""
        var iterator = stream.makeAsyncIterator()
        while let event = await iterator.next() {
            switch event {
            case .chunk(let text):
                fullText += text
                continuation.yield(fullText)
            default:
                // MLX's Generation enum has additional cases
                // (`.info`, `.toolCall`, etc.) we don't act on
                // here. A default arm keeps us forward-compatible.
                continue
            }
        }
        continuation.finish()
    }

    // MARK: - Load coordination

    private func loadContainerIfNeeded(modelID: String, repoID: String) async throws -> ModelContainer {
        if let cached = containers[modelID] {
            return cached
        }
        // Another sibling call already loading? Wait. We yield by
        // suspending; the awaited task re-enters the actor when
        // resumed and gets the cached container.
        if loadInFlight.contains(modelID) {
            while true {
                try await Task.sleep(nanoseconds: 500_000_000)
                if let cached = containers[modelID] { return cached }
                if !loadInFlight.contains(modelID) {
                    throw LLMService.LLMError.generationFailed(
                        underlying: LLMService.LLMError.modelUnavailable(modelID: modelID)
                    )
                }
            }
        }
        loadInFlight.insert(modelID)
        loadProgressByID[modelID] = 0.0

        defer { loadInFlight.remove(modelID) }

        let mlxConfig = MLXLMCommon.ModelConfiguration(id: repoID)
        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: mlxConfig,
                progressHandler: { @Sendable [weak self] p in
                    guard let self = self else { return }
                    Task { await self.recordProgress(modelID: modelID, fraction: p.fractionCompleted) }
                }
            )
            containers[modelID] = container
            loadProgressByID[modelID] = 1.0
            return container
        } catch {
            loadProgressByID[modelID] = 0.0
            throw LLMService.LLMError.generationFailed(underlying: error)
        }
    }

    private func recordProgress(modelID: String, fraction: Double) {
        loadProgressByID[modelID] = fraction
    }
}

// ========== BLOCK 01: MLX SERVICE - END ==========
