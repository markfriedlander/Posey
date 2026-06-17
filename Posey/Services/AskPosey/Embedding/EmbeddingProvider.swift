import Foundation
import NaturalLanguage
import CoreML
@preconcurrency import Embeddings

// ========== BLOCK 01: EMBEDDING PROVIDER - START ==========

/// Single-instance wrapper around whichever embedding backend is
/// currently active. Lazy-loaded on first use; subsequent calls
/// are synchronous and fast.
///
/// Two switchable backends in v1 of the new architecture:
///   - **NLContextualEmbedding** (default, built-in, 512-dim).
///   - **Nomic Embed Text v1.5** via `swift-embeddings`
///     (768-dim, ~522 MB) — wired live in Step 8h. Until then
///     `embed(_:as:)` returns nil and the migration coordinator
///     refuses the switch.
///
/// Thread safety: locked around the one-time backend load;
/// subsequent `embed(_:)` calls are reentrant and rely on the
/// backend's own thread-safety (NLContextualEmbedding is
/// documented thread-safe after `load()`).
///
/// Sync API preserved across all backends via `DispatchSemaphore`
/// bridges when the underlying load is async — every caller sees
/// a `[Double]?` per call. This is how Hal's
/// `EmbeddingProvider` shape lets retrieval-time code stay
/// synchronous even when the storage path is async.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8a). Mirrors `Hal Universal/EmbeddingProvider.swift`
/// in shape; the implementation details for each backend are
/// independent.
final class EmbeddingProvider: @unchecked Sendable {

    /// Process-wide singleton. Lazy.
    nonisolated static let shared = EmbeddingProvider()

    // MARK: - Storage for backend state

    private let lock = NSLock()

    /// 2026-06-02 — CRASH FIX. Serializes Nomic on-device inference so
    /// only ONE `bundle.encode` (MLX → MetalPerformanceShadersGraph
    /// executable specialization) runs at a time, process-wide.
    ///
    /// **Why (device backtrace, three independent crashes 2026-06-01).**
    /// `EXC_BAD_ACCESS / SIGSEGV at 0x6` deep inside
    /// `MetalPerformanceShadersGraph` — `mlir::ANECLayoutAnalysis::run`
    /// on the `MPSGraphExecutable_queue`, with two-to-six threads
    /// simultaneously in `NomicBert.Model.callAsFunction` →
    /// `MPSGraphExecutable specializeWithDevice`. MPSGraph executable
    /// specialization is NOT safe to run concurrently. The concurrency
    /// arose from multiple embedding callers overlapping: two
    /// `UnitEmbeddingService.fillEmbeddings` passes after an
    /// overwrite-import, the `EmbedderMigrationCoordinator` re-embed
    /// loop, and RAG query embeds — all funnel through `embedNomic`,
    /// which previously ran `bundle.encode` on an UNLOCKED `Task.detached`.
    /// This intermittent (~1/8) crash was misattributed to "PDF Vision
    /// enhancement" because enhancement-complete fires the chunker →
    /// embedding fill, and a concurrent delete/overwrite kicked off a
    /// second indexing pass → two parallel Nomic inferences.
    ///
    /// **Category (Rule 10 / Step 3).** The class is "concurrent
    /// on-device GPU/ANE graph inference." ALL embedding sources route
    /// through this one method, so this gate closes the whole embedding
    /// half of the category. NLContextual already serializes on `lock`
    /// (held across its compute) and never touches MPSGraph, so it needs
    /// no gate. The other MPSGraph user is the MLX LLM (`MLXService`, an
    /// actor → self-serialized, and currently dormant — no model
    /// downloaded). Embedding-vs-LLM concurrency is a documented residual:
    /// when the LLM is activated (roadmap item 5/6), its generation must
    /// share a gate with this one. Filed in NEXT.md.
    private let nomicInferenceQueue = DispatchQueue(
        label: "com.posey.embedding.nomic-inference"
    )

    // NLContextualEmbedding (mBERT) — the default backend. Asset
    // is downloaded transparently by the system on first launch;
    // until ready, `embed()` returns nil and the retrieval
    // pipeline falls back to BM25-only.
    nonisolated(unsafe) private var nlContextualModel: NLContextualEmbedding?
    nonisolated(unsafe) private var nlContextualLoadAttempted: Bool = false

