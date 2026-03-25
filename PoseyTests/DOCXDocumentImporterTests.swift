import XCTest
@testable import Posey

final class DOCXDocumentImporterTests: XCTestCase {
    func testLoadTextExtractsReadableStringFromDOCX() throws {
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "docx")

        let text = try DOCXDocumentImporter().loadText(from: fixtureURL)

        XCTAssertTrue(text.contains("Serious Reading"))
        XCTAssertTrue(text.contains("First bullet clarifies the key idea."))
        XCTAssertTrue(text.contains("Closing thought: readers need structure to stay oriented."))
    }

    func testLoadTextRejectsUnreadableDOCXData() throws {
        let invalidData = Data("not-a-docx".utf8)

        XCTAssertThrowsError(try DOCXDocumentImporter().loadText(fromData: invalidData)) { error in
            XCTAssertEqual(error as? DOCXDocumentImporter.ImportError, .unreadableDocument)
        }
    }
}
