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

    /// Task 4 #6 (A) — long-document config. Used for documents
    /// whose plainText length exceeds `longDocumentThresholdChars`.
    /// Initially set to 2000 chars per chunk; testing on
    /// Illuminatus showed that 2000-char chunks (~800 tokens
    /// each) crowd out the RAG budget — only 1 chunk fit per
    /// turn, defeating the entire point of retrieval. Settled at
    /// 1000 chars per chunk: ~400 tokens, allowing 3-4 chunks
    /// per turn within the long-doc 2800-token RAG budget. Still
    /// 2× the short-doc chunk size, so character/identity
    /// questions get more context per chunk than the original
    /// 500-char fragments while leaving headroom for multiple
    /// retrieval hits.
    static let longDocument = DocumentEmbeddingIndexConfiguration(
        chunkSize: 1000,
        chunkOverlap: 100
    )

    /// Documents over this length use the `longDocument` config
    /// (larger chunks). Threshold picked at 200K chars — covers
    /// typical book-length content (Illuminatus is 1.6M, novels
    /// are ~250K-1M, novellas/short books still get the precise
    /// 500-char chunking that suits short-form material).
    static let longDocumentThresholdChars: Int = 200_000

    /// Pick the right config for a document by length.
    static func adaptive(forCharacterCount count: Int) -> DocumentEmbeddingIndexConfiguration {
        count >= longDocumentThresholdChars ? .longDocument : .default
    }
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
        // Task 4 #6 (A) — adaptive chunk size by document length.
        // Override the instance config when the document is long.
        // The instance default still wins for short docs (essays,
        // papers, articles); long-form fiction / books get the
        // larger chunks that carry scene-level context.
        let configuration = DocumentEmbeddingIndexConfiguration
            .adaptive(forCharacterCount: plainText.count)

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
            // Task 4 #6 (B) — entity index. Collect (entityLower,
            // chunkIndex) pairs as we walk the chunks; persist them
            // alongside the chunk vectors at the end.
            var entityRows: [(entityLower: String, chunkIndex: Int)] = []
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
                // Extract named entities from this chunk via the
                // same NLTagger plumbing the entity-boost search
                // already uses. Lowercased + de-duped per chunk so
                // an entity mentioned 5 times in one chunk doesn't
                // create 5 rows.
                let chunkEntities = Self.extractEntities(from: chunk.text)
                for entity in chunkEntities {
                    entityRows.append((entityLower: entity, chunkIndex: chunk.chunkIndex))
                }
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
                    // Task 4 #6 (B) — replace any prior entities
                    // (from an older index) and bulk-insert the new
                    // ones in a single transaction. Failure here is
                    // non-fatal: chunks succeeded, the entity-aware
                    // retrieval just degrades to plain cosine for
                    // this document.
                    do {
                        try database.deleteEntities(for: documentID)
                        if !entityRows.isEmpty {
                            try database.insertEntities(documentID: documentID, entries: entityRows)
                        }
                    } catch {
                        NSLog(
                            "[POSEY_ASK_POSEY] entity index failed for %@: %@",
                            documentTitle,
                            "\(error)"
                        )
                    }
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

    // MARK: Entity-aware multi-factor scoring (M8 / v2)

    /// Search variant that re-ranks by combining cosine similarity
    /// with entity overlap between the query and each chunk. Per
    /// `NEXT.md` "Entity-aware multi-factor relevance scoring v2":
    /// `score = cosine + 2.0 × jaccard(query_entities, chunk_entities)`,
    /// clamped to [-1, 3]. Entities are extracted via `NLTagger`
    /// `nameType` at query time (for the question) and at score time
    /// (for each candidate chunk).
    ///
    /// Workflow:
    /// 1. Run regular embedding search to get a wider candidate set
    ///    (3× the requested limit) so re-ranking can promote
    ///    entity-rich chunks that ranked lower on pure cosine.
    /// 2. Extract query entities once.
    /// 3. For each candidate, extract chunk entities and compute
    ///    Jaccard overlap.
    /// 4. New score, sort, return top `limit`.
    ///
    /// Falls back gracefully: when neither side has entities, Jaccard
    /// is 0 and score reduces to pure cosine — same behavior as the
    /// existing `search`.
    func searchWithEntityBoost(
        documentID: UUID,
        query: String,
        limit: Int
    ) throws -> [DocumentEmbeddingSearchResult] {
        guard !query.isEmpty else { return [] }
        let widerLimit = max(limit * 3, limit)
        let candidates = try search(documentID: documentID, query: query, limit: widerLimit)

        // Task 4 #6 (B) — entity-index lookup. When the question
        // contains named entities AND the document has an entity
        // index, fetch every chunk that mentions those entities
        // (case-insensitive). These get UNCONDITIONALLY mixed into
        // the candidate pool — they may not have ranked top-K on
        // pure cosine but they're guaranteed to mention what the
        // user asked about. Empty entity set → degrade to pure
        // cosine, same as before.
        let queryEntities = Self.extractEntities(from: query)
        let queryEntitiesArray = Array(queryEntities)

        var entityChunks: [DocumentEmbeddingSearchResult] = []
        if !queryEntitiesArray.isEmpty {
            do {
                let mentionedIndices = try database.chunkIndicesMentioningEntities(
                    documentID: documentID,
                    entitiesLower: queryEntitiesArray
                )
                if !mentionedIndices.isEmpty {
                    let stored = try database.chunks(for: documentID)
                    let storedByIndex = Dictionary(uniqueKeysWithValues: stored.map { ($0.chunkIndex, $0) })
                    let candidateIndexSet = Set(candidates.map { $0.chunk.chunkIndex })
                    for idx in mentionedIndices where !candidateIndexSet.contains(idx) {
                        guard let chunk = storedByIndex[idx] else { continue }
                        // Synthetic similarity 0.99 — high enough
                        // to land at the top of re-ranked results
                        // but not 1.0 (reserved for exact-match
                        // sentinel uses elsewhere).
                        entityChunks.append(DocumentEmbeddingSearchResult(chunk: chunk, similarity: 0.99))
                    }
                }
            } catch {
                NSLog("[POSEY_ASK_POSEY] entity-index lookup failed: %@", "\(error)")
            }
        }

        let pool = candidates + entityChunks
        guard !pool.isEmpty else { return [] }

        // Score every candidate; the multi-factor formula clamps
        // into a stable range so downstream UI (relevance pills)
        // stays sensible. Entity-index chunks already start at
        // 0.99 + 2.0 × full-overlap so they reliably land near
        // the top.
        let rescored: [DocumentEmbeddingSearchResult] = pool.map { candidate in
            let chunkEntities = Self.extractEntities(from: candidate.chunk.text)
            let overlap = Self.jaccardOverlap(queryEntities, chunkEntities)
            let raw = candidate.similarity + 2.0 * overlap
            let clamped = max(-1.0, min(3.0, raw))
            return DocumentEmbeddingSearchResult(chunk: candidate.chunk, similarity: clamped)
        }

        return Array(rescored.sorted { $0.similarity > $1.similarity }.prefix(limit))
    }

    /// Extract person / place / organization names from `text` via
    /// `NLTagger.nameType`. Lowercased for case-insensitive overlap
    /// comparison. Returns a Set so repeated mentions don't inflate
    /// the overlap score.
    static func extractEntities(from text: String) -> Set<String> {
        guard !text.isEmpty else { return [] }
        var result = Set<String>()
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag else { return true }
            switch tag {
            case .personalName, .placeName, .organizationName:
                let span = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if span.count >= 2 { result.insert(span) }
            default:
                break
            }
            return true
        }
        return result
    }

    /// Jaccard similarity of two sets — `|intersection| / |union|`,
    /// or 0 when either is empty (avoids divide-by-zero AND is the
    /// honest answer: zero shared entities means no entity overlap).
    static func jaccardOverlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0.0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0.0 }
        return Double(intersection) / Double(union)
    }

    // MARK: Reference embedding + cosine for M6 dedup

    /// Embed an arbitrary string using the same embedding model the
    /// document was indexed with. Used by the M6 RAG dedup path to
    /// compute a reference vector for "anchor + recent STM" so we can
    /// drop chunks too similar to content already in the prompt.
    ///
    /// Returns an empty array if the document has no chunks indexed
    /// yet — callers should treat that as "skip dedup, ship all
    /// retrieved chunks." The embedding kind is inferred from the
    /// stored chunks; if chunks are mixed-kind (a re-index is in
    /// progress), the most common kind wins.
    func embed(_ text: String, forDocument documentID: UUID) -> [Double] {
        let stored: [StoredDocumentChunk]
        do {
            stored = try database.chunks(for: documentID)
        } catch {
            return []
        }
        guard !stored.isEmpty, !text.isEmpty else { return [] }
        // Pick the most common embedding kind across the document's
        // chunks. Mixed-kind tables happen briefly during re-index;
        // resolving to the dominant kind avoids skewing the reference
        // vector toward a minority embedder.
        let kindCounts = Dictionary(grouping: stored, by: { $0.embeddingKind }).mapValues(\.count)
        guard let dominantKind = kindCounts.max(by: { $0.value < $1.value })?.key else {
            return []
        }
        let language = Self.language(forKind: dominantKind)
        let embedder = Self.embedder(for: language)
        return Self.embed(text, with: embedder)
    }

    /// Cosine similarity in [-1, 1] between two embedding vectors.
    /// Mirrors the private `cosine(_:_:)` used by `search` —
    /// re-exposed for the M6 dedup path. Returns 0 when shapes don't
    /// match or either vector is empty.
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        Self.cosine(a, b)
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

    // MARK: Citation attribution (Task 2 #25)

    /// Cosine-similarity threshold for inline-citation attribution.
    /// A sentence's best-matching RAG chunk must score at least this
    /// to attach an `[N]` marker; otherwise the sentence renders
    /// uncited (the user can't navigate to a source the cosine
    /// scorer wouldn't trust).
    ///
    /// **Set 2026-05-02 from a 15-question battery against three
    /// documents (3 docs × 5 question types: factual, analytical,
    /// vague, connection, out-of-doc).** At 0.40, 85% of sentences
    /// were cited — too permissive, including borderline matches.
    /// At 0.55, 45% — too sparse, lost legitimate factual
    /// attributions like the Alternative Dispute Resolution title
    /// quote (scored 0.62 → would be lost at 0.60). At 0.50, 59%
    /// overall: factual 50%, analytical 81%, vague 30%,
    /// connection 78%, out-of-doc 0%. The vague-question category
    /// drops sharply between 0.40 and 0.50 (75% → 30%) — natural
    /// inflection where conversational filler stops being cited
    /// while in-document content still is. Mark picked 0.50.
    ///
    /// **Tuning.** Single-knob tunable here. Per-document-type
    /// thresholds (factual stricter than analytical, etc.) are a
    /// 2.0 feature logged in NEXT.md — not implemented yet.
    static let citationCosineThreshold: Double = 0.50

    /// When the second-best chunk's score is within this delta of
    /// the best AND both clear the threshold, attribute BOTH chunks
    /// (multi-cite as `[1][3]`). Avoids picking arbitrarily between
    /// two near-tied matches.
    static let citationSecondCitationDelta: Double = 0.05

    /// Attribute each sentence in `text` to the chunk(s) it most
    /// closely matches via cosine similarity in the embedding space,
    /// returning the same text with `[N]` markers appended where
    /// matches clear the threshold. The renderer downstream
    /// (`AskPoseyCitationRenderer`) converts each `[N]` to a
    /// tappable superscript link.
    ///
    /// **Algorithm.**
    /// 1. Pick the embedder for the document's dominant language
    ///    (same one the index uses).
    /// 2. Embed each sentence in `text` once.
    /// 3. Embed each chunk's text once.
    /// 4. For every sentence, score every chunk via cosine
    ///    similarity. Best wins. If second-best is within `delta`
    ///    of best AND also clears `threshold`, multi-cite as
    ///    `[1][3]` (concatenated, no separator — matches the
    ///    renderer's regex).
    /// 5. Sentences whose best score is below `threshold` get no
    ///    marker — the user simply can't navigate to a source for
    ///    that claim, which is correct (cosine wouldn't ground it).
    ///
    /// **Logging.** Every (sentence, best-chunk, score) triple is
    /// emitted via `NSLog` so we can see how the threshold lands on
    /// real answers and tune up or down.
    ///
    /// **Cost.** ~10–15ms for a typical 5-sentence answer over 5–8
    /// chunks on iPhone 16 Plus.
    func attributeCitations(
        text: String,
        chunks: [(chunkID: Int, citationNumber: Int, text: String)],
        documentID: UUID,
        threshold: Double = DocumentEmbeddingIndex.citationCosineThreshold,
        secondCitationDelta: Double = DocumentEmbeddingIndex.citationSecondCitationDelta
    ) -> String {
        guard !text.isEmpty, !chunks.isEmpty else { return text }

        // Embedder for this document.
        let stored: [StoredDocumentChunk]
        do { stored = try database.chunks(for: documentID) } catch { return text }
        guard !stored.isEmpty else { return text }
        let kindCounts = Dictionary(grouping: stored, by: { $0.embeddingKind }).mapValues(\.count)
        guard let dominantKind = kindCounts.max(by: { $0.value < $1.value })?.key else { return text }
        let language = Self.language(forKind: dominantKind)
        guard let embedder = Self.embedder(for: language) else { return text }

        // Embed each chunk once.
        let chunkVectors: [[Double]] = chunks.map { Self.embed($0.text, with: embedder) }

        // Split text into sentences via NLTokenizer — same tokenizer
        // the reader uses for segmentation. Returns an array of
        // (range, sentenceText) pairs in original order.
        let nsText = text as NSString
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [(range: NSRange, text: String)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let nsRange = NSRange(range, in: text)
            let sentenceText = String(text[range])
            sentences.append((nsRange, sentenceText))
            return true
        }
        guard !sentences.isEmpty else { return text }

        // Score each sentence against every chunk; pick top-2.
        var rebuilt = ""
        var cursor = 0
        for sentence in sentences {
            // Carry any whitespace / punctuation between sentences
            // verbatim — the tokenizer skips inter-sentence gaps.
            if sentence.range.location > cursor {
                rebuilt += nsText.substring(with: NSRange(location: cursor, length: sentence.range.location - cursor))
            }
            let trimmed = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let trailingWS = String(sentence.text.dropFirst(trimmed.count))
            // Skip very short sentences (one or two words — likely
            // headers or fragments). Embedding similarity on near-
            // empty text is noisy.
            guard trimmed.count > 12 else {
                rebuilt += sentence.text
                cursor = sentence.range.location + sentence.range.length
                continue
            }
            let sentenceVec = Self.embed(trimmed, with: embedder)
            // Score every chunk.
            var scores: [(citationNumber: Int, score: Double)] = []
            for (idx, vec) in chunkVectors.enumerated() {
                let score = Self.cosine(sentenceVec, vec)
                scores.append((chunks[idx].citationNumber, score))
            }
            scores.sort { $0.score > $1.score }
            let best = scores.first
            let second = scores.dropFirst().first
            // Log scores so we can see if the threshold needs tuning.
            // Format: best=[N]:0.52 second=[M]:0.48 sentence='…'
            if let best {
                let secondPart = second.map { "second=[\($0.citationNumber)]:\(String(format: "%.2f", $0.score))" } ?? "second=none"
                let snippet = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
                NSLog("AskPosey citation: best=[%d]:%.2f %@ sentence='%@'",
                      best.citationNumber, best.score, secondPart as NSString, snippet as NSString)
            }
            // Attach citation(s) if score clears threshold.
            var marker = ""
            if let best, best.score >= threshold {
                marker += "[\(best.citationNumber)]"
                if let second,
                   second.score >= threshold,
                   (best.score - second.score) <= secondCitationDelta,
                   second.citationNumber != best.citationNumber {
                    marker += "[\(second.citationNumber)]"
                }
            }
            rebuilt += "\(trimmed)\(marker)\(trailingWS)"
            cursor = sentence.range.location + sentence.range.length
        }
        if cursor < nsText.length {
            rebuilt += nsText.substring(from: cursor)
        }
        return rebuilt
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
