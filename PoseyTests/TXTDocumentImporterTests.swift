import XCTest
@testable import Posey

final class TXTDocumentImporterTests: XCTestCase {
    func testLoadTextNormalizesLineEndingsAndTrimsOuterWhitespace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("normalize.txt")
        try " \r\nAlpha\r\nBeta\rGamma\n ".write(to: fileURL, atomically: true, encoding: .utf8)

        let text = try TXTDocumentImporter().loadText(from: fileURL)

        // TXT normalizes CRLF/CR → LF and trims outer whitespace, THEN reflows
        // hard-wrapped lines (Gutenberg ~72-char display wraps, intended since
        // 2026-05-27): single-newline-separated lines of one paragraph join
        // with spaces. So the three lines become one reflowed line — proving
        // the line endings were normalized (no literal \r survives) and outer
        // whitespace trimmed. (Paragraph breaks, \n\n, are preserved — see the
        // reflow assertions in FormatNormalizationParityTests.)
        XCTAssertEqual(text, "Alpha Beta Gamma")
        XCTAssertFalse(text.contains("\r"))
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
