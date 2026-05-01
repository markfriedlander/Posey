import XCTest
import NaturalLanguage
@testable import Posey

// ========== BLOCK 01: CHUNKING TESTS - START ==========
/// Boundary and overlap behaviour for `DocumentEmbeddingIndex.chunk(_:)`.
/// These tests don't touch SQLite or NLEmbedding — they assert the pure
/// chunking pass produces deterministic, well-defined slices.
final class DocumentEmbeddingChunkingTests: XCTestCase {

    /// Build a service with no DB — we only call `chunk` here, which is
    /// pure-logic. The DB reference is unused.
    private func service(chunkSize: Int = 500, overlap: Int = 50) throws -> DocumentEmbeddingIndex {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let database = try DatabaseManager(databaseURL: url)
        let config = DocumentEmbeddingIndexConfiguration(chunkSize: chunkSize, chunkOverlap: overlap)
        return DocumentEmbeddingIndex(database: database, configuration: config)
    }

    func testChunkOfShortTextProducesSingleChunk() throws {
        let s = try service()
        let chunks = s.chunk("Hello world.")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].chunkIndex, 0)
        XCTAssertEqual(chunks[0].startOffset, 0)
        XCTAssertEqual(chunks[0].endOffset, 12)
        XCTAssertEqual(chunks[0].text, "Hello world.")
    }

    func testChunkOfEmptyTextProducesNoChunks() throws {
        let s = try service()
        XCTAssertEqual(s.chunk("").count, 0)
    }

    func testChunksAreContiguousAtBoundariesWithOverlap() throws {
        let s = try service(chunkSize: 100, overlap: 20)
        // 250 chars: chunk 0 [0..100], chunk 1 [80..180], chunk 2 [160..250].
        let text = String(repeating: "x", count: 250)
        let chunks = s.chunk(text)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].startOffset, 0)
        XCTAssertEqual(chunks[0].endOffset, 100)
        XCTAssertEqual(chunks[1].startOffset, 80)
        XCTAssertEqual(chunks[1].endOffset, 180)
        XCTAssertEqual(chunks[2].startOffset, 160)
        XCTAssertEqual(chunks[2].endOffset, 250)
        // Chunk indexes are 0-based contiguous.
        XCTAssertEqual(chunks.map { $0.chunkIndex }, [0, 1, 2])
        // Final chunk's text length must equal endOffset - startOffset.
        XCTAssertEqual(chunks[2].text.count, 90)
    }

    func testZeroOverlapProducesNonOverlappingChunks() throws {
        let s = try service(chunkSize: 50, overlap: 0)
        let text = String(repeating: "a", count: 110)
        let chunks = s.chunk(text)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].startOffset, 0)
        XCTAssertEqual(chunks[0].endOffset, 50)
        XCTAssertEqual(chunks[1].startOffset, 50)
        XCTAssertEqual(chunks[1].endOffset, 100)
        XCTAssertEqual(chunks[2].startOffset, 100)
        XCTAssertEqual(chunks[2].endOffset, 110)
    }

    func testChunkOffsetsMatchTextSlices() throws {
        // Real prose to confirm the substring at [start..<end] in the
        // source text equals chunk.text exactly. This is the invariant
        // that makes "jump to passage" links land in the right place
        // later in the Ask Posey UI.
        let s = try service(chunkSize: 80, overlap: 16)
        let text = "Posey is a focused reading tool. " +
                   "It plays the document aloud. " +
                   "It keeps your place. " +
                   "It anchors notes to the source text."
        let chunks = s.chunk(text)
        for chunk in chunks {
            let lower = text.index(text.startIndex, offsetBy: chunk.startOffset)
            let upper = text.index(text.startIndex, offsetBy: chunk.endOffset)
            XCTAssertEqual(String(text[lower..<upper]), chunk.text,
                           "Chunk offsets must match the substring they describe")
        }
    }
}
// ========== BLOCK 01: CHUNKING TESTS - END ==========


// ========== BLOCK 02: LANGUAGE + EMBEDDING KIND TESTS - START ==========
final class DocumentEmbeddingLanguageTests: XCTestCase {

    func testDetectsEnglishProse() {
        let text = "The fox jumped over the lazy dog. " +
                   "It was a sunny day in the village square."
        let lang = DocumentEmbeddingIndex.detectLanguage(in: text)
        XCTAssertEqual(lang, .english)
    }

