import XCTest
@testable import Posey

final class MarkdownLibraryImporterTests: XCTestCase {
    func testImportStoresDisplayAndPlainTextForms() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let importer = MarkdownLibraryImporter(databaseManager: manager)
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "md")

        let document = try importer.importDocument(from: fixtureURL)
        let storedDocument = try XCTUnwrap(try manager.documents().first)

        XCTAssertEqual(document.id, storedDocument.id)
        XCTAssertTrue(storedDocument.displayText.contains("# Serious Reading"))
        XCTAssertTrue(storedDocument.plainText.contains("Serious Reading"))
        XCTAssertFalse(storedDocument.plainText.contains("# Serious Reading"))
    }
}
