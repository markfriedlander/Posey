import XCTest
@testable import Posey

final class PDFLibraryImporterTests: XCTestCase {
    func testImportStoresPDFAsReadableDocument() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let importer = PDFLibraryImporter(databaseManager: manager)
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "pdf")

        let document = try importer.importDocument(from: fixtureURL)
        let storedDocument = try XCTUnwrap(try manager.documents().first)

        XCTAssertEqual(document.id, storedDocument.id)
        XCTAssertEqual(storedDocument.fileType, "pdf")
        XCTAssertEqual(storedDocument.title, "Structured Sample PDF")
        XCTAssertTrue(storedDocument.displayText.contains("\u{000C}"))
        XCTAssertTrue(storedDocument.displayText.contains("Serious Reading in PDF"))
        XCTAssertTrue(storedDocument.plainText.contains("Second page reminder: preserve context across page breaks."))
    }
}
