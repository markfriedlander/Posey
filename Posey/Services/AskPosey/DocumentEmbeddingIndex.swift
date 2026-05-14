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

    /// Optional metadata extractor closure (AFM-backed `@Generable`
    /// call wrapped in a closure). When non-nil, `enqueueIndexing`
    /// automatically chains to `enhanceMetadata` after the indexing
    /// pass completes, so the synthesized metadata chunk lands shortly
    /// after the content chunks. Nil on devices/OS versions that lack
    /// AFM, or in tests that don't want to exercise the AFM path.
    /// Closure-typed (rather than protocol-typed) to avoid the
    /// nonisolated→@MainActor cast hazards that Swift 6 surfaces when
    /// stashing protocol existentials inside a nonisolated class.
    typealias MetadataExtractorClosure = @MainActor (Document) async -> DocumentMetadata?
    private let metadataExtractor: MetadataExtractorClosure?

    init(database: DatabaseManager,
         configuration: DocumentEmbeddingIndexConfiguration = .default,
         metadataExtractor: MetadataExtractorClosure? = nil) {
        self.database = database
        self.configuration = configuration
        self.metadataExtractor = metadataExtractor
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
            dbgLog(
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
                        dbgLog(
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
                    // 2026-05-05 — Chain to metadata enhancement
                    // when an extractor is wired. Runs as a separate
                    // MainActor Task so we can `await` the AFM call.
                    // The synthesized prose chunk lands shortly after
                    // the content chunks; both stages roll up to a
                    // single progress signal in the UI.
                    dbgLog("DocumentEmbeddingIndex: indexing complete; metadataExtractor=%@",
                           self.metadataExtractor == nil ? "nil" : "set")
                    if let extractor = self.metadataExtractor {
                        let doc = Document(
                            id: documentID,
                            title: documentTitle,
                            fileName: documentTitle,
                            fileType: "",
                            importedAt: Date(),
                            modifiedAt: Date(),
                            displayText: plainText,
                            plainText: plainText,
                            characterCount: plainText.count
                        )
                        Task { @MainActor in
                            dbgLog("DocumentEmbeddingIndex: starting metadata enhancement for %@", documentTitle)
                            await self.enhanceMetadata(doc, extractor: extractor)
                            dbgLog("DocumentEmbeddingIndex: metadata enhancement complete for %@", documentTitle)
                        }
                    }
                } catch {
                    dbgLog(
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

    /// 2026-05-05 — Metadata enhancement notifications. Mirrors the
    /// indexing notifications shape so the IndexingTracker (and the
    /// future progress ring on the sparkle icon) can drive a single
    /// progress signal across multiple background-enhancement stages.
    static let metadataEnhancementDidStart = Notification.Name(
        "posey.askposey.metadata.didStart")
    static let metadataEnhancementDidComplete = Notification.Name(
        "posey.askposey.metadata.didComplete")
    static let metadataEnhancementDidFail = Notification.Name(
        "posey.askposey.metadata.didFail")

    /// Embedding-kind tag used for the synthetic metadata chunk. The
    /// suffix is intentional — it matches the document's content
    /// chunks' kind prefix (e.g., "en-minilm" + ":syn-meta") so
    /// `searchHybrid` can split synthetic chunks into their own kind
    /// group and embed the query with the matching embedder. Format:
    /// "<base-kind>:syn-meta" where base-kind is the kind already in
    /// use for the document's content chunks.
    static func syntheticMetadataKind(baseKind: String) -> String {
        "\(baseKind):syn-meta"
    }
    /// Inverse: extract the base kind from a synthetic kind tag, or
    /// return the input unchanged if it isn't a synthetic kind.
    static func baseKind(fromSyntheticKind kind: String) -> String {
        if let range = kind.range(of: ":syn-meta") {
            return String(kind[..<range.lowerBound])
        }
        return kind
    }
    /// True when this kind is a synthetic-metadata tag.
    static func isSyntheticKind(_ kind: String) -> Bool {
        kind.hasSuffix(":syn-meta")
    }

    /// Run AFM metadata extraction + prose synthesis for a document
    /// in the background. Posts `metadataEnhancementDidStart` /
    /// `…DidComplete` / `…DidFail` notifications around the work so
    /// the unified background-enhancement progress indicator can
    /// reflect both indexing and metadata stages as one ring.
    ///
    /// Idempotent: returns immediately if metadata for this document
    /// has already been extracted (`metadata_extracted_at > 0`).
    /// The AFM call only runs once per document.
    ///
    /// Threading: the AFM call must run on @MainActor (LanguageModelSession
    /// constraint). The embedding pass and DB writes also run on main
    /// because they touch shared state. Total wall-clock cost: 1-3
    /// seconds per document, dominated by the AFM round-trip.
    @MainActor
    func enhanceMetadata(_ document: Document,
                         extractor: MetadataExtractorClosure?) async {
        // Skip if no extractor wired (pre-AFM device, or test path).
        guard let extractor else { return }

        // Skip if already extracted.
        if let existing = try? database.documentMetadata(for: document.id),
           existing.extractedAt.timeIntervalSince1970 > 0 {
            dbgLog("DocumentMetadata: already extracted for %@; skipping",
                   document.title)
            return
        }

        let documentID = document.id
        NotificationCenter.default.post(
            name: Self.metadataEnhancementDidStart,
            object: nil,
            userInfo: [
                Self.notificationDocumentIDKey: documentID,
                Self.notificationDocumentTitleKey: document.title
            ]
        )

        // 1) Extract via AFM.
        guard let metadata = await extractor(document) else {
            // Extraction failed (AFM unavailable, refusal, error).
            // Document still works — just no synthetic chunk.
            NotificationCenter.default.post(
                name: Self.metadataEnhancementDidFail,
                object: nil,
                userInfo: [Self.notificationDocumentIDKey: documentID]
            )
            return
        }

        // 2) Persist structured fields on documents table.
        let stored = StoredDocumentMetadata(
            title: metadata.title,
            authors: metadata.authors,
            year: metadata.year,
            documentType: metadata.documentType,
            summary: metadata.summary,
            extractedAt: Date(),
            detectedNonEnglish: metadata.detectedNonEnglish
        )
        do {
            try database.saveDocumentMetadata(stored, for: documentID)
        } catch {
            dbgLog("DocumentMetadata: save failed for %@: %@",
                   document.title, "\(error)")
            NotificationCenter.default.post(
                name: Self.metadataEnhancementDidFail,
                object: nil,
                userInfo: [Self.notificationDocumentIDKey: documentID]
            )
            return
        }

        // 3) Pull TOC entries (if any) for prose synthesis.
        let tocEntries: [String]
        if let entries = try? database.tocEntries(for: documentID) {
            tocEntries = entries.map { $0.title }
        } else {
            tocEntries = []
        }

        // 4) Synthesize natural-prose chunk.
        guard let proseText = DocumentMetadataChunkSynthesizer.synthesize(
            metadata: metadata,
            documentTitle: document.title,
            tocEntries: tocEntries
        ) else {
            // Nothing meaningful to synthesize. Structured fields are
            // saved on the documents table; that's enough for future
            // library-wide queries. Just no synthetic RAG chunk.
            NotificationCenter.default.post(
                name: Self.metadataEnhancementDidComplete,
                object: nil,
                userInfo: [Self.notificationDocumentIDKey: documentID]
            )
            return
        }

        // 5) Embed the synthetic prose chunk with MiniLM specifically.
        //    The synthetic chunk is the document's metadata "beacon" —
        //    it should rank well for meta-questions like "who wrote
        //    this" or "what is this document about." MiniLM clusters
        //    those queries with their answers far better than
        //    NLEmbedding does, so we use MiniLM regardless of which
        //    embedder produced the document's content chunks. The
        //    kind tag ":syn-meta" suffix preserves the distinction;
        //    searchHybrid's per-kind grouping gives the synthetic
        //    chunk its own MiniLM-embedded query at search time.
        //
        //    If MiniLM is unavailable, fall back to the document's
        //    dominant content kind so the synthetic chunk still gets
        //    embedded (just less effectively).
        let preferredSyntheticKind = "en-minilm"
        var baseKind = preferredSyntheticKind
        var embedding = Self.embedMiniLMSync(proseText) ?? []
        if embedding.isEmpty {
            // Fallback: MiniLM unavailable. Use the dominant kind
            // from the document's content chunks.
            do {
                let chunks = try database.chunks(for: documentID)
                let contentChunks = chunks.filter { !Self.isSyntheticKind($0.embeddingKind) }
                if !contentChunks.isEmpty {
                    let kindCounts = Dictionary(
                        grouping: contentChunks, by: { $0.embeddingKind }
                    ).mapValues(\.count)
                    baseKind = kindCounts.max(by: { $0.value < $1.value })?.key
                        ?? "en-sentence"
                    embedding = Self.embedTextWithKind(text: proseText, kind: baseKind)
                } else {
                    // No content chunks yet — indexing hasn't completed.
                    NotificationCenter.default.post(
                        name: Self.metadataEnhancementDidComplete,
                        object: nil,
                        userInfo: [Self.notificationDocumentIDKey: documentID]
                    )
                    return
                }
            } catch {
                dbgLog("DocumentMetadata: chunk lookup failed: %@", "\(error)")
                return
            }
        }
        guard !embedding.isEmpty else {
            dbgLog("DocumentMetadata: embedding empty for synthesized chunk")
            return
        }

        // 6) Insert synthetic chunk into document_chunks.
        let syntheticKind = Self.syntheticMetadataKind(baseKind: baseKind)
        do {
            try database.insertSyntheticChunk(
                text: proseText,
                embedding: embedding,
                embeddingKind: syntheticKind,
                for: documentID
            )
            dbgLog("DocumentMetadata: synthetic chunk inserted for %@ (kind=%@, %d chars)",
                   document.title, syntheticKind, proseText.count)
        } catch {
            dbgLog("DocumentMetadata: synthetic chunk insert failed: %@", "\(error)")
        }

        NotificationCenter.default.post(
            name: Self.metadataEnhancementDidComplete,
            object: nil,
            userInfo: [Self.notificationDocumentIDKey: documentID]
        )
    }

    /// Embed a query string using the embedder matching `kind`.
    /// Centralizes the kind→embedder dispatch that searchHybrid /
    /// searchHybridDiagnostic / search all need, including the
    /// synthetic-metadata suffix strip so synthetic chunks of kind
    /// "en-minilm:syn-meta" get queried with MiniLM (same as their
    /// content-chunk siblings of kind "en-minilm"). Falls back to
    /// the hash embedding on embedder failure to keep cosine sane.
    static func embedQueryForKind(_ query: String, kind: String) -> [Double] {
        let baseKind = Self.baseKind(fromSyntheticKind: kind)
        if baseKind == "en-contextual" {
            if let ctx = Self.contextualEmbedder(for: .english),
               let v = Self.embedContextual(query, with: ctx) {
                return v
            }
            return Self.hashEmbedding(for: query)
        }
        if baseKind == "en-minilm" {
            return Self.embedMiniLMSync(query) ?? Self.hashEmbedding(for: query)
        }
        let language = Self.language(forKind: baseKind)
        let embedder = Self.embedder(for: language)
        return Self.embed(query, with: embedder)
    }

    /// Embed `text` using the embedder that produced chunks of `kind`.
    /// Mirrors the per-chunk embedding path used inside `rebuildIndex`.
    /// Strips the synthetic-metadata suffix before dispatching, so a
    /// kind of "en-minilm:syn-meta" is embedded with MiniLM (same as
    /// the document's content chunks). Returns empty array on
    /// embedder failure.
    static func embedTextWithKind(text: String, kind: String) -> [Double] {
        guard !text.isEmpty else { return [] }
        let baseKind = Self.baseKind(fromSyntheticKind: kind)
        if baseKind == "en-contextual" {
            if let ctx = Self.contextualEmbedder(for: .english),
               let v = Self.embedContextual(text, with: ctx) {
                return v
            }
            return Self.hashEmbedding(for: text)
        }
        if baseKind == "en-minilm" {
            if let v = Self.embedMiniLMSync(text) {
                return v
            }
            return Self.hashEmbedding(for: text)
        }
        // Default: NLEmbedding with the language inferred from kind.
        let language = Self.language(forKind: baseKind)
        let embedder = Self.embedder(for: language)
        return Self.embed(text, with: embedder)
    }

    /// Force a rebuild of the chunk index for a document. Used by
    /// re-import paths where the underlying text may have changed.
    @discardableResult
    func rebuildIndex(for documentID: UUID, plainText: String) throws -> Int {
        guard !plainText.isEmpty else { throw DocumentEmbeddingError.emptyText }

        let language = Self.detectLanguage(in: plainText)

        // 2026-05-04 — Use adaptive config (matches enqueueIndexing).
        // Without this, REINDEX_DOCUMENT and any synchronous rebuild
        // path silently double the chunk count on long documents
        // (1.6M-char EPUB went from 1829 → 3657 chunks because the
        // instance .default 500-char config was used instead of the
        // longDocument 1000-char config).
        let configuration = DocumentEmbeddingIndexConfiguration
            .adaptive(forCharacterCount: plainText.count)
        let chunks = Self.chunk(plainText, configuration: configuration)

        // 2026-05-04 Layer 2 — provider switch.
        // `Self.preferredProvider` (UserDefaults-backed) selects which
        // embedding model to use. .nlSentence is the legacy NLEmbedding
        // path (fast, low quality for retrieval). .nlContextual is the
        // BERT-based NLContextualEmbedding path (slower, evaluated for
        // retrieval quality at WWDC25). .coreMLMiniLM is reserved for
        // a bundled MiniLM CoreML model (Phase B).
        let provider = Self.preferredProvider
        let kind: String
        let embedder: NLEmbedding?
        let contextual: NLContextualEmbedding?
        switch provider {
        case .nlSentence:
            kind = Self.embeddingKind(for: language)
            embedder = Self.embedder(for: language)
            contextual = nil
        case .nlContextual:
            let ctx = Self.contextualEmbedder(for: language) ?? Self.contextualEmbedder(for: .english)
            if ctx == nil {
                dbgLog("[POSEY_ASK_POSEY] NLContextualEmbedding unavailable; falling back to NLEmbedding")
                kind = Self.embeddingKind(for: language)
                embedder = Self.embedder(for: language)
                contextual = nil
            } else {
                kind = "en-contextual"
                embedder = nil
                contextual = ctx
            }
        case .coreMLMiniLM:
            kind = "en-minilm"
            embedder = nil
            contextual = nil
        }

        var stored: [StoredDocumentChunk] = []
        stored.reserveCapacity(chunks.count)

        for chunk in chunks {
            let vector: [Double]
            switch provider {
            case .nlSentence:
                vector = Self.embed(chunk.text, with: embedder)
            case .nlContextual:
                if let ctx = contextual {
                    vector = Self.embedContextual(chunk.text, with: ctx) ?? Self.embed(chunk.text, with: embedder)
                } else {
                    vector = Self.embed(chunk.text, with: embedder)
                }
            case .coreMLMiniLM:
                if let v = Self.embedMiniLMSync(chunk.text) {
                    vector = v
                } else {
                    vector = Self.embed(chunk.text, with: embedder)
                }
            }
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
            let queryVector = Self.embedQueryForKind(query, kind: kind)
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
                dbgLog("[POSEY_ASK_POSEY] entity-index lookup failed: %@", "\(error)")
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

    /// 2026-05-04 — Hybrid retrieval. Cosine + lexical score as
    /// peers, not fallbacks. Required because NLEmbedding's
    /// `en-sentence` vectors do not differentiate well for
    /// information-retrieval queries (top scores cluster in
    /// 0.1–0.35; cosine ranking is essentially noise for short
    /// QA queries). The RAG audit (2026-05-04, see
    /// /tmp/posey-rag-audit/findings.md) verified this on three
    /// known-correct questions where the right chunk did not
    /// appear in cosine top 10.
    ///
    /// Approach:
    /// 1. Tokenize the query, drop stopwords, keep ≥3-char content
    ///    tokens.
    /// 2. For every chunk in the document, compute:
    ///    - cosine_score (0..1): standard embedding similarity.
    ///    - lexical_score (0..1): fraction of query content tokens
    ///      that appear (case-insensitive substring) in the chunk.
    /// 3. combined = max(cosine_score, lexical_score) — promotes
    ///    chunks where EITHER signal fires. Avoids the failure
    ///    mode where strong lexical match (verbatim phrase) gets
    ///    suppressed by weak cosine.
    /// 4. Sort by combined, return top `limit`.
    /// 5. (Inherited) Entity-index hits get folded in via the
    ///    existing chunkIndicesMentioningEntities path before
    ///    re-ranking.
    func searchHybrid(
        documentID: UUID,
        query: String,
        limit: Int
    ) throws -> [DocumentEmbeddingSearchResult] {
        guard !query.isEmpty else { return [] }
        let stored = try database.chunks(for: documentID)
        guard !stored.isEmpty else { return [] }

        // ── Embed the query once per kind. Chunks may be a mix of
        //   embedding kinds during a provider transition. Each kind
        //   gets its own query vector via the matching embedder.
        let kindGroups = Dictionary(grouping: stored, by: { $0.embeddingKind })
        var queryVecByKind: [String: [Double]] = [:]
        for (kind, _) in kindGroups {
            queryVecByKind[kind] = Self.embedQueryForKind(query, kind: kind)
        }

        // ── Extract content tokens (lexical query signal).
        let stopwords: Set<String> = Self.lexicalStopwords
        let rawTokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let baseTokens = rawTokens.filter { !stopwords.contains($0) && $0.count >= 3 }
        // 2026-05-14 (B4) — Lexical content tokens also receive
        // conservative singular/plural variation so a question about
        // "dogs" can match a chunk that says "dog" (and vice versa),
        // and so possessive surface forms ("Posey's") collapse to
        // their bare form for the substring scan. Common-noun queries
        // don't get NLTagger entity coverage; this is the equivalent
        // win for plain-vocabulary scoring.
        let tokenVariations = Self.expandEntityVariations(Set(baseTokens))
        let contentTokens = Array(tokenVariations)

        // ── Score every chunk.
        let queryEntities = Self.extractEntities(from: query)
        var scored: [(StoredDocumentChunk, Double, Double, Double)] = []
        scored.reserveCapacity(stored.count)
        for chunk in stored {
            let cosine: Double
            if let qVec = queryVecByKind[chunk.embeddingKind] {
                cosine = Self.cosine(qVec, chunk.embedding)
            } else {
                cosine = 0
            }
            // Lexical: fraction of query content tokens that appear
            // verbatim in the chunk text.
            let lexical: Double
            if contentTokens.isEmpty {
                lexical = 0
            } else {
                let chunkLower = chunk.text.lowercased()
                var hits = 0
                for token in contentTokens {
                    if chunkLower.contains(token) { hits += 1 }
                }
                // 2026-05-05 — Cap single-token lex matches at 0.5.
                // Without the cap, a one-content-token query like
                // "Who wrote this book?" (book is a stopword; only
                // "wrote" survives) gives lex=1.000 to every chunk
                // containing "wrote" anywhere — which dominates over
                // MiniLM cosine (the actual signal). Synthetic
                // metadata chunks lose against dozens of saturated
                // content chunks. Dividing by max(count, 2) caps
                // single-token matches at 0.5 so cosine can win.
                lexical = Double(hits) / Double(max(contentTokens.count, 2))
            }
            // Entity boost from existing index lookup gets folded in
            // separately below (we don't want to re-extract entities
            // per chunk; the index does it once at index time).
            // 2026-05-05 — Synthetic-metadata chunks get a +0.30
            // unconditional boost so they reliably surface for
            // meta-questions ("who wrote this", "what is this about")
            // even when content chunks lex-saturate on a single
            // common token. The boost is bounded so synthetic chunks
            // don't dominate questions that are about content rather
            // than metadata — they still need a real cosine signal.
            var combined = max(cosine, lexical)
            if Self.isSyntheticKind(chunk.embeddingKind) {
                // 0.40 chosen empirically: enough to beat the
                // single-token-lex-saturated content noise floor
                // (capped at 0.50), but small enough that synthetic
                // chunks don't crowd out genuine content chunks for
                // content-flavored questions (where content chunks
                // score 0.55+ via multi-token lex or strong cosine).
                combined = min(1.0, combined + 0.40)
            }
            scored.append((chunk, cosine, lexical, combined))
        }

        // ── Entity-index lookup for question-side entities. Boosts
        //   chunks that contain any of those entities.
        //
        // 2026-05-14 (B4) — Entity-variation expansion (Hal pattern).
        // Before hitting the entity index, expand each entity to
        // common English surface variations (singular/plural,
        // possessive, hyphen-collapse). Lets a question about
        // "cake" pick up chunks that say "cakes" or "cake's";
        // a question about "rabbit-hole" picks up "rabbit hole".
        // The expansion is conservative — see
        // `expandEntityVariations` doc for the exact rules.
        let expandedEntities = Self.expandEntityVariations(queryEntities)
        let queryEntitiesArray = Array(expandedEntities)
        if !queryEntitiesArray.isEmpty {
            do {
                let mentioned = try database.chunkIndicesMentioningEntities(
                    documentID: documentID,
                    entitiesLower: queryEntitiesArray
                )
                if !mentioned.isEmpty {
                    let mset = Set(mentioned)
                    for i in 0..<scored.count where mset.contains(scored[i].0.chunkIndex) {
                        // Lift the combined score by the entity bonus
                        // (additive, capped at 1.0).
                        scored[i].3 = min(1.0, scored[i].3 + 0.4)
                    }
                }
            } catch {
                dbgLog("[POSEY_ASK_POSEY] entity-index lookup failed: %@", "\(error)")
            }
        }

        // ── Sort by combined, then dedup by vector similarity before
        //   taking the top `limit`.
        //
        // 2026-05-14 (B5) — Content-dedup before top-N selection
        // (Hal pattern). Long documents frequently contain near-
        // identical passages: reprinted excerpts, recurring section
        // boilerplate, or chunk-overlap zones where the same
        // sentence lands in two consecutive chunks. If both make it
        // to the top-K, AFM sees the same content twice in the
        // injected context and we wasted token budget that could
        // have carried a distinct supporting passage.
        //
        // Dedup walks the sorted candidate list and drops any
        // chunk whose embedding cosine ≥ 0.92 against an already-
        // accepted chunk's embedding. 0.92 is "this is essentially
        // the same passage with minor wording differences"; <0.85
        // is "related but distinct content."
        //
        // We oversample the pre-dedup pool to 3× the requested
        // limit so dedup has headroom to drop near-dupes without
        // starving the final top-K of distinct content. The
        // dropped-similarity threshold is kept in code (not a
        // user setting) — too low and good distinct chunks get
        // collapsed; too high and dedup becomes a no-op.
        let sorted = scored.sorted { $0.3 > $1.3 }
        let dedupPool = Array(sorted.prefix(limit * 3))
        let dedupedChunks = Self.dedupBySimilarity(
            dedupPool, threshold: 0.92, take: limit
        )
        let top = dedupedChunks.map { (chunk, _, _, combined) in
            DocumentEmbeddingSearchResult(chunk: chunk, similarity: combined)
        }
        return top
    }

    /// 2026-05-14 (B5) — Greedy dedup over already-sorted candidates.
    ///
    /// Walks the candidate list in score order (highest first),
    /// accepting each chunk unless its embedding cosine against any
    /// already-accepted chunk's embedding meets or exceeds
    /// `threshold`. The first instance of a near-duplicate wins;
    /// later instances are dropped.
    ///
    /// `take` is the requested final size; iteration stops as soon
    /// as we've accepted `take` chunks. The caller is responsible
    /// for oversampling the input to leave headroom for dropped
    /// near-dupes.
    ///
    /// Threshold 0.92 corresponds to "essentially the same passage."
    /// 0.85+ is "closely related." Below ~0.7 is "different topics."
    static func dedupBySimilarity(
        _ scored: [(StoredDocumentChunk, Double, Double, Double)],
        threshold: Double,
        take: Int
    ) -> [(StoredDocumentChunk, Double, Double, Double)] {
        guard take > 0, !scored.isEmpty else { return [] }
        var accepted: [(StoredDocumentChunk, Double, Double, Double)] = []
        accepted.reserveCapacity(take)
        for candidate in scored {
            if accepted.count >= take { break }
            // 2026-05-14 — Synthetic-metadata chunks (title-page
            // distillations) bypass dedup entirely. They're short,
            // their embeddings live in a separate :syn-meta kind
            // band, and their content is the doc's title beacon
            // which the anti-fabrication entity check relies on to
            // ground answers about the work itself. Letting them be
            // deduped against content chunks broke "what is this
            // book?" by dropping the only chunk that named the
            // title.
            if isSyntheticKind(candidate.0.embeddingKind) {
                accepted.append(candidate)
                continue
            }
            var isDuplicate = false
            for already in accepted {
                // Skip cross-kind comparisons — vectors from
                // different embedding kinds don't share a meaningful
                // similarity scale. Dedup only applies within a
                // kind family.
                guard candidate.0.embeddingKind == already.0.embeddingKind else {
                    continue
                }
                let sim = cosine(candidate.0.embedding, already.0.embedding)
                if sim >= threshold {
                    isDuplicate = true
                    break
                }
            }
            if !isDuplicate { accepted.append(candidate) }
        }
        return accepted
    }

    // ========== BLOCK 03b: HYBRID SEARCH DIAGNOSTIC - START ==========

    /// Diagnostic-only search result with the score decomposition that
    /// `searchHybrid` collapses into a single `similarity` value. Used
    /// by the `RAG_TRACE` local-API verb to investigate retrieval
    /// quality, chunking, and "why didn't it find that?" questions.
    nonisolated struct DiagnosticResult: Sendable {
        let chunk: StoredDocumentChunk
        /// Raw cosine similarity, query-vector against chunk-vector, in
        /// [-1, 1]. For sentence embeddings on related text typically
        /// [0, 1].
        let cosine: Double
        /// Fraction of non-stopword content tokens from the query that
        /// appear (substring, case-insensitive) anywhere in the chunk
        /// text. Range [0, 1].
        let lexical: Double
        /// True if the entity index flagged this chunk as containing a
        /// named entity from the query.
        let entityBoosted: Bool
        /// Final ranking score: `max(cosine, lexical)`, plus 0.4
        /// (capped at 1.0) when `entityBoosted` is true. This is the
        /// single value `searchHybrid` returns as `similarity`.
        let combined: Double
        /// Rank among ALL chunks for this query (0-based, after sort).
        /// Tells you "the answer chunk was retrievable but it sat at
        /// rank 23 — beyond the top-K cutoff" vs "it was rank 0 but
        /// the budget filter cut it" vs "it scored zero."
        let rank: Int
    }

    /// Diagnostic mirror of `searchHybrid` that returns the score
    /// decomposition for every chunk in the document. The scoring
    /// path here is byte-equivalent to `searchHybrid` — if you change
    /// scoring, change both. Returns ranked descending by `combined`.
    ///
    /// Not for production use. Wired to the `RAG_TRACE` local-API
    /// verb in DEBUG builds.
    func searchHybridDiagnostic(
        documentID: UUID,
        query: String
    ) throws -> [DiagnosticResult] {
        guard !query.isEmpty else { return [] }
        let stored = try database.chunks(for: documentID)
        guard !stored.isEmpty else { return [] }

        // Embed query per kind — same logic path as searchHybrid.
        let kindGroups = Dictionary(grouping: stored, by: { $0.embeddingKind })
        var queryVecByKind: [String: [Double]] = [:]
        for (kind, _) in kindGroups {
            queryVecByKind[kind] = Self.embedQueryForKind(query, kind: kind)
        }

        // Lexical tokens — same filtering as searchHybrid.
        let stopwords = Self.lexicalStopwords
        let rawTokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let baseTokens = rawTokens.filter { !stopwords.contains($0) && $0.count >= 3 }
        // 2026-05-14 (B4) — singular/plural expansion on lexical
        // tokens too. Matches searchHybrid.
        let contentTokens = Array(Self.expandEntityVariations(Set(baseTokens)))

        // Entity-index hits. 2026-05-14 (B4): expand entities to
        // surface variations before lookup, matching searchHybrid.
        let queryEntities = Self.extractEntities(from: query)
        var entityChunkIndices: Set<Int> = []
        if !queryEntities.isEmpty {
            let expanded = Self.expandEntityVariations(queryEntities)
            let mentioned = (try? database.chunkIndicesMentioningEntities(
                documentID: documentID,
                entitiesLower: Array(expanded))) ?? []
            entityChunkIndices = Set(mentioned)
        }

        // Score every chunk with the same arithmetic as searchHybrid.
        var scored: [DiagnosticResult] = []
        scored.reserveCapacity(stored.count)
        for chunk in stored {
            let cosine: Double
            if let qVec = queryVecByKind[chunk.embeddingKind] {
                cosine = Self.cosine(qVec, chunk.embedding)
            } else {
                cosine = 0
            }
            let lexical: Double
            if contentTokens.isEmpty {
                lexical = 0
            } else {
                let chunkLower = chunk.text.lowercased()
                var hits = 0
                for token in contentTokens where chunkLower.contains(token) { hits += 1 }
                // 2026-05-05 — Cap single-token lex matches at 0.5.
                // Without the cap, a one-content-token query like
                // "Who wrote this book?" (book is a stopword; only
                // "wrote" survives) gives lex=1.000 to every chunk
                // containing "wrote" anywhere — which dominates over
                // MiniLM cosine (the actual signal). Synthetic
                // metadata chunks lose against dozens of saturated
                // content chunks. Dividing by max(count, 2) caps
                // single-token matches at 0.5 so cosine can win.
                lexical = Double(hits) / Double(max(contentTokens.count, 2))
            }
            let entityBoosted = entityChunkIndices.contains(chunk.chunkIndex)
            var combined = max(cosine, lexical)
            if entityBoosted { combined = min(1.0, combined + 0.4) }
            // 2026-05-05 — Synthetic-metadata chunk boost (matches
            // searchHybrid). Keep both code paths in sync.
            if Self.isSyntheticKind(chunk.embeddingKind) {
                // 0.40 chosen empirically: enough to beat the
                // single-token-lex-saturated content noise floor
                // (capped at 0.50), but small enough that synthetic
                // chunks don't crowd out genuine content chunks for
                // content-flavored questions (where content chunks
                // score 0.55+ via multi-token lex or strong cosine).
                combined = min(1.0, combined + 0.40)
            }
            scored.append(DiagnosticResult(
                chunk: chunk,
                cosine: cosine,
                lexical: lexical,
                entityBoosted: entityBoosted,
                combined: combined,
                rank: 0
            ))
        }

        // Sort descending and assign rank.
        let sorted = scored.sorted { $0.combined > $1.combined }
        return sorted.enumerated().map { (i, r) in
            DiagnosticResult(
                chunk: r.chunk,
                cosine: r.cosine,
                lexical: r.lexical,
                entityBoosted: r.entityBoosted,
                combined: r.combined,
                rank: i
            )
        }
    }

    // ========== BLOCK 03b: HYBRID SEARCH DIAGNOSTIC - END ==========

    /// Stopwords used for lexical query tokenization. Conservative —
    /// includes function words and common pronouns/auxiliaries plus
    /// generic "ask about a doc" verbs that don't carry signal.
    static let lexicalStopwords: Set<String> = [
        "the","is","are","was","were","be","been","being",
        "of","in","on","at","to","for","with","from","by",
        "and","or","but","not","no","nor","so",
        "this","that","these","those","its","their","there","here",
        "what","who","where","when","why","how","which",
        "does","did","doing","done","has","have","had",
        "tell","told","say","said","ask","asked",
        "you","your","yours","our","ours",
        "about","please","also","too","any","some","all",
        "can","could","would","should","will","may","might","must",
        "mention","mentioned","mentions","discuss","discussed","discusses",
        "explain","explains","explained","describe","describes","described",
        "give","gave","given","show","shows","showed","shown",
        "yes","yeah","ok","okay","thanks","thank",
        "book","document","article","paper","text","chapter",
        "passage","section","page","story",
        "thing","things","stuff","kind","type","sort","way",
        "really","very","much","many","more","less",
        "good","bad","well","right","wrong","fine"
    ]

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

    /// 2026-05-14 (B4) — Conservative entity-variation expansion.
    ///
    /// Hal-style query-side expansion: for each entity in the
    /// query, add common English variations so the entity-index
    /// lookup catches chunks that mention the same entity in a
    /// different surface form (singular/plural, possessive).
    ///
    /// The risk is over-expansion: aggressive rules pull unrelated
    /// chunks (e.g., `rate → rates → rated → rating`). This
    /// implementation is deliberately narrow:
    /// - Original token is always kept.
    /// - Add `+s` plural for any entity ≥ 4 chars not ending in `s`,
    ///   `sh`, `ch`, `x`, or `z`.
    /// - Add `+es` for words ending in `s`, `sh`, `ch`, `x`, `z`.
    /// - Add `+'s` possessive for any entity ≥ 3 chars.
    /// - Strip trailing `'s` / `'` to add the bare base form when
    ///   present (catches `"Alice's"` → `alice`).
    /// - Skip if the entity is already a known plural (ends in `s`
    ///   AND base form without `s` is ≥ 3 chars; both forms get
    ///   added so the lookup catches either).
    /// - Hyphen-collapse: `"rabbit-hole"` → also try `rabbithole`
    ///   and `rabbit hole`.
    ///
    /// Returns the union of all surface forms, lowercased.
    static func expandEntityVariations(_ entitiesLower: Set<String>) -> Set<String> {
        var out = Set<String>()
        for raw in entitiesLower {
            let e = raw.lowercased()
            guard !e.isEmpty else { continue }
            out.insert(e)

            // Strip trailing 's / ' possessive marker.
            if e.hasSuffix("'s") && e.count >= 4 {
                out.insert(String(e.dropLast(2)))
            } else if e.hasSuffix("'") && e.count >= 3 {
                out.insert(String(e.dropLast(1)))
            }

            // Singular ⇄ plural pivot from the bare base form.
            let bare: String = {
                if e.hasSuffix("'s") { return String(e.dropLast(2)) }
                if e.hasSuffix("'")  { return String(e.dropLast(1)) }
                return e
            }()

            if bare.count >= 3, !bare.hasSuffix("s") {
                if bare.hasSuffix("sh") || bare.hasSuffix("ch")
                    || bare.hasSuffix("x") || bare.hasSuffix("z") {
                    out.insert(bare + "es")
                } else {
                    out.insert(bare + "s")
                }
            }
            // Plural → singular (drop trailing s when the remaining
            // base is at least 3 chars). Conservative: don't apply
            // when bare ends in "ss" (boss / mess), "us" (cactus),
            // or "is" (analysis / basis) — these don't trim cleanly
            // with a single -s rule.
            if bare.hasSuffix("s") && bare.count >= 4 {
                let stem = String(bare.dropLast())
                let suspiciousEnd = stem.hasSuffix("s") || stem.hasSuffix("u") || stem.hasSuffix("i")
                if !suspiciousEnd { out.insert(stem) }
            }

            // Possessive form (add only when not present and base is
            // a likely noun — we already gate by NLTagger name types
            // upstream, so this is just a surface-form variation).
            if bare.count >= 3 {
                out.insert(bare + "'s")
            }

            // Hyphen-collapse variations.
            if bare.contains("-") {
                out.insert(bare.replacingOccurrences(of: "-", with: ""))
                out.insert(bare.replacingOccurrences(of: "-", with: " "))
            }
        }
        return out
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
    ///
    /// 2026-05-05 — Replaced blind character-window chunking with
    /// sentence-aware chunking modeled on Hal's MENTAT strategy
    /// (Hal.swift:9275). NLTokenizer(unit: .sentence) enumerates
    /// sentence boundaries; chunks accumulate whole sentences until
    /// `chunkSize` is reached, then emit. Overlap is sentence-granular
    /// (whole sentences from the tail of the previous chunk seed the
    /// next), not character-granular. Side benefits:
    /// - Comparative statements like "Litigation is more time-consuming
    ///   than ADR" never get split mid-clause; AFM sees the full
    ///   sentence with both subjects intact.
    /// - Antecedents like "This is generally an advantage" are bounded
    ///   by the same chunk as their referent ("Litigation takes longer
    ///   than ADR"), reducing pronoun-resolution failures across chunk
    ///   boundaries.
    /// - The chunk text remains a meaningful prose unit, not a
    ///   character window that happens to contain partial sentences.
    ///
    /// `startOffset` / `endOffset` are still character offsets in the
    /// ORIGINAL `text` (not in the cleaned chunk), preserving the
    /// existing contract that downstream code uses for jump-to-passage,
    /// dedup, and the document_chunks schema.
    ///
    /// Edge cases preserved:
    /// - Empty text → empty array.
    /// - Sentence longer than chunkSize → emitted as its own chunk
    ///   anyway (boundary integrity > size cap; truncating a sentence
    ///   defeats the purpose).
    /// - NLTokenizer detects 0 sentences (single very long string with
    ///   no terminators, code blob, hex dump) → fall back to legacy
    ///   character-window chunking.
    static func chunk(
        _ text: String,
        configuration: DocumentEmbeddingIndexConfiguration
    ) -> [DocumentEmbeddingChunk] {
        let chunkSize = configuration.chunkSize
        let overlap   = configuration.chunkOverlap
        precondition(chunkSize > 0, "chunkSize must be positive")
        precondition(overlap >= 0 && overlap < chunkSize, "overlap must be in [0, chunkSize)")

        if text.isEmpty { return [] }

        // ── Step 1: Enumerate sentence boundaries.
        // Track running character offset alongside the String.Index
        // walk so we don't pay O(N) for every distance() call. The
        // tokenizer enumerates in order, so each sentence's start is
        // ≥ the previous sentence's end — we walk forward only.
        var sentenceRanges: [(start: Int, end: Int)] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var cursor = text.startIndex
        var cursorOffset = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Walk from cursor → range.lowerBound, accumulating chars.
            if range.lowerBound != cursor {
                cursorOffset += text.distance(from: cursor, to: range.lowerBound)
                cursor = range.lowerBound
            }
            let startOffset = cursorOffset
            // Walk from cursor → range.upperBound.
            cursorOffset += text.distance(from: cursor, to: range.upperBound)
            cursor = range.upperBound
            let endOffset = cursorOffset
            // Skip empty / whitespace-only sentences (NLTokenizer
            // doesn't usually emit these but be defensive).
            if endOffset > startOffset {
                sentenceRanges.append((start: startOffset, end: endOffset))
            }
            return true
        }

        // ── Step 2: If sentence detection failed (no sentences at all,
        //   or only one giant sentence with no terminators), fall back
        //   to the legacy character-window strategy. Hal does this same
        //   fallback (createWordBasedChunks); we use character windows
        //   for parity with prior behavior on edge-case inputs.
        if sentenceRanges.isEmpty {
            return Self.chunkByCharacterWindow(
                text: text, chunkSize: chunkSize, overlap: overlap)
        }

        // ── Step 3: Accumulate sentences into chunks bounded by
        //   chunkSize. Sentence-granular overlap.
        var chunks: [DocumentEmbeddingChunk] = []
        var currentSentences: [(start: Int, end: Int)] = []
        var chunkIndex = 0

        // Helper: span size of currentSentences in the original text.
        //   Span runs from the first sentence's start to the last
        //   sentence's end, INCLUDING inter-sentence whitespace —
        //   that's what AFM will see, so that's what we measure.
        func currentSpan() -> Int {
            guard let first = currentSentences.first,
                  let last  = currentSentences.last else { return 0 }
            return last.end - first.start
        }

        // Helper: emit currentSentences as one chunk, then seed the
        //   next chunk with the trailing sentences of the previous
        //   that fit within `overlap` characters.
        func emitChunkAndOverlap() {
            guard let first = currentSentences.first,
                  let last  = currentSentences.last else { return }
            let startOff = first.start
            let endOff   = last.end
            let lower = text.index(text.startIndex, offsetBy: startOff)
            let upper = text.index(text.startIndex, offsetBy: endOff)
            let slice = String(text[lower..<upper])
            // Same per-chunk sanitization as before — strips Wayback
            // Machine print headers, dot-leader runs, trailing page
            // numbers from short lines. Preserves prose untouched.
            let cleaned = Self.sanitizeChunkText(slice)
            chunks.append(DocumentEmbeddingChunk(
                chunkIndex: chunkIndex,
                startOffset: startOff,
                endOffset: endOff,
                text: cleaned
            ))
            chunkIndex += 1

            // Seed next chunk with trailing sentences as overlap.
            // Walk currentSentences from the END, accumulating
            // sentences whose total span (last.end - candidate.start)
            // ≤ overlap. Skip the LAST sentence — including it would
            // make the next chunk identical to this one if no further
            // sentences arrive. We want overlap to be "context for the
            // next chunk's first new sentence," not a duplicate of the
            // previous emit.
            var seed: [(start: Int, end: Int)] = []
            if currentSentences.count >= 2 {
                let referenceEnd = last.end
                for s in currentSentences.dropLast().reversed() {
                    let prospective = referenceEnd - s.start
                    if prospective <= overlap {
                        seed.insert(s, at: 0)
                    } else {
                        break
                    }
                }
            }
            currentSentences = seed
        }

        for sentence in sentenceRanges {
            // If this single sentence already exceeds chunkSize, emit
            // any pending chunk first, then emit the long sentence
            // as its own chunk. Boundary integrity wins over size cap.
            if sentence.end - sentence.start > chunkSize {
                if !currentSentences.isEmpty {
                    emitChunkAndOverlap()
                }
                currentSentences = [sentence]
                emitChunkAndOverlap()
                continue
            }
            // Compute the prospective span if we add this sentence.
            // Use the FIRST sentence's start (or this sentence's start
            // when currentSentences is empty) as the start anchor.
            let prospectiveStart = currentSentences.first?.start ?? sentence.start
            let prospectiveSpan  = sentence.end - prospectiveStart
            if prospectiveSpan <= chunkSize || currentSentences.isEmpty {
                currentSentences.append(sentence)
            } else {
                // Adding this sentence would exceed chunkSize. Emit
                // what we have, then start fresh (with overlap seed)
                // and add this sentence.
                emitChunkAndOverlap()
                currentSentences.append(sentence)
            }
            // Defensive: if even after appending we somehow have a
            // span exceeding chunkSize (overlap seed pushed us past
            // it), emit immediately.
            if currentSpan() >= chunkSize {
                emitChunkAndOverlap()
            }
        }

        // Final flush.
        if !currentSentences.isEmpty {
            emitChunkAndOverlap()
        }

        return chunks
    }

    /// Legacy character-window chunking, retained as the fallback for
    /// inputs where sentence detection fails (no terminators, single
    /// giant token). Preserves the original 2026-05-04 sanitization
    /// behavior. Most documents never hit this path.
    private static func chunkByCharacterWindow(
        text: String,
        chunkSize: Int,
        overlap: Int
    ) -> [DocumentEmbeddingChunk] {
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
            let cleaned = Self.sanitizeChunkText(slice)
            chunks.append(DocumentEmbeddingChunk(
                chunkIndex: index,
                startOffset: start,
                endOffset: end,
                text: cleaned
            ))
            index += 1
            if end == total { break }
            start = max(start + chunkSize - overlap, start + 1)
        }
        return chunks
    }

    /// Per-chunk sanitization run at index time.
    /// - Strips Wayback Machine print-header artifacts.
    /// - Strips TOC noise (trailing page numbers from short lines,
    ///   dot-leader runs of 2+ consecutive periods).
    /// - Leaves prose untouched.
    /// The trailing-page-number strip is intentionally narrow: only
    /// fires on lines ≤ 100 chars whose last token is purely digits
    /// preceded by a content word. Prose ending with a year ("…in
    /// 2024.") doesn't trip because the period after the digits is
    /// a sentence terminator, not a page marker.
    static func sanitizeChunkText(_ text: String) -> String {
        var result = text
        // (a) Wayback Machine print headers.
        if result.contains("Wayback") || result.contains("web.archive.org") {
            result = TextNormalizer.stripWaybackPrintHeaders(result)
        }
        // (b) Dot-leader runs: replace "...." (2+ consecutive periods)
        //     with a single space. Done before page-number strip so
        //     "Section 1: Watch App Bugs.... 17" → "Section 1: Watch
        //     App Bugs 17" → "Section 1: Watch App Bugs".
        if result.contains("..") {
            if let regex = try? NSRegularExpression(pattern: #"\.{2,}"#, options: []) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result, range: range, withTemplate: " ")
            }
        }
        // (c) Trailing page numbers on short lines. Process line-by-
        //     line so multi-paragraph prose isn't touched.
        if result.contains("\n") {
            let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
            let cleanedLines: [Substring] = lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count <= 100 else { return line }
                guard let last = trimmed.last, last.isNumber else { return line }
                // Walk back through trailing digits + tab/spaces.
                var i = trimmed.endIndex
                while i > trimmed.startIndex {
                    let prev = trimmed.index(before: i)
                    if trimmed[prev].isNumber || trimmed[prev] == " " || trimmed[prev] == "\t" {
                        i = prev
                    } else {
                        break
                    }
                }
                let prefix = trimmed[..<i].trimmingCharacters(in: CharacterSet(charactersIn: " .\t-—"))
                let prefixLetters = prefix.filter { $0.isLetter }.count
                // Only strip if there's substantive prose before the
                // page number (avoid stripping legitimate "Total: 5"
                // style lines that happen to end with a number).
                guard prefixLetters >= 4 else { return line }
                // Recover original whitespace-prefix of the line.
                let leading = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                return Substring(leading + prefix)
            }
            result = cleanedLines.joined(separator: "\n")
        }
        return result
    }

    /// Heuristic: is this chunk dominated by Table-of-Contents text,
    /// appendix listings, or other non-prose artifacts that should
    /// not be embedded for retrieval? Multi-signal — real prose rarely
    /// trips ≥2 signals, and very strong single signals (dense
    /// dot-leaders, dense lettered lists, near-pure digit/short-token
    /// content) can trip on their own.
    static func chunkIsMostlyTOC(_ text: String) -> Bool {
        let n = text.count
        guard n >= 120 else { return false } // too small to judge
        // Count alpha and digit characters.
        var letters = 0
        var digits = 0
        var newlines = 0
        for ch in text {
            if ch.isLetter { letters += 1 }
            else if ch.isNumber { digits += 1 }
            else if ch.isNewline { newlines += 1 }
        }
        guard letters > 0 else { return true } // pure numbers — definitely junk
        let digitRatio = Double(digits) / Double(letters)
        let linesPerKChar = Double(newlines) * 1000.0 / Double(n)

        // Signal A: lots of digits relative to letters (TOC page numbers).
        let signalA = digitRatio > 0.06
        // Signal B: lots of newlines (short TOC entries).
        let signalB = linesPerKChar > 12.0
        // Signal C: trailing-page-number patterns line by line.
        let signalC: Bool = {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            var hits = 0
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                guard line.count <= 100 else { continue }
                guard let last = line.last, last.isNumber else { continue }
                var i = line.endIndex
                while i > line.startIndex {
                    let prev = line.index(before: i)
                    if line[prev].isNumber { i = prev } else { break }
                }
                let prefix = line[..<i].trimmingCharacters(in: CharacterSet(charactersIn: " .\t-—"))
                let prefixLetters = prefix.filter { $0.isLetter }.count
                if prefixLetters >= 3 { hits += 1 }
            }
            return hits >= 5
        }()
        // Signal D: dense dot-leader runs (PDF inline TOC like
        // "C. my.mp3.com.. 11 D. Beam-it™. 12 E. User Identification 13").
        // Count runs of 2+ consecutive dots.
        let signalD: Bool = {
            var runs = 0
            var i = text.startIndex
            while i < text.endIndex {
                if text[i] == "." {
                    var j = text.index(after: i)
                    var runLen = 1
                    while j < text.endIndex, text[j] == "." {
                        runLen += 1
                        j = text.index(after: j)
                    }
                    if runLen >= 2 { runs += 1 }
                    i = j
                } else {
                    i = text.index(after: i)
                }
            }
            return runs >= 4
        }()
        // Signal E: dense lettered/numbered-list density — patterns
        // like "A. Internet 6 B. mp3 9 C. my.mp3.com .. 11" or
        // "I. Introduction... 3 II. Technology...".
        // Count "<single uppercase letter or 1-3 roman numeral>."
        // followed by space.
        let signalE: Bool = {
            var hits = 0
            let chars = Array(text)
            var i = 0
            while i < chars.count - 2 {
                let c = chars[i]
                let isUpper = c.isUppercase && c.isLetter
                let isRoman = "IVXLCDM".contains(c)
                if (isUpper || isRoman),
                   chars[i+1] == "." {
                    let after = chars[i+2]
                    if after == " " || after == "\t" {
                        // Confirm we're at a token boundary (preceded by
                        // start, space, newline, or another item separator).
                        let isBoundary: Bool = {
                            if i == 0 { return true }
                            let p = chars[i-1]
                            return p == " " || p == "\t" || p.isNewline || p == "."
                        }()
                        if isBoundary { hits += 1 }
                    }
                }
                i += 1
            }
            return hits >= 5
        }()
        // Signal F: appendix-listing pattern (EPUB front-matter).
        // "Appendix Heth: Property and Priviledge Appendix Cheth: ..."
        // — same word repeating at short intervals.
        let signalF: Bool = {
            let lower = text.lowercased() as NSString
            // Common front-matter listing prefixes.
            let prefixes = ["appendix ", "chapter ", "part ", "book ", "section "]
            for prefix in prefixes {
                var count = 0
                var searchRange = NSRange(location: 0, length: lower.length)
                while searchRange.length > 0 {
                    let r = lower.range(of: prefix, options: [.literal], range: searchRange)
                    if r.location == NSNotFound { break }
                    count += 1
                    if count >= 4 { return true }
                    let next = r.location + r.length
                    searchRange = NSRange(location: next, length: lower.length - next)
                }
            }
            return false
        }()

        let strongSignals = (signalA ? 1 : 0) + (signalB ? 1 : 0)
            + (signalC ? 1 : 0) + (signalD ? 1 : 0)
            + (signalE ? 1 : 0) + (signalF ? 1 : 0)
        if strongSignals >= 2 { return true }
        // Very-strong single signals (catch single-line PDF TOCs and
        // dense lettered lists that don't trip newline-based signals).
        if digitRatio > 0.12 && (signalD || signalE) { return true }
        if signalE && signalD { return true }
        if signalF { return true }   // appendix-listing alone is enough
        return false
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
                dbgLog("AskPosey citation: best=[%d]:%.2f %@ sentence='%@'",
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

    // MARK: - Embedding provider (Layer 2)

    /// Selectable embedding model. UserDefaults-backed so the
    /// running app can switch providers without a rebuild.
    enum EmbeddingProvider: String, Sendable, CaseIterable {
        case nlSentence    // Apple NLEmbedding (legacy, fast, weak retrieval)
        case nlContextual  // Apple NLContextualEmbedding (BERT, slower)
        case coreMLMiniLM  // CoreML MiniLM (Phase B — bundled .mlpackage)

        static let userDefaultsKey = "Posey.AskPosey.embeddingProvider"
    }

    /// The provider used for new indexing and query embedding.
    /// Default: .coreMLMiniLM (Phase B winner per 2026-05-04 RAG audit:
    /// 18/24 = 75% clean rate on non-fiction vs. NLEmbedding's 16/24
    /// = 67%; NLContextualEmbedding's 15/24 = 63%). The MiniLM model
    /// (`MiniLML6v2.mlpackage`, 43MB fp16) ships bundled with the app.
    static var preferredProvider: EmbeddingProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: EmbeddingProvider.userDefaultsKey)
                ?? EmbeddingProvider.coreMLMiniLM.rawValue
            return EmbeddingProvider(rawValue: raw) ?? .coreMLMiniLM
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: EmbeddingProvider.userDefaultsKey)
        }
    }

    // MARK: - NLContextualEmbedding (Layer 2)

    /// Cached contextual embedder per language. NLContextualEmbedding
    /// is BERT-based, expensive to construct, and benefits hugely
    /// from being kept warm across queries / chunks.
    @MainActor
    private static var contextualCache: [String: NLContextualEmbedding] = [:]

    /// 2026-05-04 — Layer 2 RAG fix.
    /// Build (or fetch cached) `NLContextualEmbedding` for `language`.
    /// `NLContextualEmbedding` is Apple's BERT-based contextual model
    /// (iOS 17+). Apple recommends it over `NLEmbedding` for retrieval
    /// per WWDC25. First call downloads the model (~500MB); subsequent
    /// calls are cached. Returns nil if the model is unavailable or
    /// fails to load.
    nonisolated static func contextualEmbedder(for language: NLLanguage) -> NLContextualEmbedding? {
        guard let model = NLContextualEmbedding(language: language) else {
            return nil
        }
        if !model.hasAvailableAssets {
            do {
                try model.requestAssets { _, _ in }
            } catch {
                dbgLog("[POSEY_ASK_POSEY] NLContextualEmbedding requestAssets failed: %@", "\(error)")
                return nil
            }
        }
        if !model.hasAvailableAssets {
            // Assets requested but not yet downloaded.
            return nil
        }
        do {
            try model.load()
        } catch {
            dbgLog("[POSEY_ASK_POSEY] NLContextualEmbedding.load failed: %@", "\(error)")
            return nil
        }
        return model
    }

    /// Synchronous bridge to `MiniLMEmbedder.shared.embed(_:)`. The
    /// embedder is `@MainActor`-isolated; indexing runs on a
    /// background queue. We dispatch sync to main, accepting the
    /// stall — chunk-level inference is fast (~5-15ms) and indexing
    /// already serializes on a background queue per document.
    nonisolated static func embedMiniLMSync(_ text: String) -> [Double]? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { MiniLMEmbedder.shared.embed(text) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { MiniLMEmbedder.shared.embed(text) }
        }
    }

    /// Embed `text` via NLContextualEmbedding and mean-pool the token
    /// vectors into a single chunk-level vector. Returns nil on
    /// failure so callers can fall back to NLEmbedding.
    nonisolated static func embedContextual(
        _ text: String,
        with embedder: NLContextualEmbedding?
    ) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let embedder, !trimmed.isEmpty else { return nil }
        do {
            let result = try embedder.embeddingResult(for: trimmed, language: nil)
            let dim = embedder.dimension
            var sum = [Double](repeating: 0, count: dim)
            var count = 0
            result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vec, _ in
                if vec.count == dim {
                    for i in 0..<dim { sum[i] += vec[i] }
                    count += 1
                }
                return true
            }
            guard count > 0 else { return nil }
            let inv = 1.0 / Double(count)
            for i in 0..<dim { sum[i] *= inv }
            return sum
        } catch {
            dbgLog("[POSEY_ASK_POSEY] embedContextual failed: %@", "\(error)")
            return nil
        }
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
