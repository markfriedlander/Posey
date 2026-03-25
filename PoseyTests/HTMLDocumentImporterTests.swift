import XCTest
@testable import Posey

final class HTMLDocumentImporterTests: XCTestCase {
    func testLoadTextExtractsReadableStringFromHTML() throws {
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "html")

        let text = try HTMLDocumentImporter().loadText(from: fixtureURL)

        XCTAssertTrue(text.contains("Serious Reading"))
        XCTAssertTrue(text.contains("Dense material benefits from visual structure."))
        XCTAssertTrue(text.contains("First bullet clarifies the key idea."))
        XCTAssertTrue(text.contains("Closing thought: readers need structure to stay oriented."))
    }

    func testLoadTextRejectsEmptyHTMLDocument() throws {
        let emptyHTML = Data("<html><body> \n </body></html>".utf8)

        XCTAssertThrowsError(try HTMLDocumentImporter().loadText(fromData: emptyHTML)) { error in
            XCTAssertEqual(error as? HTMLDocumentImporter.ImportError, .emptyDocument)
        }
    }
}
