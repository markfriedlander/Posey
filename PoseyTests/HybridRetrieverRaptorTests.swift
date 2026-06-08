import XCTest
@testable import Posey

/// Audit fix #2 (2026-06-08) — RAPTOR wired to production.
///
/// The audit's confirmed finding #1 was that RAPTOR summary nodes were never
/// produced in a Release build (only a DEBUG-only antenna verb built them).
/// The production trigger now lives in `RaptorTreeService` (kicked from
/// `UnitEmbeddingService` on index completion + `bootstrap` on launch). The
/// *builder* (cluster → AFM-summarize → verify) needs Apple Foundation Models
/// and is therefore phone-only to exercise end-to-end. What IS verifiable on
/// the simulator — and is the crux Mark asked to confirm — is that once a
/// summary node is stored, `HybridRetriever` actually surfaces it. These tests
/// prove that via the lexical (BM25) path, which needs no AFM and no embedding
/// backend, plus the two count helpers `RaptorTreeService` relies on.
final class HybridRetrieverRaptorTests: XCTestCase {

    private func makeDB() throws -> (DatabaseManager, ParsedDocument) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let db = try DatabaseManager(databaseURL: url)
        let docID = UUID()
        let units = [
            ContentUnit(documentID: docID, sequence: 0, kind: .prose,
                        text: "An ordinary first paragraph about sailing ships and the open sea."),
            ContentUnit(documentID: docID, sequence: 1, kind: .prose,
                        text: "A second ordinary paragraph about the weather and the ship's crew."),
        ]
        let parsed = ParsedDocument(
            id: docID, title: "Doc", fileName: "d.txt", fileType: "txt",
            units: units, sentences: [], toc: [],
            skipUnitID: nil, skipSource: "",
            playbackSkipUntilOffset: 0, contentEndOffset: 0,
            contentEndUnitID: nil, contentHash: nil, editionLabel: nil)
        try db.persistParsedDocument(parsed)
        return (db, parsed)
    }

    /// The whole point of finding #1: a stored summary node must be reachable
    /// by the same retriever that serves Ask Posey. A distinctive token lives
    /// ONLY in the summary node; querying it must return a result whose
    /// chunkID is in the summary range (>= raptorSummaryIndexBase).
    func testHybridRetrieverSurfacesStoredRaptorSummaryNode() throws {
        let (db, parsed) = try makeDB()
        let unit = try XCTUnwrap(try db.units(for: parsed.id).first { $0.kind == .prose })

        let summary = StoredUnitEmbeddingChunk(
            id: UUID(), documentID: parsed.id,
            chunkIndex: DatabaseManager.raptorSummaryIndexBase,
            startUnitID: unit.id, startIntraOffset: 0,
            endUnitID: unit.id, endIntraOffset: 0,
            text: "This cluster summary concerns the Zorblattian voyage and its recurring themes.",
            embedding: nil)
        try db.replaceSummaryNodes([summary], for: parsed.id)
        XCTAssertEqual(try db.raptorSummaryNodeCount(for: parsed.id), 1)

        let retriever = HybridRetriever(database: db)
        let outcome = retriever.retrieve(documentID: parsed.id, query: "Zorblattian", limit: 10)
        let surfaced = outcome.results.contains {
            $0.chunkID >= DatabaseManager.raptorSummaryIndexBase
        }
        XCTAssertTrue(surfaced,
                      "RAPTOR summary node did not surface in hybrid retrieval results")
    }

    /// `replaceSummaryNodes` with an empty array clears the tree (the rebuild
    /// path), and the count helper reflects it.
    func testReplaceSummaryNodesClearsTree() throws {
        let (db, parsed) = try makeDB()
        let unit = try XCTUnwrap(try db.units(for: parsed.id).first { $0.kind == .prose })
        let summary = StoredUnitEmbeddingChunk(
            id: UUID(), documentID: parsed.id,
            chunkIndex: DatabaseManager.raptorSummaryIndexBase,
            startUnitID: unit.id, startIntraOffset: 0,
            endUnitID: unit.id, endIntraOffset: 0,
            text: "A summary.", embedding: nil)
        try db.replaceSummaryNodes([summary], for: parsed.id)
        XCTAssertEqual(try db.raptorSummaryNodeCount(for: parsed.id), 1)
        try db.replaceSummaryNodes([], for: parsed.id)
        XCTAssertEqual(try db.raptorSummaryNodeCount(for: parsed.id), 0)
    }

    /// The two count helpers `RaptorTreeService` uses for its build gate +
    /// bootstrap dedup. No chunks indexed → both zero; summaries are NOT
    /// counted as leaves.
    func testRaptorCountHelpers() throws {
        let (db, parsed) = try makeDB()
        XCTAssertEqual(try db.raptorSummaryNodeCount(for: parsed.id), 0)
        XCTAssertEqual(try db.embeddedLeafChunkCount(for: parsed.id), 0)

        let unit = try XCTUnwrap(try db.units(for: parsed.id).first { $0.kind == .prose })
        let summary = StoredUnitEmbeddingChunk(
            id: UUID(), documentID: parsed.id,
            chunkIndex: DatabaseManager.raptorSummaryIndexBase,
            startUnitID: unit.id, startIntraOffset: 0,
            endUnitID: unit.id, endIntraOffset: 0,
            text: "A summary node.", embedding: [0.1, 0.2, 0.3])
        try db.replaceSummaryNodes([summary], for: parsed.id)
        // Summary node exists but is NOT an embedded *leaf*.
        XCTAssertEqual(try db.raptorSummaryNodeCount(for: parsed.id), 1)
        XCTAssertEqual(try db.embeddedLeafChunkCount(for: parsed.id), 0)
    }
}