    // Nomic Embed Text v1.5 — wired live in Step 8h via the
    // swift-embeddings package. NomicBert.loadModelBundle does
    // the HuggingFace download + load in one call; subsequent
    // embeds are tokenize → forward → mean-pool → L2-normalize.
    nonisolated(unsafe) private var nomicBundle: NomicBert.ModelBundle?
    nonisolated(unsafe) private var nomicLoadAttempted: Bool = false

    private init() {}

    // MARK: - Public surface

    /// Pooled sentence vector for `text`, or nil if the active
    /// backend isn't loaded.
    ///
    /// `purpose` is honored by retrieval-asymmetric backends
    /// (Nomic adds `search_query:` / `search_document:`
    /// prefixes). NLContextual ignores it and produces the same
    /// vector either way.
    nonisolated func embed(_ text: String, as purpose: EmbeddingPurpose) -> [Double]? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // Route by PURPOSE so a swap never mismatches query- vs document-space:
        //  • .query    → the ACTIVE (read) backend, `current()`. A query vector
        //    is cosine-compared against the stored column the retriever reads
        //    (the active backend's), so it MUST be produced in that same space.
        //  • .document → the WRITE backend, `writeBackend()` (the swap target
        //    during a swap), so newly-stored vectors land in the column being
        //    built.
        // Outside a swap the two coincide. Without this split, a query issued
        // mid-swap would be embedded in the half-built target's space (e.g.
        // 512-dim NL) and compared against the active backend's vectors (e.g.
        // 768-dim Nomic) — a dimension mismatch that silently kills the semantic
        // pass. (Ask Posey is locked during swaps, so this is latent in the UI,
        // but the headless /ask path and correctness both demand the right space.)
        let backend: EmbeddingBackend
        switch purpose {
        case .query:    backend = EmbeddingBackend.current()
        case .document: backend = EmbeddingBackend.writeBackend()
        }

