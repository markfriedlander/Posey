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
        guard model.source == .mlx, let repoID = model.repoID else {
            dbgLog("MLX: rejecting %@ — wrong source or missing repoID", model.id)
            throw LLMService.LLMError.modelUnavailable(modelID: model.id)
        }
        dbgLog("MLX: streamChat begin model=%@ repoID=%@", model.id, repoID)
        let container = try await loadContainerIfNeeded(modelID: model.id, repoID: repoID)
        dbgLog("MLX: container ready for %@", model.id)

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
        dbgLog("MLX: preparing input messages=%d", chatMessages.count)
        let lmInput: LMInput
        do {
            lmInput = try await container.prepare(input: userInput)
        } catch {
            dbgLog("MLX: prepare threw: %@", "\(error)")
            throw error
        }
        let promptTokenCount = lmInput.text.tokens.size
        dbgLog("MLX: prepared promptTokens=%d", promptTokenCount)

        // Per-turn pre-flight.
        let kvNeeded = Int64(promptTokenCount) * Int64(kvBytesPerTokenDefault)
        let scratchBytes: Int64 = 200 * 1024 * 1024
        let safetyBytes: Int64 = 200 * 1024 * 1024
        let neededBytes = kvNeeded + scratchBytes + safetyBytes
        let availableBytes = Int64(os_proc_available_memory())
        dbgLog("MLX: preflight kv+scratch+safety=%dMB available=%dMB",
               Int(neededBytes / (1024*1024)),
               Int(availableBytes / (1024*1024)))
        if availableBytes > 0 && availableBytes < neededBytes {
            let neededMB = Int(neededBytes / (1024 * 1024))
            let availableMB = Int(availableBytes / (1024 * 1024))
            dbgLog("MLX: REJECTING preflight need=%dMB avail=%dMB", neededMB, availableMB)
            throw LLMService.LLMError.insufficientMemoryForTurn(
                modelID: model.id,
                promptTokens: promptTokenCount,
                neededMB: neededMB,
                availableMB: availableMB
            )
        }

        // F13 (2026-05-27): pass per-model repetition penalty +
        // context to `GenerateParameters`. The penalty alone is not
        // enough — Hal documented that well-behaved MLX models still
        // occasionally drift into a degenerate repetition loop deep
        // into a long generation. The in-stream `MLXRepetitionGuard`
        // brake below catches the residual case.
        //
        // 2026-05-28 — the per-model penalty + context now live in
        // `ModelSettings.defaultSettings` (Hal's per-model settings
        // infrastructure), read here via `ModelSettingsStore`. This is
        // the CC-tuned, not-user-exposed surface; the effective value is
        // catalog default overlaid with any tuning override.
        let tunedSettings = ModelSettingsStore.shared.effectiveSettings(for: model)
        let parameters = GenerateParameters(
            maxTokens: 4096,
            temperature: Float(options.temperature),
            repetitionPenalty: tunedSettings.repetitionPenalty,
            repetitionContextSize: tunedSettings.repetitionContextSize ?? 64  // matches Hal's pairing
        )

        dbgLog("MLX: generate begin promptTokens=%d", promptTokenCount)
        do {
            let stream = try await container.generate(input: lmInput, parameters: parameters)
            var fullText = ""
            var iterator = stream.makeAsyncIterator()
            var chunkCount = 0

            // F13 — in-stream repetition brake. Check every ~50 chars
            // of generated output; on detection, break the loop, trim
            // the residue + append an in-Posey-voice closing phrase,
            // and yield the cleaned snapshot one last time so the UI
            // settles on the trimmed text. See MLXRepetitionGuard.
            var lastRepetitionCheck = 0
            let repetitionCheckEvery = 50
            var stoppedForRepetition = false

            streamLoop: while let event = await iterator.next() {
                switch event {
                case .chunk(let text):
                    fullText += text
                    chunkCount += 1
                    continuation.yield(fullText)

                    if fullText.count - lastRepetitionCheck >= repetitionCheckEvery {
                        lastRepetitionCheck = fullText.count
                        if MLXRepetitionGuard.detect(in: fullText) {
                            dbgLog("MLX: repetition brake fired at %d chars", fullText.count)
                            stoppedForRepetition = true
                            break streamLoop
                        }
                    }
                case .info(let info):
                    // Measured throughput for catalog calibration (task #11).
                    // Greppable via LOGS:<n>:0 — `MLX-PERF: <model> gen=… ttft=…`.
                    // Real numbers measured on Posey's reference phone; never
                    // copied from Hal. `promptTime` is the prefill duration =
                    // time-to-first-token (the reader-felt latency), warm.
                    dbgLog("MLX-PERF: %@ gen=%.1f tok/s ttft=%.2f s promptTokens=%d",
                           model.id,
                           info.tokensPerSecond,
                           info.promptTime,
                           info.promptTokenCount)
                default:
                    continue
                }
            }

            if stoppedForRepetition {
                let cleaned = MLXRepetitionGuard.trim(fullText)
                dbgLog("MLX: post-trim length %d (was %d)", cleaned.count, fullText.count)
                fullText = cleaned
                continuation.yield(fullText)
            }

            dbgLog("MLX: generate finished chunks=%d totalLen=%d brake=%@",
                   chunkCount, fullText.count, stoppedForRepetition ? "true" : "false")
            continuation.finish()
        } catch {
            dbgLog("MLX: generate threw: %@", "\(error)")
            throw error
        }
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

        // Catalog lookup for sizeGB (used by swap headroom poll below AND
        // the existing pre-flight further down).
        let sizeGBForLoad = ModelCatalog.model(id: modelID)?.sizeGB

        // 2026-05-27 — MLX→MLX swap unload (Hal pattern, Hal.swift:5588-5640).
        // Previously this actor kept every loaded ModelContainer in the
        // `containers` dict and never evicted; multiple loaded MLX models
        // accumulated in memory until iOS jetsam-killed the app. Now: when
        // loading a NEW modelID and any OTHER MLX model is already loaded,
        // unload all of them first with the GPU-sync barrier + cache clear
        // + memory-headroom poll Hal calibrated against this exact failure.
        let otherLoadedIDs = containers.keys.filter { $0 != modelID }
        if !otherLoadedIDs.isEmpty {
            dbgLog("MLX-MEM: swap detected — unloading %d previous MLX container(s) before loading %@", otherLoadedIDs.count, modelID)
            for previousID in otherLoadedIDs {
                if let previousContainer = containers[previousID] {
                    // GPU sync barrier — wait for all in-flight Metal command
                    // buffers from the previous model's generation to complete
                    // before tearing down its state. Without this, the previous
                    // model's pending buffers fire against backing memory ARC has
                    // just freed → mlx::core::gpu::check_error throws → SIGABRT.
                    // Hal hit this on May-12. Same fix here.
                    dbgLog("MLX-MEM: draining GPU before unloading %@", previousID)
                    MLX.Stream.gpu.synchronize()
                    _ = previousContainer
                    containers.removeValue(forKey: previousID)
                    loadProgressByID[previousID] = nil
                }
            }
            // Free the GPU cache so iOS can reclaim the pages.
            Memory.clearCache()
            // Poll iOS available memory until we have headroom for the new
            // model (up to 3s). Mach VM reclamation is lazy — without the
            // poll, the next load starts before iOS has actually dropped
            // the freed pages, and the new load peaks against an
            // unrecovered memory ceiling.
            let requiredMB = requiredMemoryMBForLoad(sizeGB: sizeGBForLoad)
            let headroom = await waitForMemoryHeadroom(
                requiredMB: requiredMB,
                timeoutSeconds: 3.0
            )
            if headroom.success {
                dbgLog("MLX-MEM: headroom reached after %d polls / %.2fs (availableMB=%.0f requiredMB=%.0f)",
                       headroom.pollsTaken, headroom.elapsedSeconds, headroom.finalAvailableMB, requiredMB)
            } else {
                dbgLog("MLX-MEM: headroom NOT reached within 3s (availableMB=%.0f requiredMB=%.0f) — proceeding; load pre-flight will refuse if still insufficient",
                       headroom.finalAvailableMB, requiredMB)
            }
        }

        // Step 1 — ensure the model files are on disk via the public
        // HF tree+resolve endpoints. The pre-port path called
        // `LLMModelFactory.loadContainer(configuration: .init(id: repoID))`
        // which routes through `#hubDownloader()` against an authenticated
        // HF endpoint and fails with 401 for Qwen/Dolphin/Gemma. The
        // post-port path pre-downloads via `MLXModelDownloader` (Hal's
        // BackgroundDownloadCoordinator pattern, public endpoints, no
        // auth) and then loads from disk via `.directory` init.
        let sizeGB = sizeGBForLoad
        if !MLXModelDownloader.shared.isModelDownloaded(modelID) {
            dbgLog("MLX: model %@ not on disk; triggering pre-download", modelID)
            await MLXModelDownloader.shared.startDownload(modelID: modelID, repoID: repoID, sizeGB: sizeGB)

            // Wait for completion. BackgroundDownloadCoordinator posts
            // .mlxModelDidDownload with userInfo["modelID"] on success.
            // On failure, MLXModelDownloader sets downloadStates[modelID].error
            // — we poll that alongside the notification so a permanent failure
            // (e.g. 401/404 from HF, no network) surfaces promptly instead of
            // hanging the /ask request indefinitely.
            var didSucceed = false
            let pollDeadline = Date().addingTimeInterval(60 * 30) // 30-minute outer cap
            while Date() < pollDeadline {
                if MLXModelDownloader.shared.isModelDownloaded(modelID) {
                    didSucceed = true
                    break
                }
                if let state = await MainActor.run(body: { MLXModelDownloader.shared.downloadStates[modelID] }),
                   let err = state.error {
                    dbgLog("MLX: pre-download failed for %@: %@", modelID, err)
                    loadProgressByID[modelID] = 0.0
                    throw LLMService.LLMError.generationFailed(
                        underlying: NSError(domain: "MLXService", code: 100, userInfo: [
                            NSLocalizedDescriptionKey: err
                        ])
                    )
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard didSucceed else {
                dbgLog("MLX: pre-download timed out (30 min) for %@", modelID)
                loadProgressByID[modelID] = 0.0
                throw LLMService.LLMError.generationFailed(
                    underlying: NSError(domain: "MLXService", code: 101, userInfo: [
                        NSLocalizedDescriptionKey: "Model download timed out after 30 minutes."
                    ])
                )
            }
            dbgLog("MLX: pre-download complete for %@", modelID)
        }

        guard let localPath = MLXModelDownloader.shared.localPath(for: modelID) else {
            dbgLog("MLX: pre-download finished but localPath nil for %@; aborting", modelID)
            loadProgressByID[modelID] = 0.0
            throw LLMService.LLMError.generationFailed(
                underlying: LLMService.LLMError.modelUnavailable(modelID: modelID)
            )
        }

        // Step 2 — build the directory-anchored ModelConfiguration with
        // per-model extraEOSTokens so chat-template turn markers stop
        // generation at the natural turn boundary. Without these, Gemma /
        // Phi / Qwen produce runaway output past the assistant turn.
        // Llama and Dolphin (Llama-3.2 base) are well-behaved without
        // extraEOSTokens — they fall through to the empty branch.
        let idLower = modelID.lowercased()
        let extraEOSTokens: Set<String>
        if idLower.contains("gemma") {
            extraEOSTokens = ["<end_of_turn>"]
        } else if idLower.contains("phi") {
            extraEOSTokens = ["<|end|>"]
        } else if idLower.contains("qwen") {
            extraEOSTokens = ["<turn|>"]
        } else {
            extraEOSTokens = []
        }
        dbgLog("MLX: extraEOSTokens for %@: count=%d", modelID, extraEOSTokens.count)

        // Pre-flight memory refusal (faithful Hal pattern from
        // Hal.swift:4871-4900 + ProcessMemoryGuard.swift). Refuse the load
        // if iOS-reported available memory is below the model's estimated
        // requirement. Without this, a load that exceeds the dirty-memory
        // limit triggers jetsam and the process dies mid-load. Surfacing
        // a user-visible error is strictly better than a silent process
        // kill — the chat thread survives, the user sees what happened.
        let availableMBPreflight = processAvailableMemoryMB()
        let requiredMBPreflight = requiredMemoryMBForLoad(sizeGB: sizeGB)
        dbgLog("MLX-MEM: loadModel pre-flight model=%@ availableMB=%.0f requiredMB=%.0f",
               modelID, availableMBPreflight, requiredMBPreflight)
        if availableMBPreflight < requiredMBPreflight {
            let displayName = ModelCatalog.model(id: modelID)?.displayName ?? modelID
            let msg = memoryRefusalMessage(
                modelDisplayName: displayName,
                availableMB: availableMBPreflight,
                requiredMB: requiredMBPreflight
            )
            dbgLog("MLX-MEM: loadModel REFUSED — have %.0fMB, need %.0fMB",
                   availableMBPreflight, requiredMBPreflight)
            loadProgressByID[modelID] = 0.0
            throw LLMService.LLMError.generationFailed(
                underlying: NSError(domain: "MLXService", code: 102, userInfo: [
                    NSLocalizedDescriptionKey: msg
                ])
            )
        }

        // Match LLMEval's MLX cache config (Hal does the same at
        // Hal.swift:4903). 20 MB is the documented iOS example value.
        Memory.cacheLimit = 20 * 1024 * 1024

        let mlxConfig = MLXLMCommon.ModelConfiguration(
            directory: localPath,
            extraEOSTokens: extraEOSTokens
        )

        do {
            // hubDownloader is provided but unused — the configuration
            // carries a .directory URL (already local).
            let container = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: mlxConfig
            )
            containers[modelID] = container
            loadProgressByID[modelID] = 1.0
            dbgLog("MLX: loadContainer success for %@", modelID)
            return container
        } catch {
            dbgLog("MLX: loadContainer threw for %@: %@", modelID, "\(error)")
            loadProgressByID[modelID] = 0.0
            throw LLMService.LLMError.generationFailed(underlying: error)
        }
    }

    private func recordProgress(modelID: String, fraction: Double) {
        loadProgressByID[modelID] = fraction
    }
}

// ========== BLOCK 01: MLX SERVICE - END ==========
