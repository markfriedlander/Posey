import XCTest
@testable import Posey

final class TXTLibraryImporterTests: XCTestCase {
    func testImportingSameFixtureTwiceReusesDocumentRecord() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let importer = TXTLibraryImporter(databaseManager: manager)
        let fixtureURL = TestFixtureLoader.url(named: "DuplicateImportSample")

        let firstDocument = try importer.importDocument(from: fixtureURL)
        let secondDocument = try importer.importDocument(from: fixtureURL)
        let documents = try manager.documents()

        XCTAssertEqual(firstDocument.id, secondDocument.id)
        XCTAssertEqual(documents.count, 1)
    }
}
