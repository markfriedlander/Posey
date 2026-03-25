import XCTest
@testable import Posey

final class RTFDocumentImporterTests: XCTestCase {
    func testLoadTextExtractsReadableStringFromRTF() throws {
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "rtf")

        let text = try RTFDocumentImporter().loadText(from: fixtureURL)

        XCTAssertTrue(text.contains("Serious Reading"))
        XCTAssertTrue(text.contains("First bullet clarifies the key idea."))
        XCTAssertTrue(text.contains("Closing thought: readers need structure to stay oriented."))
        XCTAssertFalse(text.contains(#"\rtf1"#))
    }

    func testLoadTextRejectsEmptyRTFDocument() throws {
        let emptyRTF = Data("{\\rtf1\\ansi   }".utf8)

        XCTAssertThrowsError(try RTFDocumentImporter().loadText(fromData: emptyRTF)) { error in
            XCTAssertEqual(error as? RTFDocumentImporter.ImportError, .emptyDocument)
        }
    }
}
