import Foundation
import NaturalLanguage

// ========== BLOCK 01: TYPES - START ==========
// Posey's project-wide setting `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
// means every type in this file would otherwise be implicitly MainActor.
// The Ask Posey embedding index does CPU-bound work (chunking, embedding,
// SQLite I/O) and is read both from MainActor (the library importers) and
// — crucially — *deallocated* from XCTest's runner threads, which are not
// MainActor. With MainActor isolation, deinit is dispatched via
// `swift_task_deinitOnExecutorImpl`, and a Swift Concurrency runtime
// issue around TaskLocal scope teardown crashes the test bundle on
// dealloc. Marking everything in this file `nonisolated` keeps deinit
// in-place, eliminates the executor hop, and preserves correctness because
// the index has no mutable state of its own.

/// One chunk produced by `DocumentEmbeddingIndex.chunk(_:)`. Holds the
/// `plainText` slice and its character-offset range so retrieval can map
/// back into the document's original coordinate space (used by Ask Posey
/// to render "jump to passage" links and to dedup against verbatim
/// content already in the prompt).
nonisolated struct DocumentEmbeddingChunk: Equatable, Sendable {
    let chunkIndex: Int
    let startOffset: Int
    let endOffset: Int
    let text: String
}

/// One result from `DocumentEmbeddingIndex.search`. The chunk plus its
/// cosine similarity to the query embedding. Score is in [-1, 1] but in
/// practice for sentence embeddings on related text it's [0, 1].
nonisolated struct DocumentEmbeddingSearchResult: Equatable, Sendable {
    let chunk: StoredDocumentChunk
    let similarity: Double
}