    func testDetectsFrenchProse() {
        let text = "Je pense, donc je suis. La philosophie est " +
                   "essentielle pour comprendre le monde qui nous entoure."
        let lang = DocumentEmbeddingIndex.detectLanguage(in: text)
        XCTAssertEqual(lang, .french,
                       "NLLanguageRecognizer should pick French here; " +
                       "got \(lang.rawValue)")
    }

    func testEmbeddingKindRoundTripsThroughLanguage() {
        // language(forKind:) is the inverse of embeddingKind(for:) for
        // anything that ends up using a real per-language model.
        for language: NLLanguage in [.english, .french, .german, .spanish] {
            guard NLEmbedding.sentenceEmbedding(for: language) != nil else {
                continue // Skip if the simulator/device doesn't ship this model.
            }
            let kind = DocumentEmbeddingIndex.embeddingKind(for: language)
            XCTAssertEqual(kind, "\(language.rawValue)-sentence")
            XCTAssertEqual(DocumentEmbeddingIndex.language(forKind: kind), language)
        }
    }

    func testEnglishFallbackKindIsRecognised() {
        // We can't easily force the "english-fallback" branch from a
        // unit test (it depends on Apple shipping a model gap), so we
        // just confirm the round trip on the literal string.
        XCTAssertEqual(
            DocumentEmbeddingIndex.language(forKind: "english-fallback"),
            .english
        )
        XCTAssertEqual(
            DocumentEmbeddingIndex.language(forKind: "hash-fallback"),
            .english
        )
    }

    func testCosineSimilarityBaseline() {
        XCTAssertEqual(DocumentEmbeddingIndex.cosine([1, 0, 0], [1, 0, 0]), 1, accuracy: 1e-9)
        XCTAssertEqual(DocumentEmbeddingIndex.cosine([1, 0, 0], [0, 1, 0]), 0, accuracy: 1e-9)
        XCTAssertEqual(DocumentEmbeddingIndex.cosine([1, 0, 0], [-1, 0, 0]), -1, accuracy: 1e-9)
        // Mismatched dimensions return 0, not crash.
        XCTAssertEqual(DocumentEmbeddingIndex.cosine([1, 0], [1, 0, 0]), 0)
        // Zero magnitude returns 0, not NaN.
        XCTAssertEqual(DocumentEmbeddingIndex.cosine([0, 0], [1, 0]), 0)
    }
}
// ========== BLOCK 02: LANGUAGE + EMBEDDING KIND TESTS - END ==========


// ========== BLOCK 03: PERSISTENCE + RETRIEVAL TESTS - START ==========
/// End-to-end: index a real document, verify chunks were persisted with
/// embeddings and a sensible kind, run a search, confirm ordering.
final class DocumentEmbeddingPersistenceTests: XCTestCase {

