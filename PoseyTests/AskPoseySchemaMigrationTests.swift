import XCTest
import SQLite3
@testable import Posey

// ========== BLOCK 01: SCHEMA MIGRATION TESTS - START ==========
/// Confirm the Ask Posey Milestone 1 schema migrations apply cleanly to a
/// fresh database and produce the expected tables, columns, and indexes.
///
/// The DatabaseManager runs migrations in its initializer, so simply opening
/// a database against a fresh URL is enough to exercise the migration path.
/// Each test then opens a parallel sqlite3 connection to introspect
/// `sqlite_master` and the `PRAGMA table_info(...)` output. Using a
/// parallel connection (instead of exposing introspection through
/// DatabaseManager's API surface) keeps production code minimal — the
/// schema is internal and the tests are the only place that needs to read
/// it back directly.
final class AskPoseySchemaMigrationTests: XCTestCase {

    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        // Force migration to run by opening a manager. We discard it
        // immediately so each test has a clean introspection connection.
        _ = try DatabaseManager(databaseURL: databaseURL)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path) {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }
    }

    func testAskPoseyConversationsTableCreated() throws {
        let columns = try columnsOf(table: "ask_posey_conversations")
        XCTAssertEqual(Set(columns.keys), [
            // M1 columns
            "id",
            "document_id",
            "timestamp",
            "role",
            "content",
            "invocation",
            "anchor_offset",
            "summary_of_turns_through",
            "is_summary",
            // M5 column additions
            "intent",
            "chunks_injected",
            "full_prompt_for_logging",
            "embedding",
            "embedding_kind"
        ])
        // Spot-check a few constraints we'll rely on at the storage layer.
        XCTAssertEqual(columns["id"]?.type, "TEXT")
        XCTAssertEqual(columns["id"]?.isPrimaryKey, true)
        XCTAssertEqual(columns["document_id"]?.notNull, true)
        XCTAssertEqual(columns["anchor_offset"]?.notNull, false,
                       "anchor_offset must be nullable for document-scoped invocations")
        XCTAssertEqual(columns["summary_of_turns_through"]?.notNull, true)
        XCTAssertEqual(columns["is_summary"]?.notNull, true)
        // M5 columns: intent + full_prompt_for_logging + embedding are
        // nullable because legacy/M1 rows didn't carry them and the
        // ALTER TABLE migration can't backfill. chunks_injected and
        // embedding_kind have NOT NULL DEFAULTs so existing rows pick
        // up the defaults.
        XCTAssertEqual(columns["intent"]?.notNull, false)
        XCTAssertEqual(columns["full_prompt_for_logging"]?.notNull, false)
        XCTAssertEqual(columns["embedding"]?.notNull, false)
        XCTAssertEqual(columns["embedding"]?.type, "BLOB")
        XCTAssertEqual(columns["chunks_injected"]?.notNull, true)
        XCTAssertEqual(columns["embedding_kind"]?.notNull, true)
    }

    func testAskPoseyConversationsIndexCreated() throws {
        let indexes = try indexesOf(table: "ask_posey_conversations")
        XCTAssertTrue(indexes.contains("idx_ask_posey_doc_ts"),
                      "Expected idx_ask_posey_doc_ts to be created; got \(indexes)")
    }

    func testDocumentChunksTableCreated() throws {
        let columns = try columnsOf(table: "document_chunks")
        XCTAssertEqual(Set(columns.keys), [
            "id",
            "document_id",
            "chunk_index",
            "start_offset",
            "end_offset",
            "text",
            "embedding",
            "embedding_kind"
        ])
        XCTAssertEqual(columns["id"]?.isPrimaryKey, true)
        XCTAssertEqual(columns["embedding"]?.type, "BLOB")
        XCTAssertEqual(columns["embedding_kind"]?.notNull, true)
    }

    func testDocumentChunksIndexCreated() throws {
        let indexes = try indexesOf(table: "document_chunks")
        XCTAssertTrue(indexes.contains("idx_document_chunks_doc"),
                      "Expected idx_document_chunks_doc to be created; got \(indexes)")
    }

    func testCascadeDeleteIsConfigured() throws {
        // Both new tables MUST cascade-delete on document removal so
        // dropping a document doesn't leave orphaned chunks or
        // conversations behind. Verify via PRAGMA foreign_key_list.
        try assertCascadeForeignKey(on: "ask_posey_conversations", referencing: "documents")
        try assertCascadeForeignKey(on: "document_chunks", referencing: "documents")
    }

    func testForeignKeysAreEnabledByPragma() throws {
        // Posey turns on PRAGMA foreign_keys = ON when opening the database
        // (see DatabaseManager.open()). If that ever regresses, the
        // ON DELETE CASCADE clauses become silently inactive — which would
        // be a data-integrity bug we'd never notice without this assertion.
        let manager = try DatabaseManager(databaseURL: databaseURL)
        // Use the manager's own connection by opening a parallel one and
        // checking the same database file's pragma-honored behavior:
        // insert a conversation row, delete its parent document, then
        // assert the conversation is gone.
        let document = Document(
            id: UUID(),
            title: "Cascade test",
            fileName: "cascade.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: "x",
            plainText: "x",
            characterCount: 1
        )
        try manager.upsertDocument(document)

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        defer { if connection != nil { sqlite3_close(connection) } }
        XCTAssertEqual(
            sqlite3_exec(connection, "PRAGMA foreign_keys = ON;", nil, nil, nil),
            SQLITE_OK
        )

        let convoID = UUID().uuidString
        let insertSQL = """
        INSERT INTO ask_posey_conversations
        (id, document_id, timestamp, role, content, invocation, anchor_offset, summary_of_turns_through, is_summary)
        VALUES ('\(convoID)', '\(document.id.uuidString)', \(Date.now.timeIntervalSince1970), 'user', 'hi', 'document', NULL, 0, 0);
        """
        XCTAssertEqual(sqlite3_exec(connection, insertSQL, nil, nil, nil), SQLITE_OK,
                       "Insert failed: \(String(cString: sqlite3_errmsg(connection)))")

        try manager.deleteDocument(document)

        let countSQL = "SELECT COUNT(*) FROM ask_posey_conversations WHERE id = '\(convoID)';"
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, countSQL, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 0,
                       "Cascade delete should have removed the orphan conversation row")
    }

    // MARK: - Introspection helpers

    private struct ColumnInfo {
        let type: String
        let notNull: Bool
        let isPrimaryKey: Bool
    }

    private func columnsOf(table: String) throws -> [String: ColumnInfo] {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        defer { if connection != nil { sqlite3_close(connection) } }

        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &stmt, nil), SQLITE_OK,
                       "Failed to prepare PRAGMA table_info: \(String(cString: sqlite3_errmsg(connection)))")
        defer { sqlite3_finalize(stmt) }

        var result: [String: ColumnInfo] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            // PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
            guard
                let nameC = sqlite3_column_text(stmt, 1),
                let typeC = sqlite3_column_text(stmt, 2)
            else { continue }
            let name = String(cString: nameC)
            let type = String(cString: typeC).uppercased()
            let notNull = sqlite3_column_int(stmt, 3) != 0
            let isPrimaryKey = sqlite3_column_int(stmt, 5) != 0
            result[name] = ColumnInfo(type: type, notNull: notNull, isPrimaryKey: isPrimaryKey)
        }
        return result
    }

    private func indexesOf(table: String) throws -> Set<String> {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        defer { if connection != nil { sqlite3_close(connection) } }

        var stmt: OpaquePointer?
        let sql = "PRAGMA index_list(\(table));"
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        var indexes = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            // PRAGMA index_list columns: seq, name, unique, origin, partial
            if let nameC = sqlite3_column_text(stmt, 1) {
                indexes.insert(String(cString: nameC))
            }
        }
        return indexes
    }

    private func assertCascadeForeignKey(on table: String, referencing parent: String) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        defer { if connection != nil { sqlite3_close(connection) } }

        var stmt: OpaquePointer?
        let sql = "PRAGMA foreign_key_list(\(table));"
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            // foreign_key_list columns: id, seq, table, from, to, on_update, on_delete, match
            guard let parentTableC = sqlite3_column_text(stmt, 2),
                  let onDeleteC = sqlite3_column_text(stmt, 6) else { continue }
            let parentTable = String(cString: parentTableC)
            let onDelete = String(cString: onDeleteC).uppercased()
            if parentTable == parent {
                XCTAssertEqual(onDelete, "CASCADE",
                               "Foreign key from \(table) → \(parent) must be ON DELETE CASCADE; got \(onDelete)")
                found = true
            }
        }
        XCTAssertTrue(found, "No foreign key found from \(table) to \(parent)")
    }
}
// ========== BLOCK 01: SCHEMA MIGRATION TESTS - END ==========