        switch backend {
        case .nlContextual:
            return embedNLContextual(cleaned)
        case .nomic:
            return embedNomic(cleaned, purpose: purpose)
        }
    }

    /// Convenience overload defaulting to `.document`. Storage
    /// paths (chunker, indexing) should use this; retrieval call
    /// sites must pass `.query` explicitly.
    nonisolated func embed(_ text: String) -> [Double]? {
        return embed(text, as: .document)
    }

    /// True if the backend that NEW embeddings are produced in (`writeBackend()`
    /// — the swap target during a swap, else the active backend) is loaded and
    /// ready. The coordinator's wait-for-load gate reads this, so during a swap
    /// it correctly reports the TARGET's load state.
    nonisolated var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        switch EmbeddingBackend.writeBackend() {
        case .nlContextual: return nlContextualModel != nil
        case .nomic:        return nomicBundle != nil
        }
    }

    /// The currently active backend (for diagnostics + UI).
    nonisolated var activeBackend: EmbeddingBackend {
        return EmbeddingBackend.current()
    }

    /// Trigger an async warm-up of the active backend, used from
    /// app launch so the model (and any downloaded assets) are
    /// ready before the first Ask Posey turn. Idempotent.
    nonisolated func warmUp() {
        Task.detached { [weak self] in
            guard let self = self else { return }
            // Warm the WRITE backend (swap target during a swap, else active) so
            // a resumed swap loads its target model at launch, and normal launch
            // warms the active backend as before.
            switch EmbeddingBackend.writeBackend() {
            case .nlContextual: self.ensureNLContextualLoadedBlocking()
            case .nomic:        self.ensureNomicLoadedBlocking()
            }
        }
    }

    // MARK: - NLContextualEmbedding path (default)

    private nonisolated func embedNLContextual(_ text: String) -> [Double]? {
        ensureNLContextualLoadedBlocking()

        lock.lock()
        let loaded = nlContextualModel
        lock.unlock()

        guard let model = loaded else { return nil }

        do {
            let result = try model.embeddingResult(for: text, language: .english)
            let dim = model.dimension
            guard dim > 0 else { return nil }

            var sum = [Double](repeating: 0, count: dim)
            var tokenCount = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                let limit = min(dim, vector.count)
                for i in 0..<limit { sum[i] += vector[i] }
                tokenCount += 1
                return true
            }
            guard tokenCount > 0 else { return nil }
            return sum.map { $0 / Double(tokenCount) }
        } catch {
            return nil
        }
    }

    private nonisolated func ensureNLContextualLoadedBlocking() {
        lock.lock()
        if nlContextualModel != nil { lock.unlock(); return }
        if nlContextualLoadAttempted { lock.unlock(); return }
        nlContextualLoadAttempted = true
        lock.unlock()

        guard let candidate = NLContextualEmbedding(language: .english) else {
            return
        }

        if !candidate.hasAvailableAssets {
            let sem = DispatchSemaphore(value: 0)
            var assetError: Error?
            candidate.requestAssets(completionHandler: { _, err in
                if let e = err { assetError = e }
                sem.signal()
            })
            sem.wait()
            if assetError != nil {
                // Allow a retry on the next call.
                lock.lock(); nlContextualLoadAttempted = false; lock.unlock()
                return
            }
        }

        do {
            try candidate.load()
            lock.lock()
            self.nlContextualModel = candidate
            lock.unlock()
        } catch {
            lock.lock(); nlContextualLoadAttempted = false; lock.unlock()
        }
    }

    // MARK: - Nomic Embed Text v1.5 path (live in Step 8h)

    /// Nomic-prefixed prompt per the model card. The prefix is
    /// load-bearing — without it retrieval quality drops sharply.
    /// Kept here today so the asymmetric-purpose plumbing is
    /// exercised even before the live model is wired; the result
    /// is the same nil until 8h ships.
    private nonisolated func nomicPrefixed(_ text: String, purpose: EmbeddingPurpose) -> String {
        switch purpose {
        case .document: return "search_document: " + text
        case .query:    return "search_query: " + text
        }
    }

    private nonisolated func embedNomic(_ text: String, purpose: EmbeddingPurpose) -> [Double]? {
        ensureNomicLoadedBlocking()

        lock.lock()
        let loaded = nomicBundle
        lock.unlock()

        guard let bundle = loaded else { return nil }

        let prefixed = nomicPrefixed(text, purpose: purpose)

        // Bridge async MLTensor inference into the sync embed
        // surface via a semaphore. Same pattern Hal uses; bundle.
        // encode is throws and the shapedArray fetch is async.
        //
        // 2026-06-02 CRASH FIX — run the whole inference bridge on the
        // dedicated serial `nomicInferenceQueue` so concurrent embed
        // callers can never drive MPSGraph specialization in parallel
        // (the crash). The queue thread blocks on `sem.wait()` while the
        // one in-flight detached encode runs; the next caller waits its
        // turn. See `nomicInferenceQueue`'s declaration for the backtrace.
        return nomicInferenceQueue.sync {
        let sem = DispatchSemaphore(value: 0)
        var resultVec: [Double]?
        Task.detached {
            do {
                let encoded = try bundle.encode(prefixed, maxLength: 512)
                let asFloat = await encoded.cast(to: Float.self).shapedArray(of: Float.self)
                let shape = asFloat.shape
                let scalars = asFloat.scalars
                // Pool over the sequence dimension to get a single
                // sentence vector. NomicBert can emit either
                // [1, hidden] (already pooled), [1, seqLen, hidden],
                // or [seqLen, hidden] depending on the model wrapper.
                // Mean-pool whichever shape we see; the L2-normalize
                // at the end makes cosine == dot product.
                let pooled: [Double]
                if shape.count == 2 && shape[0] == 1 {
                    pooled = (0..<shape[1]).map { Double(scalars[$0]) }
                } else if shape.count == 3 && shape[0] == 1 {
                    let seqLen = shape[1], hidden = shape[2]
                    var acc = [Double](repeating: 0, count: hidden)
                    for t in 0..<seqLen {
                        let base = t * hidden
                        for h in 0..<hidden { acc[h] += Double(scalars[base + h]) }
                    }
                    pooled = acc.map { $0 / Double(seqLen) }
                } else if shape.count == 2 {
                    let seqLen = shape[0], hidden = shape[1]
                    var acc = [Double](repeating: 0, count: hidden)
                    for t in 0..<seqLen {
                        let base = t * hidden
                        for h in 0..<hidden { acc[h] += Double(scalars[base + h]) }
                    }
                    pooled = acc.map { $0 / Double(seqLen) }
                } else {
                    sem.signal()
                    return
                }
                let norm = sqrt(pooled.reduce(0) { $0 + $1 * $1 })
                resultVec = norm > 0 ? pooled.map { $0 / norm } : pooled
            } catch {
                // Leave resultVec nil; caller treats as "no semantic"
                // and falls through to BM25-only retrieval.
            }
            sem.signal()
        }
        sem.wait()
        return resultVec
        }
    }

    private nonisolated func ensureNomicLoadedBlocking() {
        lock.lock()
        if nomicBundle != nil { lock.unlock(); return }
        if nomicLoadAttempted { lock.unlock(); return }
        nomicLoadAttempted = true
        lock.unlock()

        guard let repoID = EmbeddingBackend.nomic.modelID else { return }

        // 2026-05-28 (#71) — Memory pre-flight refusal, mirroring the
        // MLX pattern in `MLXService.loadModel`. Surfaced live during
        // the post-N1 verification: the second Nomic re-migration in a
        // single session jetsam-killed the app mid-load. UserDefaults
        // persisted target=nomic so the relaunch recovered cleanly, but
        // the kill is the failure mode we want to refuse-rather-than-
        // crash. Better to leave the user on the prior embedder with a
        // log line they can grep than to lose the process.
        //
        // Nomic on-disk size ≈ 522 MB; mmap-loaded effective resident
        // memory uses the same 0.75× ratio Hal calibrated for MLX. The
        // 250 MB safety margin covers Swift baseline + activation
        // buffer. Same `requiredMemoryMBForLoad` helper as MLX.
        let availableMB = processAvailableMemoryMB()
        let requiredMB = requiredMemoryMBForLoad(sizeGB: 0.522)
        if availableMB < requiredMB {
            dbgLog("EMB-MEM: Nomic load REFUSED — availableMB=%.0f requiredMB=%.0f",
                   availableMB, requiredMB)
            // Allow retry next call when memory recovers. The fallback
            // path (BM25-only retrieval) takes over until then.
            lock.lock()
            self.nomicLoadAttempted = false
            lock.unlock()
            return
        }
        dbgLog("EMB-MEM: Nomic load pre-flight OK — availableMB=%.0f requiredMB=%.0f",
               availableMB, requiredMB)

        // The Nomic load triggers a ~522 MB HuggingFace fetch on
        // first use. Set the crash guard before attempting, clear
        // on success — if the load crashes the process, the next
        // launch reverts to NLContextual rather than re-crashing.
        EmbeddingBackend.recordLoadAttempt()

        let sem = DispatchSemaphore(value: 0)
        var loaded: NomicBert.ModelBundle?
        Task.detached {
            do {
                // 2026-06-16 — download/load the Nomic asset into the shared App
                // Group container (not purgeable Caches), so it survives storage
                // pressure and the Posey app family shares one copy.
                loaded = try await NomicBert.loadModelBundle(
                    from: repoID,
                    downloadBase: SharedModelStore.huggingFaceRoot
                )
            } catch {
                // Leave loaded nil; allow retry next call.
            }
            sem.signal()
        }
        sem.wait()

        if let loaded = loaded {
            lock.lock()
            self.nomicBundle = loaded
            lock.unlock()
            EmbeddingBackend.recordLoadSuccess()
        } else {
            lock.lock()
            self.nomicLoadAttempted = false
            lock.unlock()
        }
    }

    // MARK: - Cosine similarity (used everywhere downstream)

    /// Standard cosine similarity over `[Double]` vectors. Rejects
    /// dimension mismatches by returning 0 — embedding-system
    /// migrations therefore can't silently produce noise (a row
    /// half-migrated to a different-dimensional backend just
    /// scores zero).
    nonisolated static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }
}

// ========== BLOCK 01: EMBEDDING PROVIDER - END ==========
