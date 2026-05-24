import Foundation

// ========== BLOCK 01: EMBEDDING BACKEND - START ==========

/// The set of embedding backends Posey can run for Ask Posey RAG.
/// One backend is active at a time, selected via UserDefaults
/// (`embeddingBackend` key); selection is persisted and reapplied
/// at app launch.
///
/// **Invariant:** every row in `unit_embedding_chunks` either holds
/// a vector in the active backend's space, or has `embedding = NULL`
/// and is awaiting re-embed by `EmbedderMigrationCoordinator`.
/// There is no per-row "embedding_kind" column — the active backend
/// is the only valid space, period. Swapping backends requires the
/// migration coordinator to NULL every row and re-embed.
///
/// Mirrors Hal Universal's `EmbeddingBackend` enum almost exactly;
/// the two projects share the same calibration discipline and the
/// same Nomic asymmetric-retrieval contract. Differences:
///
/// - Posey defaults to NLContextual today (no Nomic install
///   shipped with the app yet — see step 8h).
/// - Per-backend "synthesis threshold" (which Hal uses to merge
///   reflections) doesn't apply to Posey, so those constants are
///   omitted here. Backends carry only retrieval-relevant metadata.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8a).
nonisolated enum EmbeddingBackend: String, Sendable, CaseIterable {
    /// `NLEmbedding.sentenceEmbedding(for:)` — the pre-iOS-17
    /// Natural Language framework sentence embedder. Bundled with
    /// iOS, no download, language-specific dimensions (English is
    /// 50–300 depending on platform release). Lower retrieval
    /// quality than transformer-based backends but **available
    /// instantly on first launch**, which is why it's the default.
    /// Posey's legacy `DocumentEmbeddingIndex` defaults to this
    /// same backend, so behavior parity is preserved.
    case nlSentence = "nlsentence"

    /// Apple's transformer-based on-device sentence embedder
    /// (iOS 17+, mBERT). Higher retrieval quality, 512-dim, runs
    /// on the Neural Engine. Requires a one-time asset download
    /// on first selection (~50 MB). Opt-in via the embedder
    /// picker; matches Hal's NLContextual path.
    case nlContextual = "nlcontextual"

    /// Nomic Embed Text v1.5 via the `swift-embeddings` package
    /// (Apple MLTensor, no MLX, no Metal init crash). 768-dim,
    /// purpose-built for asymmetric retrieval (`search_query:` /
    /// `search_document:` prefixes — see `EmbeddingPurpose`).
    /// ~522 MB on disk. Wired live in Step 8h.
    case nomic = "nomic"

    // MARK: - UserDefaults

    /// Key under which the chosen backend's `rawValue` is stored.
    nonisolated static let defaultsKey = "askPosey.embeddingBackend"

    /// Key under which a Nomic / EmbeddingGemma-style "load in
    /// progress" flag lives. Set immediately before attempting
    /// to load a heavyweight model; cleared once the load
    /// succeeds. If a launch starts with this flag set, the
    /// previous launch crashed during load — we force back to
    /// NLContextual rather than re-crash on the same backend.
    nonisolated static let crashGuardKey = "askPosey.embeddingBackend.loadInFlight"

    /// Resolved active backend, honoring the crash guard. Reads
    /// `defaultsKey` on each call; cheap. Call
    /// `applyCrashGuardAtLaunch()` once at startup before any
    /// other access so the guard's side effect happens in a
    /// predictable place.
    ///
    /// Default is `nlSentence` — Apple's older NLEmbedding API
    /// that's built into iOS and works instantly. Users upgrade
    /// to NLContextual (one-time mBERT download) or Nomic
    /// (one-time 522 MB download) via the picker.
    nonisolated static func current() -> EmbeddingBackend {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)
            ?? Self.nlSentence.rawValue
        return EmbeddingBackend(rawValue: raw) ?? .nlSentence
    }

    /// Called once at app launch (before any embed call). If the
    /// previous launch wrote `crashGuardKey` (Nomic load was in
    /// flight when the process died), force NLContextual on this
    /// launch and persist that choice. Returns the resolved
    /// backend so the caller can log it.
    @discardableResult
    nonisolated static func applyCrashGuardAtLaunch() -> EmbeddingBackend {
        let selected = current()
        // The crash guard only protects against heavyweight loads
        // (Nomic in particular). nlSentence and nlContextual are
        // OS-bundled and don't crash on load — no need to revert.
        guard selected == .nomic else { return selected }
        let crashed = UserDefaults.standard.bool(forKey: crashGuardKey)
        if crashed {
            UserDefaults.standard.set(
                EmbeddingBackend.nlSentence.rawValue,
                forKey: defaultsKey
            )
            UserDefaults.standard.removeObject(forKey: crashGuardKey)
            return .nlSentence
        }
        return selected
    }

    /// Mark a heavyweight load as in-flight. Stored as a Bool so
    /// repeated attempts during the same launch are a no-op.
    nonisolated static func recordLoadAttempt() {
        UserDefaults.standard.set(true, forKey: crashGuardKey)
    }

    /// Load completed without crashing — clear the flag.
    nonisolated static func recordLoadSuccess() {
        UserDefaults.standard.removeObject(forKey: crashGuardKey)
    }

    // MARK: - Backend metadata

    /// Sentence-vector dimension for this backend. The migration
    /// coordinator does NOT consult this — its invariant is row-
    /// level (NULL or active), not dimension-tracked. This is
    /// here purely for diagnostics and sanity checks. NLEmbedding's
    /// English sentence dim varies by iOS release (was 300 for
    /// a long time, currently 50 on iOS 26 — Apple reduced it);
    /// callers shouldn't hard-code on this.
    nonisolated var dimension: Int {
        switch self {
        case .nlSentence:   return 50    // English; nominal, varies
        case .nlContextual: return 512
        case .nomic:        return 768
        }
    }

    /// HuggingFace model id for backends that load a downloadable
    /// model. nil for OS-built-in backends.
    nonisolated var modelID: String? {
        switch self {
        case .nlSentence:   return nil
        case .nlContextual: return nil
        case .nomic:        return "nomic-ai/nomic-embed-text-v1.5"
        }
    }

    /// On-disk size note for the model picker UI. nil for backends
    /// that don't ship a model file the user is on the hook for.
    var sizeBlurb: String? {
        switch self {
        case .nlSentence:   return nil
        case .nlContextual: return "~50 MB asset"
        case .nomic:        return "~522 MB"
        }
    }

    /// Display name shown in the embedder picker.
    var displayName: String {
        switch self {
        case .nlSentence:   return "Apple NLEmbedding (sentence)"
        case .nlContextual: return "Apple NLContextual (mBERT)"
        case .nomic:        return "Nomic Embed Text v1.5"
        }
    }

    /// One-line description for the picker card.
    var blurb: String {
        switch self {
        case .nlSentence:
            return "Built into iOS. Bundled with the OS, no download. Fast and small; the default."
        case .nlContextual:
            return "Apple's transformer-based mBERT embedder. Runs on the Neural Engine. Higher retrieval quality. Downloads a ~50 MB asset on first use."
        case .nomic:
            return "Nomic AI's open embedding model. 137M params, 768-dim, purpose-built for asymmetric retrieval (query vs document). ~522 MB on disk."
        }
    }
}

// ========== BLOCK 01: EMBEDDING BACKEND - END ==========
