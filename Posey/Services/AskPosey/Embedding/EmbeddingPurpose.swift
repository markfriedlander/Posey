import Foundation

// ========== BLOCK 01: EMBEDDING PURPOSE - START ==========

/// Distinguishes how an embedding is being used. Required by
/// retrieval-asymmetric models (Nomic Embed v1.5 emits different
/// vectors when given the prompt prefix `search_query:` vs
/// `search_document:`). Symmetric backends ignore the parameter
/// and produce the same vector either way, so callers can pass
/// `.query` and `.document` everywhere without worrying about
/// backend capabilities.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8a). End-to-end asymmetry is the prerequisite
/// for adopting Nomic as a backend later (Step 8h).
nonisolated enum EmbeddingPurpose: Sendable {
    /// The text is being stored for later retrieval.
    case document
    /// The text is a search query being matched against stored documents.
    case query
}

// ========== BLOCK 01: EMBEDDING PURPOSE - END ==========
