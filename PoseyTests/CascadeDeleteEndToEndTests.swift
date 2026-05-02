import XCTest
import SQLite3
@testable import Posey

// ========== BLOCK 01: COMPREHENSIVE CASCADE - START ==========
/// End-to-end verification that `DatabaseManager.deleteDocument(_:)`
/// removes EVERY child row across every table that references
/// `documents(id)` via `ON DELETE CASCADE`. The existing
/// `AskPoseySchemaMigrationTests.testCascadeDeleteIsConfigured`
/// checks the schema-level FK contract via `PRAGMA foreign_key_list`;
/// this test seeds real data into every dependent table and verifies
/// the actual delete drops them all.
///
/// Coverage matrix:
/// - reading_positions
/// - notes
/// - document_images
/// - document_toc
/// - ask_posey_conversations (M1 + M5 columns)
/// - document_chunks (M2)
///
/// Triggered by Mark 2026-05-02 before re-importing the AI Book for
/// a clean test baseline. If a future schema migration adds a new
/// `document_id`-referencing table, extend this test to cover it.
final class CascadeDeleteEndToEndTests: XCTestCase {

    private var databaseURL: URL!
    private var manager: DatabaseManager!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        manager = try DatabaseManager(databaseURL: databaseURL)
    }

    override func tearDownWithError() throws {
        manager = nil
        if FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path) {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }
    }

    func testDeleteDocumentCascadesAcrossEveryChildTable() throws {
        let docID = UUID()
        let doc = Document(
            id: docID,
            title: "Cascade End-to-End",
            fileName: "cascade.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: "x",
            plainText: "x",
            characterCount: 1,
            playbackSkipUntilOffset: 0
        )
        try manager.upsertDocument(doc)

        // ---- Seed every child table ----

        // reading_positions
        try manager.upsertReadingPosition(
            ReadingPosition(documentID: docID, updatedAt: .now, characterOffset: 0, sentenceIndex: 0)
        )

        // notes
        try manager.insertNote(
            Note(
                id: UUID(),
                documentID: docID,
                createdAt: .now,
                updatedAt: .now,
                kind: .note,
                startOffset: 0,
                endOffset: 1,
                body: "test"
            )
        )

        // document_images
        try manager.insertImage(id: UUID().uuidString, documentID: docID, data: Data([0xFF, 0xD8, 0xFF]))

        // document_toc
        try manager.insertTOCEntries(
            [StoredTOCEntry(title: "Chapter 1", plainTextOffset: 0, playOrder: 1)],
            for: docID
        )

        // ask_posey_conversations (M1 schema + M5 columns)
        try manager.appendAskPoseyTurn(StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: docID,
            timestamp: .now,
            role: "user",
            content: "what is this about?",
            invocation: "passage",
            anchorOffset: 0,
            intent: "immediate",
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        ))
        // Also seed a summary row to make sure those cascade too.
        try manager.appendAskPoseyTurn(StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: docID,
            timestamp: .now,
            role: "assistant",
            content: "summary text",
            invocation: "passage",
            anchorOffset: nil,
            intent: nil,
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 5,
            isSummary: true
        ))

        // document_chunks (M2)
        let chunk = StoredDocumentChunk(
            chunkIndex: 0,
            startOffset: 0,
            endOffset: 1,
            text: "x",
            embedding: [0.1, 0.2, 0.3],
            embeddingKind: "english-fallback"
        )
        try manager.replaceChunks([chunk], for: docID)

        // Verify all rows present BEFORE delete (sanity check the seeding worked).
        let preCounts = try countsByTable(forDocument: docID)
        XCTAssertEqual(preCounts["documents"], 1)
        XCTAssertEqual(preCounts["reading_positions"], 1)
        XCTAssertEqual(preCounts["notes"], 1)
        XCTAssertEqual(preCounts["document_images"], 1)
        XCTAssertEqual(preCounts["document_toc"], 1)
        XCTAssertEqual(preCounts["ask_posey_conversations"], 2,
                       "Should have one normal turn + one summary row pre-delete")
        XCTAssertEqual(preCounts["document_chunks"], 1)

        // ---- The actual delete ----
        try manager.deleteDocument(doc)

        // Verify EVERY child table is empty for this document_id.
        let postCounts = try countsByTable(forDocument: docID)
        XCTAssertEqual(postCounts["documents"], 0,
                       "documents row should be gone")
        XCTAssertEqual(postCounts["reading_positions"], 0,
                       "reading_positions did not cascade")
        XCTAssertEqual(postCounts["notes"], 0,
                       "notes did not cascade")
        XCTAssertEqual(postCounts["document_images"], 0,
                       "document_images did not cascade")
        XCTAssertEqual(postCounts["document_toc"], 0,
                       "document_toc did not cascade")
        XCTAssertEqual(postCounts["ask_posey_conversations"], 0,
                       "ask_posey_conversations (incl. summary rows) did not cascade")
        XCTAssertEqual(postCounts["document_chunks"], 0,
                       "document_chunks did not cascade")
    }

    /// Direct row counts via a parallel sqlite connection that
    /// re-enables PRAGMA foreign_keys (the cascade is enforced by
    /// the manager's connection but introspection runs through a
    /// new connection here — opening fresh + setting the pragma
    /// keeps the read consistent with the manager's state).
    private func countsByTable(forDocument docID: UUID) throws -> [String: Int] {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        defer { if connection != nil { sqlite3_close(connection) } }
        sqlite3_exec(connection, "PRAGMA foreign_keys = ON;", nil, nil, nil)

        let tables = [
            "documents",
            "reading_positions",
            "notes",
            "document_images",
            "document_toc",
            "ask_posey_conversations",
            "document_chunks"
        ]
        var counts: [String: Int] = [:]
        for table in tables {
            let column = (table == "documents") ? "id" : "document_id"
            let sql = "SELECT COUNT(*) FROM \(table) WHERE \(column) = '\(docID.uuidString)';"
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &stmt, nil), SQLITE_OK,
                           "Failed to prepare count: \(table)")
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            counts[table] = Int(sqlite3_column_int(stmt, 0))
        }
        return counts
    }
}
// ========== BLOCK 01: COMPREHENSIVE CASCADE - END ==========