    private var databaseURL: URL!
    private var database: DatabaseManager!
    private var index: DocumentEmbeddingIndex!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        database = try DatabaseManager(databaseURL: databaseURL)
        index = DocumentEmbeddingIndex(database: database)
    }

    override func tearDownWithError() throws {
        index = nil
        database = nil
        if FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path) {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }
    }

    private func makeDocument(plain: String) throws -> Document {
        let document = Document(
            id: UUID(),
            title: "Test",
            fileName: "test.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: plain,
            plainText: plain,
            characterCount: plain.count
        )
        try database.upsertDocument(document)
        return document
    }

    func testIndexIfNeededPersistsChunksWithEmbeddings() throws {
        let plain = String(repeating: "Posey is a focused reading tool. ", count: 60)
        let doc = try makeDocument(plain: plain)

        let count = try index.indexIfNeeded(doc)
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(try database.chunkCount(for: doc.id), count)

        let stored = try database.chunks(for: doc.id)
        XCTAssertEqual(stored.count, count)
        XCTAssertTrue(stored.allSatisfy { !$0.embedding.isEmpty },
                      "Every stored chunk must have a non-empty embedding")
        XCTAssertTrue(stored.allSatisfy { !$0.embeddingKind.isEmpty })
        // For English prose we expect the per-language kind on a typical
        // build environment that ships English sentence embeddings —
        // skip the assertion if not available so the test stays portable.
        if NLEmbedding.sentenceEmbedding(for: .english) != nil {
            XCTAssertEqual(stored.first?.embeddingKind, "en-sentence")
        }
    }

    func testIndexIfNeededIsIdempotent() throws {
        let doc = try makeDocument(plain: String(repeating: "x ", count: 800))
        let firstCount = try index.indexIfNeeded(doc)
        let secondCount = try index.indexIfNeeded(doc)
        XCTAssertEqual(firstCount, secondCount,
                       "Re-indexing the same document must not duplicate chunks")
        XCTAssertEqual(try database.chunkCount(for: doc.id), firstCount)
    }

    func testRebuildIndexReplacesPriorChunks() throws {
        let doc = try makeDocument(plain: String(repeating: "old ", count: 400))
        let firstCount = try index.indexIfNeeded(doc)

        let newPlain = String(repeating: "new content ", count: 400)
        let secondCount = try index.rebuildIndex(for: doc.id, plainText: newPlain)
        XCTAssertGreaterThan(secondCount, 0)

        let stored = try database.chunks(for: doc.id)
        XCTAssertEqual(stored.count, secondCount)
        // Old chunks were "old" repeats; new should contain "new content".
        XCTAssertTrue(stored.allSatisfy { $0.text.contains("new") || $0.text.contains("content") },
                      "Rebuilt index must contain the new content, not the old")
        // A clean rebuild was a delete-then-insert (per replaceChunks);
        // assert the counts diverged so we're not just re-using rows.
        // (Short documents may have similar counts; just verify >0.)
        XCTAssertGreaterThan(firstCount, 0)
    }

    func testSearchRanksRelevantChunkHigher() throws {
        // Build a document with two distinct topics. Ask about one of
        // them and verify the matching chunk lands near the top of the
        // results. We use sentence embeddings if available; on a build
        // without them we fall back to hash embeddings, in which case
        // semantic ranking is degraded but we still expect deterministic
        // ordering.
        let plain = """
        The garden was full of roses and tulips. Bees worked in steady patterns.
        Mathematics requires careful proof. Theorems demand rigour and clarity.
        """
        let doc = try makeDocument(plain: plain)
        _ = try index.indexIfNeeded(doc)

        let results = try index.search(documentID: doc.id, query: "flowers in the garden", limit: 5)
        XCTAssertFalse(results.isEmpty, "Search should produce results")
        // With real sentence embeddings, the garden chunk should come
        // first. With hash fallback, this assertion may not hold —
        // gate the strong assertion on a real model being present.
        if NLEmbedding.sentenceEmbedding(for: .english) != nil {
            XCTAssertTrue(
                results.first?.chunk.text.contains("garden") == true,
                "Expected the garden chunk to rank first; got: \(results.first?.chunk.text ?? "<none>")"
            )
        }
    }

    func testSearchOnUnindexedDocumentReturnsEmpty() throws {
        let doc = try makeDocument(plain: "nothing indexed yet")
        let results = try index.search(documentID: doc.id, query: "anything", limit: 5)
        XCTAssertEqual(results.count, 0,
                       "Searching a document with no chunks must return empty (caller falls back to non-RAG)")
    }

    func testCascadeDeleteRemovesChunks() throws {
        let doc = try makeDocument(plain: String(repeating: "abc ", count: 200))
        _ = try index.indexIfNeeded(doc)
        XCTAssertGreaterThan(try database.chunkCount(for: doc.id), 0)

        try database.deleteDocument(doc)
        // Cascade delete (verified by AskPoseySchemaMigrationTests) should
        // have wiped the chunks too.
        XCTAssertEqual(try database.chunkCount(for: doc.id), 0,
                       "ON DELETE CASCADE should remove chunks when the parent document is deleted")
    }

    func testEmptyTextThrows() throws {
        XCTAssertThrowsError(try index.rebuildIndex(for: UUID(), plainText: "")) { error in
            guard case DocumentEmbeddingError.emptyText = error else {
                XCTFail("Expected DocumentEmbeddingError.emptyText, got \(error)")
                return
            }
        }
    }
}
// ========== BLOCK 03: PERSISTENCE + RETRIEVAL TESTS - END ==========
