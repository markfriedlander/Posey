import XCTest
@testable import Posey

final class DOCXLibraryImporterTests: XCTestCase {
    func testImportStoresDOCXAsReadableDocument() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let importer = DOCXLibraryImporter(databaseManager: manager)
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "docx")

        let document = try importer.importDocument(from: fixtureURL)
        let storedDocument = try XCTUnwrap(try manager.documents().first)

        XCTAssertEqual(document.id, storedDocument.id)
        XCTAssertEqual(storedDocument.fileType, "docx")
        XCTAssertTrue(storedDocument.displayText.contains("Serious Reading"))
        XCTAssertTrue(storedDocument.plainText.contains("First bullet clarifies the key idea."))
    }
}
