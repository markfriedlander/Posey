import XCTest
@testable import Posey

final class HTMLDocumentImporterTests: XCTestCase {
    func testLoadTextExtractsReadableStringFromHTML() async throws {
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "html")

        let text = try await HTMLDocumentImporter().loadText(from: fixtureURL)

        XCTAssertTrue(text.contains("Serious Reading"))
        XCTAssertTrue(text.contains("Dense material benefits from visual structure."))
        XCTAssertTrue(text.contains("First bullet clarifies the key idea."))
        XCTAssertTrue(text.contains("Closing thought: readers need structure to stay oriented."))
    }

    func testLoadTextRejectsEmptyHTMLDocument() async throws {
        let emptyHTML = Data("<html><body> \n </body></html>".utf8)

        // loadText is now async (Path A); assert the throw via do/catch.
        do {
            _ = try await HTMLDocumentImporter().loadText(fromData: emptyHTML)
            XCTFail("expected emptyDocument")
        } catch {
            XCTAssertEqual(error as? HTMLDocumentImporter.ImportError, .emptyDocument)
        }
    }
}
