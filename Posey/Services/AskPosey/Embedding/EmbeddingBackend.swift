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
    /// (iOS 17+, mBERT under the hood). Higher retrieval quality
    /// than the legacy `NLEmbedding.sentenceEmbedding` API, 512-dim,
    /// runs on the Neural Engine. Requires a one-time asset
    /// download on first launch — handled transparently by the
    /// system (no UI prompt, no user interaction). This is the
    /// **default** and what Hal Universal also defaults to.
    case nlContextual = "nlcontextual"

    /// Nomic Embed Text v1.5 via the `swift-embeddings` package
    /// (Apple MLTensor, no MLX, no Metal init crash). 768-dim,
    /// purpose-built for asymmetric retrieval (`search_query:` /
    /// `search_document:` prefixes — see `EmbeddingPurpose`).
    /// ~522 MB on disk. The upgrade option for users who want
    /// stronger retrieval quality. Wired live in Step 8h.
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

    // MARK: - Backend swap markers (2026-06-17 — per-backend columns)

    /// Key holding the `rawValue` of the backend a swap is currently
    /// filling, or absent when no swap is in flight. Persisted so an
    /// interrupted swap RESUMES on the next launch (Rule 3). Distinct
    /// from `defaultsKey`: `defaultsKey` is the ACTIVE backend the
    /// retriever reads (only flipped at swap COMPLETION); this is the
    /// in-flight TARGET being built. While this is set, Ask Posey is
    /// locked (`AskPoseyAvailability.isUnlocked` gains `&& !isSwapInProgress`).
    nonisolated static let swapTargetKey = "askPosey.embeddingBackend.swapTarget"

    /// The backend a swap is currently building, or nil if none. Reading
    /// this is how launch-resume detects an interrupted swap.
    nonisolated static func swapTarget() -> EmbeddingBackend? {
        guard let raw = UserDefaults.standard.string(forKey: swapTargetKey) else { return nil }
        return EmbeddingBackend(rawValue: raw)
    }

    /// True while a swap is building the target backend's column. The
    /// active backend (and its complete column) stays readable throughout;
    /// only the reader-facing Ask Posey surfaces are gated off during this
    /// window so no query races a half-built column.
    nonisolated static var isSwapInProgress: Bool {
        UserDefaults.standard.string(forKey: swapTargetKey) != nil
    }

    nonisolated static func beginSwapMarker(target: EmbeddingBackend) {
        UserDefaults.standard.set(target.rawValue, forKey: swapTargetKey)
    }

    nonisolated static func clearSwapMarker() {
        UserDefaults.standard.removeObject(forKey: swapTargetKey)
    }

    /// The backend that NEW embeddings are produced in and written to — the
    /// swap TARGET while a swap is building (so fresh vectors land in the
    /// column being filled), otherwise the active backend. Decoupled from
    /// `current()` on purpose: `current()` is the backend the RETRIEVER reads
    /// (the complete column, only flipped at swap completion), while this is
    /// the backend `EmbeddingProvider` embeds with. During a swap the two
    /// differ — reads stay on the old complete column, writes fill the new one
    /// — which is exactly what lets the swap be non-destructive (Rule 1) and
    /// keeps retrieval correct without ever reading a half-built column.
    nonisolated static func writeBackend() -> EmbeddingBackend {
        return swapTarget() ?? current()
    }

    /// Resolved active backend, honoring the crash guard. Reads
    /// `defaultsKey` on each call; cheap. Call
    /// `applyCrashGuardAtLaunch()` once at startup before any
    /// other access so the guard's side effect happens in a
    /// predictable place.
    ///
    /// Default is `nlContextual` — Apple's mBERT-backed embedder.
    /// The required asset downloads transparently in the
    /// background on first launch; until it's ready, retrieval
    /// degrades to the BM25/lexical path (no semantic) and the
    /// next round automatically picks up the loaded model. Users
    /// can upgrade to Nomic (~522 MB) via the embedder picker.
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
        // The crash guard only protects against heavyweight loads
        // (Nomic in particular). nlSentence and nlContextual are
        // OS-bundled and don't crash on load — no need to revert.
        guard selected == .nomic else { return selected }
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

    /// The `unit_embedding_chunks` BLOB column that stores THIS backend's
    /// vectors. Each backend owns a permanent column so both vector sets
    /// coexist — a swap fills the target's column without destroying the
    /// other, and removing a backend is a free revert (flip the active flag,
    /// no re-embed). The name is from this fixed enum (never user input), so
    /// interpolating it into SQL is safe.
    nonisolated var vectorColumn: String {
        switch self {
        case .nlContextual: return "embedding_nl"
        case .nomic:        return "embedding_nomic"
        }
    }

    /// HuggingFace model id for backends that load a downloadable
    /// model. nil for OS-built-in backends.
    nonisolated var modelID: String? {
        switch self {
        case .nlContextual: return nil
        case .nomic:        return "nomic-ai/nomic-embed-text-v1.5"
        }
    }

    /// On-disk size note for the model picker UI. nil for backends
    /// where the user incurs no managed download.
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
            return "Built into iOS. Runs on the Neural Engine. Asset downloads transparently in the background on first launch — no user interaction needed. The default."
        case .nomic:
            return "Nomic AI's open embedding model. 137M params, 768-dim, purpose-built for asymmetric retrieval (query vs document). ~522 MB on disk."
        }
    }
}

// ========== BLOCK 01: EMBEDDING BACKEND - END ==========
