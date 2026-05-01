import Foundation
import NaturalLanguage

// ========== BLOCK 01: TYPES - START ==========
/// One chunk produced by `DocumentEmbeddingIndex.chunk(_:)`. Holds the
/// `plainText` slice and its character-offset range so retrieval can map
/// back into the document's original coordinate space (used by Ask Posey
/// to render "jump to passage" links and to dedup against verbatim
/// content already in the prompt).
struct DocumentEmbeddingChunk: Equatable {
    let chunkIndex: Int
    let startOffset: Int
    let endOffset: Int
    let text: String
}

/// One result from `DocumentEmbeddingIndex.search`. The chunk plus its
/// cosine similarity to the query embedding. Score is in [-1, 1] but in
/// practice for sentence embeddings on related text it's [0, 1].
struct DocumentEmbeddingSearchResult: Equatable {
    let chunk: StoredDocumentChunk
    let similarity: Double
}

/// Errors the embedding index can throw at the public surface. Caller
/// code should treat all of these as "couldn't index right now" — the
/// document is still importable, the index is just absent or stale.
enum DocumentEmbeddingError: LocalizedError {
    case emptyText
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyText:           return "Cannot index an empty document."
        case .databaseUnavailable: return "Posey could not reach the local database."
        }
    }
}
// ========== BLOCK 01: TYPES - END ==========


// ========== BLOCK 02: CONFIG - START ==========
/// Configuration knobs for the index. Defaults match `ask_posey_spec.md`:
/// 500-char windows with 50-char overlap. Exposed as a struct so tests
/// can build deterministic chunkings without monkey-patching the static
/// surface. Production callers always use `.default`.
struct DocumentEmbeddingIndexConfiguration {
    /// Target chunk size in characters. Most chunks land at exactly this
    /// size; the final chunk is whatever remains.
    let chunkSize: Int
    /// How many trailing characters of chunk N also appear at the start
    /// of chunk N+1, to give RAG retrieval continuity at chunk borders.
    let chunkOverlap: Int

    static let `default` = DocumentEmbeddingIndexConfiguration(
        chunkSize: 500,
        chunkOverlap: 50
    )
}
// ========== BLOCK 02: CONFIG - END ==========


// ========== BLOCK 03: SERVICE - START ==========
/// Builds and queries the per-document embedding index used by Ask Posey
/// for RAG retrieval (Milestone 2).
///
/// Lifecycle:
/// 1. Library importers call `indexIfNeeded(_:)` after `upsertDocument`.
///    The first time it runs for a document, the index is built and
///    persisted to `document_chunks`. Subsequent calls early-return if
///    the table already has rows for that document, so re-imports of
///    identical content stay cheap.
/// 2. When existing-content imports change (the `existingDocument`
///    matcher returns nil but the same UUID is re-used after a reset)
///    callers should explicitly request a rebuild via
///    `rebuildIndex(for:plainText:)`.
/// 3. `search(documentID:query:limit:)` returns the top-K chunks for a
///    user question, used by the prompt builder in Milestone 6.
///
/// Multilingual: language is detected with `NLLanguageRecognizer` and
/// the matching `NLEmbedding.sentenceEmbedding(for:)` is selected when
/// available; English is the fallback when no matching model ships;
/// hash-based embeddings are the final fallback so import never fails
/// on a model gap.
final class DocumentEmbeddingIndex {

    // MARK: Wiring

    private let database: DatabaseManager
    private let configuration: DocumentEmbeddingIndexConfiguration

    init(database: DatabaseManager,
         configuration: DocumentEmbeddingIndexConfiguration = .default) {
        self.database = database
        self.configuration = configuration
    }

    // MARK: Public surface

    /// Build the chunk index for `document` if it has none. Idempotent:
    /// returns immediately if `document_chunks` already has rows for
    /// this document.
    @discardableResult
    func indexIfNeeded(_ document: Document) throws -> Int {
        let count = try database.chunkCount(for: document.id)
        if count > 0 { return count }
        return try rebuildIndex(for: document.id, plainText: document.plainText)
    }

