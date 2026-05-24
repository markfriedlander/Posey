import Foundation
import NaturalLanguage

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

    // NLContextualEmbedding (mBERT) — the default backend. Asset
    // is downloaded transparently by the system on first launch;
    // until ready, `embed()` returns nil and the retrieval
    // pipeline falls back to BM25-only.
    nonisolated(unsafe) private var nlContextualModel: NLContextualEmbedding?
    nonisolated(unsafe) private var nlContextualLoadAttempted: Bool = false

    // Nomic state is declared so the surface area is stable even
    // before 8h. The 8h step bumps these up to real types from
    // the `Embeddings` package and adds the load path; until
    // then `embedNomic` returns nil.
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

        switch EmbeddingBackend.current() {
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

    /// True if the currently active backend is loaded and ready.
    nonisolated var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        switch EmbeddingBackend.current() {
        case .nlContextual: return nlContextualModel != nil
        case .nomic:        return false // wired live in 8h
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
            switch EmbeddingBackend.current() {
            case .nlContextual: self.ensureNLContextualLoadedBlocking()
            case .nomic:        ()  // 8h wires this
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
        _ = nomicPrefixed(text, purpose: purpose)
        // 8h wires the live swift-embeddings call here. Until
        // then the surface returns nil; the migration coordinator
        // refuses the switch so callers shouldn't reach this.
        _ = nomicLoadAttempted
        return nil
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
