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

    // MARK: - stripDropcapSpans regression coverage

    /// 2026-05-28 — Mark caught that Project Gutenberg's illustrated
    /// Pride and Prejudice EPUB rendered every chapter opening with the
    /// first letter missing ("R. BENNET'S property" instead of
    /// "MR. BENNET'S property"). PG implements drop caps as a tiny PNG
    /// inside a span; the prior regex only matched plain-text inner
    /// content and silently dropped the entire `<img …/>` substring on
    /// the `[^<]{1,3}` capture. These tests pin the four shapes we now
    /// handle so the regression can't return.
    func testStripDropcapSpans_imageBasedDropcap_substitutesAltLetter() throws {
        let html = """
        <p class="nind"><span class="letra">
        <img alt="M" src="i_035_b.png"/></span>R. BENNET was among the earliest…</p>
        """
        let out = EPUBDocumentImporter.stripDropcapSpans(from: Data(html.utf8))
        let result = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(result.contains("MR. BENNET"),
                      "image-based drop cap should resolve to 'MR. BENNET'; got: \(result)")
        XCTAssertFalse(result.contains("<img"),
                       "image tag should be replaced wholesale; got: \(result)")
        XCTAssertFalse(result.contains("<span"),
                       "wrapping span should be stripped; got: \(result)")
    }

    func testStripDropcapSpans_textBasedDropcap_preservesLetter() throws {
        // Pre-existing case (Alice EPUB): text inside the span.
        let html = #"<p><span class="dropcap">A</span>lice was beginning to get very tired</p>"#
        let out = EPUBDocumentImporter.stripDropcapSpans(from: Data(html.utf8))
        let result = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(result.contains("Alice was beginning"),
                      "text-based drop cap should resolve to 'Alice'; got: \(result)")
        XCTAssertFalse(result.contains("<span"))
    }

    func testStripDropcapSpans_inlineFloatStyle_preservesLetter() throws {
        let html = #"<p><span style="float:left;font-size:50px;">A</span>lice opened the door</p>"#
        let out = EPUBDocumentImporter.stripDropcapSpans(from: Data(html.utf8))
        let result = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(result.contains("Alice opened the door"),
                      "inline-float drop cap should resolve to 'Alice'; got: \(result)")
    }

    func testStripDropcapSpans_leavesNonDropcapSpansAlone() throws {
        // Guard: a wider inline span (footnote ref, citation chip,
        // styled emphasis) must NOT be eaten by the dropcap stripper.
        // The {1,3} cap on inner content is the protection.
        let html = #"<p>She said <span class="emphasis">absolutely nothing</span> on the subject.</p>"#
        let out = EPUBDocumentImporter.stripDropcapSpans(from: Data(html.utf8))
        let result = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(result.contains("<span class=\"emphasis\">absolutely nothing</span>"),
                      "non-dropcap span must be preserved; got: \(result)")
    }
}