    /// Force a rebuild of the chunk index for a document. Used by
    /// re-import paths where the underlying text may have changed.
    @discardableResult
    func rebuildIndex(for documentID: UUID, plainText: String) throws -> Int {
        guard !plainText.isEmpty else { throw DocumentEmbeddingError.emptyText }

        let language = Self.detectLanguage(in: plainText)
        let kind = Self.embeddingKind(for: language)
        let embedder = Self.embedder(for: language)

        let chunks = chunk(plainText)
        var stored: [StoredDocumentChunk] = []
        stored.reserveCapacity(chunks.count)

        for chunk in chunks {
            let vector = Self.embed(chunk.text, with: embedder)
            stored.append(StoredDocumentChunk(
                chunkIndex: chunk.chunkIndex,
                startOffset: chunk.startOffset,
                endOffset: chunk.endOffset,
                text: chunk.text,
                embedding: vector,
                embeddingKind: kind
            ))
        }

        try database.replaceChunks(stored, for: documentID)
        return stored.count
    }

    /// Return the top-`limit` chunks for `query`, ranked by cosine
    /// similarity against the query's embedding. Empty result set if the
    /// document has no chunks indexed yet (callers should treat that as
    /// "RAG unavailable for this query, fall back to non-RAG context").
    func search(documentID: UUID, query: String, limit: Int) throws -> [DocumentEmbeddingSearchResult] {
        let stored = try database.chunks(for: documentID)
        guard !stored.isEmpty, !query.isEmpty else { return [] }

        // Use the same embedding model the document was indexed with so
        // the query and chunk vectors live in the same space. If the
        // chunks are mixed-kind (re-index in progress) we score per
        // chunk against an embedder built for that chunk's language.
        let kindGroups = Dictionary(grouping: stored, by: { $0.embeddingKind })
        var allScored: [DocumentEmbeddingSearchResult] = []
        for (kind, group) in kindGroups {
            let language = Self.language(forKind: kind)
            let embedder = Self.embedder(for: language)
            let queryVector = Self.embed(query, with: embedder)
            for storedChunk in group {
                let score = Self.cosine(queryVector, storedChunk.embedding)
                allScored.append(DocumentEmbeddingSearchResult(chunk: storedChunk, similarity: score))
            }
        }
        allScored.sort { $0.similarity > $1.similarity }
        return Array(allScored.prefix(limit))
    }

    // MARK: Chunking (visible for testing)

    /// Slice `text` into overlapping chunks per the configuration.
    /// Visibility-internal so unit tests can assert exact boundaries.
    func chunk(_ text: String) -> [DocumentEmbeddingChunk] {
        let chunkSize = configuration.chunkSize
        let overlap   = configuration.chunkOverlap
        precondition(chunkSize > 0, "chunkSize must be positive")
        precondition(overlap >= 0 && overlap < chunkSize, "overlap must be in [0, chunkSize)")

        var chunks: [DocumentEmbeddingChunk] = []
        let total = text.count
        if total == 0 { return [] }

        var start = 0
        var index = 0
        while start < total {
            let end = min(start + chunkSize, total)
            let lower = text.index(text.startIndex, offsetBy: start)
            let upper = text.index(text.startIndex, offsetBy: end)
            let slice = String(text[lower..<upper])
            chunks.append(DocumentEmbeddingChunk(
                chunkIndex: index,
                startOffset: start,
                endOffset: end,
                text: slice
            ))
            index += 1
            if end == total { break }
            // Advance by chunkSize - overlap so each new chunk shares
            // `overlap` characters with the previous one.
            start = max(start + chunkSize - overlap, start + 1)
        }
        return chunks
    }
}
// ========== BLOCK 03: SERVICE - END ==========


// ========== BLOCK 04: LANGUAGE + EMBEDDING - START ==========
extension DocumentEmbeddingIndex {

