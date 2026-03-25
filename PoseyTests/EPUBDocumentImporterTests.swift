import XCTest
@testable import Posey

final class EPUBDocumentImporterTests: XCTestCase {
    func testLoadDocumentExtractsReadableTextAndTitleFromEPUB() throws {
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "epub")

        let parsed = try EPUBDocumentImporter().loadDocument(from: fixtureURL)

        XCTAssertEqual(parsed.title, "Structured Sample EPUB")
        XCTAssertTrue(parsed.plainText.contains("Serious Reading"))
        XCTAssertTrue(parsed.plainText.contains("Dense material benefits from visual structure."))
        XCTAssertTrue(parsed.plainText.contains("Closing thought: readers need structure to stay oriented."))
    }

    func testLoadDocumentRejectsUnreadableEPUBData() throws {
        let invalidData = Data("not-an-epub".utf8)

        XCTAssertThrowsError(try EPUBDocumentImporter().loadDocument(fromData: invalidData)) { error in
            XCTAssertEqual(error as? EPUBDocumentImporter.ImportError, .unreadableDocument)
        }
    }
}
