import XCTest
@testable import Posey

final class MarkdownParserTests: XCTestCase {
    func testParseBuildsDisplayBlocksForHeadingsBulletsAndParagraphs() throws {
        let source = try TestFixtureLoader.string(named: "StructuredSample", fileExtension: "md")

        let parsed = MarkdownParser().parse(markdown: source)

        XCTAssertEqual(parsed.blocks.first?.kind, .heading(level: 1))
        XCTAssertTrue(parsed.blocks.contains { $0.kind == .bullet })
        XCTAssertTrue(parsed.blocks.contains { $0.kind == .numbered })
        XCTAssertTrue(parsed.blocks.contains { $0.kind == .paragraph })
        XCTAssertTrue(parsed.plainText.contains("Readers need headings and lists to stay oriented."))
    }

    func testParsePreservesNumberedListMarkersForDisplay() throws {
        let source = try TestFixtureLoader.string(named: "StructuredSample", fileExtension: "md")

        let parsed = MarkdownParser().parse(markdown: source)
        let numberedBlocks = parsed.blocks.filter { $0.kind == .numbered }

        XCTAssertEqual(numberedBlocks.first?.displayPrefix, "1.")
        XCTAssertEqual(numberedBlocks.dropFirst().first?.displayPrefix, "2.")
        XCTAssertTrue(parsed.plainText.contains("First numbered step keeps the sequence visible."))
    }

    func testParseStripsInlineMarkdownFromPlainText() throws {
        let source = try TestFixtureLoader.string(named: "MalformedMarkdownSample", fileExtension: "md")

        let parsed = MarkdownParser().parse(markdown: source)

        XCTAssertTrue(parsed.plainText.contains("bold"))
        XCTAssertTrue(parsed.plainText.contains("a link"))
        XCTAssertFalse(parsed.plainText.contains("**"))
        XCTAssertFalse(parsed.plainText.contains("[a link]"))
    }
}
