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
    /// Apple's transformer-based on-device sentence embedder
    /// (iOS 17+). Built into the OS, no download, 512-dim.
    /// Default for v1 of the new architecture.
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
    nonisolated static func current() -> EmbeddingBackend {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)
            ?? Self.nlContextual.rawValue
        return EmbeddingBackend(rawValue: raw) ?? .nlContextual
    }

    /// Called once at app launch (before any embed call). If the
    /// previous launch wrote `crashGuardKey` (Nomic load was in
    /// flight when the process died), force NLContextual on this
    /// launch and persist that choice. Returns the resolved
    /// backend so the caller can log it.
    @discardableResult
    nonisolated static func applyCrashGuardAtLaunch() -> EmbeddingBackend {
        let selected = current()
        guard selected != .nlContextual else { return selected }
        let crashed = UserDefaults.standard.bool(forKey: crashGuardKey)
        if crashed {
            UserDefaults.standard.set(
                EmbeddingBackend.nlContextual.rawValue,
                forKey: defaultsKey
            )
            UserDefaults.standard.removeObject(forKey: crashGuardKey)
            return .nlContextual
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
    /// here purely for diagnostics and sanity checks.
    nonisolated var dimension: Int {
        switch self {
        case .nlContextual: return 512
        case .nomic:        return 768
        }
    }

    /// HuggingFace model id for backends that load a downloadable
    /// model. nil for the OS-built-in backend.
    nonisolated var modelID: String? {
        switch self {
        case .nlContextual: return nil
        case .nomic:        return "nomic-ai/nomic-embed-text-v1.5"
        }
    }

    /// On-disk size note for the model picker UI. nil for backends
    /// that don't ship a model file.
    var sizeBlurb: String? {
        switch self {
        case .nlContextual: return nil
        case .nomic:        return "~522 MB"
        }
    }

    /// Display name shown in the embedder picker.
    var displayName: String {
        switch self {
        case .nlContextual: return "Apple NLContextual"
        case .nomic:        return "Nomic Embed Text v1.5"
        }
    }

    /// One-line description for the picker card.
    var blurb: String {
        switch self {
        case .nlContextual:
            return "Built into iOS. Runs on the Neural Engine. 512-dim sentence vectors. No download, always available."
        case .nomic:
            return "Nomic AI's open embedding model. 137M params, 768-dim, purpose-built for asymmetric retrieval (query vs document). ~522 MB on disk."
        }
    }
}

// ========== BLOCK 01: EMBEDDING BACKEND - END ==========
