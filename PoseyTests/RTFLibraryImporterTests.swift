import XCTest
@testable import Posey

final class RTFLibraryImporterTests: XCTestCase {
    func testImportStoresRTFAsReadableDocument() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let importer = RTFLibraryImporter(databaseManager: manager)
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "rtf")

        let document = try importer.importDocument(from: fixtureURL)
        let storedDocument = try XCTUnwrap(try manager.documents().first)

        XCTAssertEqual(document.id, storedDocument.id)
        XCTAssertEqual(storedDocument.fileType, "rtf")
        XCTAssertTrue(storedDocument.displayText.contains("Serious Reading"))
        XCTAssertTrue(storedDocument.plainText.contains("First bullet clarifies the key idea."))
    }
}
