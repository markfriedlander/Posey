import XCTest
@testable import Posey

final class TXTDocumentImporterTests: XCTestCase {
    func testLoadTextNormalizesLineEndingsAndTrimsOuterWhitespace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("normalize.txt")
        try " \r\nAlpha\r\nBeta\rGamma\n ".write(to: fileURL, atomically: true, encoding: .utf8)

        let text = try TXTDocumentImporter().loadText(from: fileURL)

        XCTAssertEqual(text, "Alpha\nBeta\nGamma")
    }

    func testLoadTextRejectsEmptyDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("empty.txt")
        try "   \n\n  ".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try TXTDocumentImporter().loadText(from: fileURL)) { error in
            XCTAssertEqual(error as? TXTDocumentImporter.ImportError, .emptyDocument)
        }
    }
}
