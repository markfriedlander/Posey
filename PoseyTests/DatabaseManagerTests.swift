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
}
