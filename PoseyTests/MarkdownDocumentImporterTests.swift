import XCTest
@testable import Posey

final class MarkdownDocumentImporterTests: XCTestCase {
    func testLoadDocumentPreservesDisplayTextAndBuildsReadablePlainText() throws {
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "md")

        let document = try MarkdownDocumentImporter().loadDocument(from: fixtureURL)

        XCTAssertTrue(document.displayText.contains("# Serious Reading"))
        XCTAssertTrue(document.plainText.contains("Serious Reading"))
        XCTAssertTrue(document.plainText.contains("First bullet clarifies the key idea."))
        XCTAssertFalse(document.plainText.contains("# Serious Reading"))
    }

    func testLoadDocumentRejectsEmptyMarkdown() throws {
        XCTAssertThrowsError(try MarkdownDocumentImporter().loadDocument(fromContents: " \n\n ")) { error in
            XCTAssertEqual(error as? MarkdownDocumentImporter.ImportError, .emptyDocument)
        }
    }
}