    /// Best-effort language detection. NLLanguageRecognizer needs a
    /// reasonable sample to be confident — we hand it the first 1000
    /// characters which is typically more than enough for a long doc
    /// and tolerable noise for a short one.
    static func detectLanguage(in text: String) -> NLLanguage {
        let sample: String
        if text.count > 1000 {
            let endIndex = text.index(text.startIndex, offsetBy: 1000)
            sample = String(text[text.startIndex..<endIndex])
        } else {
            sample = text
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage ?? .english
    }

    /// Build an `NLEmbedding` for `language`, falling back to English if
    /// Apple ships no sentence-embedding model for that language. The
    /// hash fallback is selected at embedding time when this returns
    /// nil for both the detected language and English (extremely rare).
    static func embedder(for language: NLLanguage) -> NLEmbedding? {
        if let embedding = NLEmbedding.sentenceEmbedding(for: language) {
            return embedding
        }
        if language != .english,
           let englishFallback = NLEmbedding.sentenceEmbedding(for: .english) {
            return englishFallback
        }
        return nil
    }

    /// Embed `text` using `embedder`, falling back to a hash-derived
    /// vector when no native model is available or the model returns
    /// nil for this particular input. The hash fallback isn't a great
    /// embedding — it preserves nothing semantic — but it keeps import
    /// from failing on model gaps and lets ranked retrieval at least
    /// place exact-substring matches near each other. Real users on
    /// AFM-eligible hardware will overwhelmingly hit the native path.
    static func embed(_ text: String, with embedder: NLEmbedding?) -> [Double] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let embedder, !trimmed.isEmpty,
           let vector = embedder.vector(for: trimmed) {
            return vector
        }
        return hashEmbedding(for: trimmed)
    }

    /// Tag string written to `document_chunks.embedding_kind`. Captures
    /// which model produced the embeddings so a future model upgrade
    /// can re-index the rows that need it without rebuilding the whole
    /// library.
    static func embeddingKind(for language: NLLanguage) -> String {
        if NLEmbedding.sentenceEmbedding(for: language) != nil {
            return "\(language.rawValue)-sentence"
        }
        if language != .english,
           NLEmbedding.sentenceEmbedding(for: .english) != nil {
            return "english-fallback"
        }
        return "hash-fallback"
    }

    /// Reverse mapping from an `embedding_kind` tag back to the
    /// `NLLanguage` to use for query embedding. Necessary because the
    /// query has to be embedded in the same space as the stored chunks.
    static func language(forKind kind: String) -> NLLanguage {
        switch kind {
        case "english-fallback", "hash-fallback":
            return .english
        default:
            // Form: "<rawValue>-sentence". Strip the suffix and rebuild
            // the NLLanguage from the raw value. NLLanguage's raw value
            // is a BCP-47 language tag (e.g. "en", "fr") so this is a
            // direct round trip.
            if kind.hasSuffix("-sentence") {
                let raw = String(kind.dropLast("-sentence".count))
                return NLLanguage(rawValue: raw)
            }
            return .english
        }
    }

    /// Crash-prevention fallback. Mirrors Hal Block 05's hash-embedding
    /// shape (5 prime-like seeds × 13 dimensions = 65 dims, normalised
    /// to unit vector for cosine compatibility).
    private static func hashEmbedding(for text: String) -> [Double] {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return Array(repeating: 0, count: 64) }
        var embedding: [Double] = []
        let seeds = [1, 31, 131, 1313, 13131]
        for seed in seeds {
            let hash = abs(normalized.hashValue ^ seed)
            for i in 0..<13 {
                let value = Double((hash >> (i % 32)) & 0xFF) / 255.0
                embedding.append(value)
            }
        }
        let magnitude = sqrt(embedding.map { $0 * $0 }.reduce(0, +))
        if magnitude > 0 {
            embedding = embedding.map { $0 / magnitude }
        }
        return Array(embedding.prefix(64))
    }

    /// Standard cosine similarity. Returns 0 for mismatched dimensions
    /// or zero-magnitude vectors (which can happen with the hash
    /// fallback on empty input).
    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var aMag = 0.0
        var bMag = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            aMag += a[i] * a[i]
            bMag += b[i] * b[i]
        }
        let denom = sqrt(aMag) * sqrt(bMag)
        return denom == 0 ? 0 : dot / denom
    }
}
// ========== BLOCK 04: LANGUAGE + EMBEDDING - END ==========
