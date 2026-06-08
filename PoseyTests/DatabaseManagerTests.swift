import XCTest
@testable import Posey

final class DatabaseManagerTests: XCTestCase {
    func testResetIfExistsClearsDatabaseContents() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")

        var manager: DatabaseManager? = try DatabaseManager(databaseURL: databaseURL)
        let document = Document(
            id: UUID(),
            title: "Doc",
            fileName: "doc.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: "One. Two.",
            plainText: "One. Two.",
            characterCount: 9
        )
        try manager?.upsertDocument(document)
        manager = nil

        let resetManager = try DatabaseManager(databaseURL: databaseURL, resetIfExists: true)

        XCTAssertEqual(try resetManager.documents().count, 0)
    }

    func testReadingPositionRoundTrips() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)

        let document = Document(
            id: UUID(),
            title: "Doc",
            fileName: "doc.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: "One. Two. Three.",
            plainText: "One. Two. Three.",
            characterCount: 16
        )
        try manager.upsertDocument(document)

        let position = ReadingPosition(documentID: document.id, updatedAt: .now, characterOffset: 5, sentenceIndex: 1)
        try manager.upsertReadingPosition(position)

        let storedPosition = try XCTUnwrap(try manager.readingPosition(for: document.id))
        XCTAssertEqual(storedPosition.documentID, position.documentID)
        XCTAssertEqual(storedPosition.characterOffset, position.characterOffset)
        XCTAssertEqual(storedPosition.sentenceIndex, position.sentenceIndex)
        XCTAssertLessThan(abs(storedPosition.updatedAt.timeIntervalSince(position.updatedAt)), 1)
    }

    func testNotesRoundTripForDocument() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)

        let document = Document(
            id: UUID(),
            title: "Doc",
            fileName: "doc.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: "One. Two. Three.",
            plainText: "One. Two. Three.",
            characterCount: 16
        )
        try manager.upsertDocument(document)

        let note = Note(
            id: UUID(),
            documentID: document.id,
            createdAt: .now,
            updatedAt: .now,
            kind: .note,
            startOffset: 5,
            endOffset: 9,
            body: "Important point"
        )
        try manager.insertNote(note)

        let storedNotes = try manager.notes(for: document.id)
        XCTAssertEqual(storedNotes.count, 1)
        XCTAssertEqual(storedNotes.first?.body, "Important point")
        XCTAssertEqual(storedNotes.first?.kind, .note)
    }

    // MARK: - PDF enhancement persistence (audit fix #1, 2026-06-08)
    //
    // Regression for the Tier-2 / Tier-3 rollback bug: replaceUnitsForPage
    // and replaceTokenInUnits used to write `UPDATE documents SET plain_text=?,
    // display_text=?, ...`, but those columns are dropped at migration
    // (DatabaseManager migrate(), :1135-1136). The write threw "no such
    // column", the surrounding do/catch ROLLBACKed the whole transaction, and
    // every Vision-OCR page rewrite (Tier 2) and AFM token correction (Tier 3)
    // was silently discarded. These tests fail on the pre-fix code (the
    // mutation never persists) and pass once the dead columns are dropped from
    // the writes. Pure SQLite — no AFM/MLX/Vision, so they run on the sim.

    /// Build a 2-page document: pageBreak(0), prose(token), pageBreak(1),
    /// prose(token). Persisted via the shared importer path.
    private func makeTwoPageDoc() -> ParsedDocument {
        let docID = UUID()
        let units: [ContentUnit] = [
            ContentUnit(documentID: docID, sequence: 0, kind: .pageBreak,
                        text: "", metadata: ContentUnitMetadata(pageNumber: 0)),
            ContentUnit(documentID: docID, sequence: 1, kind: .prose,
                        text: "The quick brown fox sees the OCRerror token."),
            ContentUnit(documentID: docID, sequence: 2, kind: .pageBreak,
                        text: "", metadata: ContentUnitMetadata(pageNumber: 1)),
            ContentUnit(documentID: docID, sequence: 3, kind: .prose,
                        text: "Second page also has an OCRerror to repair."),
        ]
        return ParsedDocument(
            id: docID, title: "Scan", fileName: "scan.pdf", fileType: "pdf",
            units: units, sentences: [], toc: [],
            skipUnitID: nil, skipSource: "",
            playbackSkipUntilOffset: 0, contentEndOffset: 0,
            contentEndUnitID: nil, contentHash: nil, editionLabel: nil
        )
    }

    func testReplaceTokenInUnitsPersistsAcrossTransaction() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let parsed = makeTwoPageDoc()
        try manager.persistParsedDocument(parsed)

        let result = try manager.replaceTokenInUnits(
            documentID: parsed.id,
            original: "OCRerror",
            corrected: "corrected",
            sourceTier: "tier3_afm"
        )
        XCTAssertEqual(result.unitsTouched, 2)
        XCTAssertEqual(result.totalOccurrences, 2)

        // The mutation must SURVIVE the commit. Pre-fix this rolled back.
        let after = try manager.units(for: parsed.id)
        let prose = after.filter { $0.kind.carriesProseText }.map(\.text)
        XCTAssertFalse(prose.contains { $0.contains("OCRerror") },
                       "Tier-3 correction did not persist — transaction rolled back")
        XCTAssertTrue(prose.allSatisfy { $0.contains("corrected") })
        XCTAssertTrue(after.filter { $0.kind == .prose }.allSatisfy { $0.sourceTier == "tier3_afm" })

        // character_count must reflect the corrected prose join.
        let expectedCount = after.filter { $0.kind.carriesProseText }
            .map(\.text).joined(separator: "\n\n").count
        let doc = try XCTUnwrap(try manager.documents().first { $0.id == parsed.id })
        XCTAssertEqual(doc.characterCount, expectedCount)
    }

    func testReplaceUnitsForPagePersistsAcrossTransaction() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let parsed = makeTwoPageDoc()
        try manager.persistParsedDocument(parsed)

        let result = try manager.replaceUnitsForPage(
            documentID: parsed.id,
            pageNumber: 0,
            newPageText: "Replaced page zero prose from Vision OCR.",
            sourceTier: "tier2_vision"
        )
        XCTAssertEqual(result.removedUnitCount, 1)
        XCTAssertEqual(result.insertedUnitCount, 1)

        // The rewrite must SURVIVE the commit. Pre-fix this rolled back.
        let after = try manager.units(for: parsed.id)
        let prose = after.filter { $0.kind.carriesProseText }.map(\.text)
        XCTAssertTrue(prose.contains("Replaced page zero prose from Vision OCR."),
                      "Tier-2 page rewrite did not persist — transaction rolled back")
        XCTAssertFalse(prose.contains { $0.contains("quick brown fox") },
                       "Old page-0 prose should be gone after the rewrite")
        // Page 1 untouched.
        XCTAssertTrue(prose.contains { $0.contains("Second page") })

        let expectedCount = after.filter { $0.kind.carriesProseText }
            .map(\.text).joined(separator: "\n\n").count
        let doc = try XCTUnwrap(try manager.documents().first { $0.id == parsed.id })
        XCTAssertEqual(doc.characterCount, expectedCount)
    }
}
