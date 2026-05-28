import XCTest
@testable import Posey

final class HTMLLibraryImporterTests: XCTestCase {
    func testImportStoresHTMLAsReadableDocument() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let importer = HTMLLibraryImporter(databaseManager: manager)
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "html")

        // 2026-05-28 — importDocument became async during Step 8/9 of
        // the rebuild (units fast path + sentence indexing happen
        // inside the import transaction). Test signature updated.
        let document = try await importer.importDocument(from: fixtureURL)
        let storedDocument = try XCTUnwrap(try manager.documents().first)

        XCTAssertEqual(document.id, storedDocument.id)
        XCTAssertEqual(storedDocument.fileType, "html")
        XCTAssertTrue(storedDocument.displayText.contains("Serious Reading"))
        XCTAssertTrue(storedDocument.plainText.contains("First bullet clarifies the key idea."))
    }
}
