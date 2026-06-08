import XCTest
@testable import Posey

/// Audit / foundation-parity pass (2026-06-08, item #1).
///
/// All 7 importers now route their extracted text through the single shared
/// `TextNormalizer.normalizeUniversal(_:hardWrapped:)`, which folds in the
/// universal à-la-carte fixes that previously only TXT ran — most visibly
/// `stripGutenbergItalics` (`_Mem._` → `Mem.`). These tests prove the shared
/// function does the right thing AND that each importer's actual extraction
/// path reaches it, so `_Mem._` is stripped uniformly. (DOCX/EPUB binary paths
/// are exercised end-to-end on device/sim; EPUB's per-chapter text path is the
/// HTML `loadText` method covered here.)
final class FormatNormalizationParityTests: XCTestCase {

    // MARK: - The shared normalizer

    func testNormalizeUniversalStripsUnderscoreItalics() {
        XCTAssertEqual(
            TextNormalizer.normalizeUniversal("A note. _Mem._ to self."),
            "A note. Mem. to self.")
        // Multi-word phrase.
        XCTAssertEqual(
            TextNormalizer.normalizeUniversal("She wrote _Kept in shorthand._ here."),
            "She wrote Kept in shorthand. here.")
    }

    func testNormalizeUniversalLeavesSnakeCaseIdentifiersAlone() {
        // Word-boundary guards: legitimate snake_case must survive.
        let s = "Call my_var_name and __init__ today."
        XCTAssertEqual(TextNormalizer.normalizeUniversal(s), s)
    }

    func testNormalizeUniversalAppliesUniversalCleanups() {
        // ZWSP + nbsp + soft-hyphen + CRLF + line-break hyphen + multi-space.
        let messy = "Hello\u{200B}\u{00A0}world.\r\nThe inde-\npendent  cat."
        let out = TextNormalizer.normalizeUniversal(messy)
        XCTAssertFalse(out.contains("\u{200B}"))
        XCTAssertFalse(out.contains("\u{00A0}"))
        XCTAssertFalse(out.contains("\r"))
        XCTAssertTrue(out.contains("independent"), "line-break hyphen should rejoin")
        XCTAssertFalse(out.contains("  "), "multi-space should collapse")
    }

    func testSpacedGlyphRepairIsPDFOnlyNotUniversal() {
        // The PDF glyph-spacing artifact must NOT be collapsed by the
        // universal path (would mangle intentional letter-spacing in
        // DOCX/HTML), but MUST be collapsed by the PDF-specific helper.
        let spaced = "C O N T E N T S and 1 9 4 5"
        XCTAssertEqual(TextNormalizer.normalizeUniversal(spaced), spaced,
                       "universal path must leave spaced glyphs intact")
        XCTAssertEqual(TextNormalizer.normalizePDFGlyphArtifacts(spaced),
                       "CONTENTS and 1945",
                       "PDF-specific path must collapse spaced glyphs")
    }

    // MARK: - Per-importer paths reach the shared normalizer

    func testTXTImporterStripsUnderscoreItalics() throws {
        let out = try TXTDocumentImporter().loadText(fromContents: "A note. _Mem._ to self.")
        XCTAssertTrue(out.contains("Mem."))
        XCTAssertFalse(out.contains("_Mem._"))
    }

    func testMarkdownImporterStripsUnderscoreItalics() throws {
        let parsed = try MarkdownDocumentImporter().loadDocument(
            fromContents: "A note. _Mem._ to self.")
        XCTAssertTrue(parsed.plainText.contains("Mem."))
        XCTAssertFalse(parsed.plainText.contains("_Mem._"))
    }

    @MainActor
    func testHTMLImporterStripsUnderscoreItalics() throws {
        // HTML's loadText is ALSO the per-chapter text path EPUB uses, so this
        // covers EPUB's text normalization too.
        let html = "<html><body><p>A note. _Mem._ to self.</p></body></html>"
        let out = try HTMLDocumentImporter().loadText(fromData: Data(html.utf8))
        XCTAssertTrue(out.contains("Mem."))
        XCTAssertFalse(out.contains("_Mem._"))
    }

    func testRTFImporterStripsUnderscoreItalics() throws {
        // Minimal RTF carrying literal `_Mem._` (the shape real Gutenberg-
        // derived RTFs use — e.g. rtf_with-image.rtf in the corpus).
        let rtf = #"{\rtf1\ansi\ansicpg1252 A note. _Mem._ to self.\par}"#
        let parsed = try RTFDocumentImporter().loadDocument(fromData: Data(rtf.utf8))
        XCTAssertTrue(parsed.plainText.contains("Mem."))
        XCTAssertFalse(parsed.plainText.contains("_Mem._"))
    }
}