/// Errors the embedding index can throw at the public surface. Caller
/// code should treat all of these as "couldn't index right now" — the
/// document is still importable, the index is just absent or stale.
nonisolated enum DocumentEmbeddingError: LocalizedError, Sendable {
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
nonisolated struct DocumentEmbeddingIndexConfiguration: Sendable {
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
///
/// `nonisolated` because the project default is `MainActor` and the
/// service is allocated/released from non-MainActor contexts (XCTest
/// runner threads, eventually a background `Task` for retro-indexing).
/// MainActor-isolated deinit hopping triggers a Swift Concurrency
/// runtime crash on dealloc; nonisolated avoids the hop entirely.
nonisolated final class DocumentEmbeddingIndex {

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

    /// Best-effort wrapper around `indexIfNeeded`. Catches and logs any
    /// failure via NSLog, never throws, never returns a value caller has
    /// to dispose of. This is the variant importers should call after
    /// `upsertDocument` — if indexing fails, the document is still
    /// fully readable; the index will be retro-built on first Ask Posey
    /// invocation. The NSLog gives us a breadcrumb so consistent
    /// failures (a real bug) don't go silent.
    func tryIndex(_ document: Document) {
        do {
            try indexIfNeeded(document)
        } catch {
            NSLog(
                "[POSEY_ASK_POSEY] embedding index failed for %@ (%@): %@",
                document.title,
                document.id.uuidString,
                "\(error)"
            )
        }
    }

    /// Enqueue indexing on a background dispatch queue and post
    /// notifications around the work so any view that wants to display
    /// "Indexing this document…" can pick up the state.
    ///
    /// This is the variant the library importers call after
    /// `upsertDocument`. It returns immediately so import never blocks
    /// the main thread on the multi-second embedding pass — Mark's
    /// "Illuminatus load time" complaint was rooted in the previous
    /// synchronous call (≈3,300 chunks × ~5-10ms each = 16-33s on a
    /// 1.6M-char EPUB). The synchronous form is retained for tests
    /// and any caller that needs a deterministic completion point.
    ///
    /// **Threading:** the CPU-bound work (language detection,
    /// chunking, NLEmbedding calls) runs on a background dispatch
    /// queue. The SQLite write hops back to the main queue because
    /// `DatabaseManager` uses a single sqlite3 handle without internal
    /// synchronisation — production code must always touch it from a
    /// single thread. The main queue is the one we already use across
    /// the rest of the app, so we keep it as the canonical SQLite
    /// thread.
    func enqueueIndexing(_ document: Document) {
        // Skip work entirely when the document already has chunks —
        // this matches `indexIfNeeded`'s contract and avoids posting
        // a misleading "Indexing…" notification for documents that
        // need no work. The COUNT(*) is sub-millisecond and runs
        // wherever the caller is — typically the main thread (library
        // importers).
        let alreadyIndexed: Bool
        do {
            alreadyIndexed = try database.chunkCount(for: document.id) > 0
        } catch {
            alreadyIndexed = false
        }
        guard !alreadyIndexed else { return }

        let documentID = document.id
        let documentTitle = document.title
        let plainText = document.plainText
        // Capture only Sendable values into the @Sendable
        // dispatch closures — capturing `self` (a non-Sendable class
        // reference) would surface a Sendable warning in Swift 5
        // and an error in Swift 6. The chunk-building helpers we
        // need are all `static` so we don't need an instance to call
        // them; the database write is dispatched back to main with
        // an explicit weak self capture, where the access is safe.
        let database = self.database
        let configuration = self.configuration

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .documentIndexingDidStart,
                object: nil,
                userInfo: [
                    DocumentEmbeddingIndex.notificationDocumentIDKey: documentID,
                    DocumentEmbeddingIndex.notificationDocumentTitleKey: documentTitle
                ]
            )
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Pure-CPU phase: language detection + chunking + NLEmbedding
            // calls. No SQLite touched here — database writes happen on
            // main below.
            let language = Self.detectLanguage(in: plainText)
            let kind = Self.embeddingKind(for: language)
            let embedder = Self.embedder(for: language)
            let chunks = Self.chunk(plainText, configuration: configuration)
            let totalChunks = chunks.count

            // Post an initial 0-of-N progress so the UI can render the
            // count immediately — without this, the user briefly sees
            // "Indexing this document…" with no number while the first
            // batch processes.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .documentIndexingDidProgress,
                    object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: documentID,
                        DocumentEmbeddingIndex.notificationProcessedChunksKey: 0,
                        DocumentEmbeddingIndex.notificationTotalChunksKey: totalChunks
                    ]
                )
            }

            // Embed in chunks of 50 between progress posts. Posting
            // every chunk would flood the main queue; 50 is a balance
            // between responsiveness (the UI updates ~6× per second
            // for a typical 5-10ms-per-chunk pace) and overhead. For
            // small documents (< 50 chunks) the loop completes without
            // posting any intermediate progress and the .didComplete
            // notification carries the final count.
            let progressBatchSize = 50
            var stored: [StoredDocumentChunk] = []
            stored.reserveCapacity(totalChunks)
            for (index, chunk) in chunks.enumerated() {
                let vector = Self.embed(chunk.text, with: embedder)
                stored.append(StoredDocumentChunk(
                    chunkIndex: chunk.chunkIndex,
                    startOffset: chunk.startOffset,
                    endOffset: chunk.endOffset,
                    text: chunk.text,
                    embedding: vector,
                    embeddingKind: kind
                ))
                let processed = index + 1
                if processed % progressBatchSize == 0 && processed < totalChunks {
                    let snapshot = processed
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .documentIndexingDidProgress,
                            object: nil,
                            userInfo: [
                                DocumentEmbeddingIndex.notificationDocumentIDKey: documentID,
                                DocumentEmbeddingIndex.notificationProcessedChunksKey: snapshot,
                                DocumentEmbeddingIndex.notificationTotalChunksKey: totalChunks
                            ]
                        )
                    }
                }
            }

            // Persist + notify on main. SQLite handle is single-threaded
            // so all writes route through the canonical main thread.
            DispatchQueue.main.async {
                do {
                    try database.replaceChunks(stored, for: documentID)
                    NotificationCenter.default.post(
                        name: .documentIndexingDidComplete,
                        object: nil,
                        userInfo: [
                            DocumentEmbeddingIndex.notificationDocumentIDKey: documentID,
                            DocumentEmbeddingIndex.notificationChunkCountKey: stored.count
                        ]
                    )
                } catch {
                    NSLog(
                        "[POSEY_ASK_POSEY] embedding index failed for %@ (%@): %@",
                        documentTitle,
                        documentID.uuidString,
                        "\(error)"
                    )
                    NotificationCenter.default.post(
                        name: .documentIndexingDidFail,
                        object: nil,
                        userInfo: [
                            DocumentEmbeddingIndex.notificationDocumentIDKey: documentID,
                            DocumentEmbeddingIndex.notificationErrorKey: error
                        ]
                    )
                }
            }
        }
    }

    // MARK: Notification keys

    /// Notification userInfo key for the affected document's UUID. Always present.
    static let notificationDocumentIDKey = "posey.askposey.indexing.documentID"
    /// Notification userInfo key for the document title (humans). Optional.
    static let notificationDocumentTitleKey = "posey.askposey.indexing.documentTitle"
    /// Notification userInfo key for the indexed chunk count. Present on .didComplete.
    static let notificationChunkCountKey = "posey.askposey.indexing.chunkCount"
    /// Notification userInfo key for the failure error. Present on .didFail.
    static let notificationErrorKey = "posey.askposey.indexing.error"
    /// Notification userInfo key for processed-chunk count. Present on
    /// .didProgress. Use alongside `notificationTotalChunksKey` to
    /// render "Indexing N of M sections".
    static let notificationProcessedChunksKey = "posey.askposey.indexing.processedChunks"
    /// Notification userInfo key for total-chunk count. Present on
    /// .didProgress. Total is known up front from the chunking pass.
    static let notificationTotalChunksKey = "posey.askposey.indexing.totalChunks"

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

    /// Slice `text` into overlapping chunks per the instance's
    /// configuration. Convenience wrapper over the static form so
    /// tests can call `index.chunk(...)` without re-passing the
    /// configuration; production code paths that already have a
    /// detached configuration (e.g. the background closure inside
    /// `enqueueIndexing`) call the static form directly.
    func chunk(_ text: String) -> [DocumentEmbeddingChunk] {
        Self.chunk(text, configuration: configuration)
    }

    /// Static chunking pass. Called from the background closure in
    /// `enqueueIndexing` so the operation doesn't need a non-Sendable
    /// `self` capture. Visibility-internal so unit tests can pass a
    /// custom configuration if they ever need to assert boundaries
    /// against a non-default chunk size.
    static func chunk(
        _ text: String,
        configuration: DocumentEmbeddingIndexConfiguration
    ) -> [DocumentEmbeddingChunk] {
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
// `nonisolated extension` so language helpers and the `cosine`
// utility are callable from `search`/`indexIfNeeded`/`tryIndex`/
// `enqueueIndexing` (all nonisolated by class declaration). Without
// this annotation the project's default MainActor isolation would
// promote these helpers, and Swift 5 with approachable concurrency
// emits a warning when nonisolated callers reach into them.
nonisolated extension DocumentEmbeddingIndex {

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


// ========== BLOCK 05: NOTIFICATION NAMES - START ==========
extension Notification.Name {
    /// Posted on the main queue immediately before background indexing
    /// begins for a document. Observe this to show "Indexing…" UI.
    static let documentIndexingDidStart    = Notification.Name("posey.askposey.indexingDidStart")
    /// Posted on the main queue when background indexing finishes
    /// successfully. UserInfo carries the chunk count under
    /// `DocumentEmbeddingIndex.notificationChunkCountKey`.
    static let documentIndexingDidComplete = Notification.Name("posey.askposey.indexingDidComplete")
    /// Posted on the main queue when background indexing throws.
    /// UserInfo carries the error under
    /// `DocumentEmbeddingIndex.notificationErrorKey`. The document
    /// remains readable; callers should treat this as "RAG
    /// temporarily unavailable for this document," not a hard import
    /// failure.
    static let documentIndexingDidFail     = Notification.Name("posey.askposey.indexingDidFail")
    /// Posted periodically during background indexing so UI can render
    /// "Indexing 847 of 3,300 sections" instead of an indeterminate
    /// spinner. Posted at every progress checkpoint (currently every
    /// 50 chunks); not posted on completion (the .didComplete
    /// notification covers that).
    static let documentIndexingDidProgress = Notification.Name("posey.askposey.indexingDidProgress")
}
// ========== BLOCK 05: NOTIFICATION NAMES - END ==========
