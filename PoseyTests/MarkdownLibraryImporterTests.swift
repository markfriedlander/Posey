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
        // The parser's display form keeps the markdown markers (`# `)…
        XCTAssertTrue(document.displayText.contains("# Serious Reading"))
        // …while the plain reading text strips them. In the units architecture
        // the STORED text (displayText/plainText) is derived from content units
        // by joining prose — headings carry their text WITHOUT the `#` marker
        // (they render as styled `.heading` units, not literal `#`). So both
        // stored forms are clean prose, and the heading survives as a unit.
        XCTAssertTrue(storedDocument.plainText.contains("Serious Reading"))
        XCTAssertFalse(storedDocument.plainText.contains("# Serious Reading"))
        let units = try manager.units(for: storedDocument.id)
        XCTAssertTrue(
            units.contains { $0.kind == .heading && $0.text.contains("Serious Reading") },
            "the `# Serious Reading` heading should be preserved as a styled heading unit")
    }
}
