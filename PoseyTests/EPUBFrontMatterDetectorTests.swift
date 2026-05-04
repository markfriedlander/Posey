import XCTest
@testable import Posey

// ========== BLOCK 01: FRONT-MATTER DETECTOR TESTS - START ==========
/// Direct tests for `EPUBFrontMatterDetector` with verbatim Internet
/// Archive `notice.html` text and synthetic non-front-matter cases.
/// Confirms the heuristic is conservative — false positives on real
/// content are far worse than false negatives.
final class EPUBFrontMatterDetectorTests: XCTestCase {

    /// Verbatim opening of the IA notice file from Mark's Illuminatus
    /// EPUB. Spelling and punctuation match the on-disk content.
    private let verbatimIANotice = """
    <?xml version='1.0' encoding='utf-8'?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
      <head>
        <title>Notice</title>
      </head>
      <body>
        <div class="offset"><p dir="ltr">This book was produced in EPUB format by the Internet Archive.</p>
        <p dir="ltr">The book pages were scanned and converted to EPUB format automatically.</p>
        <p>Created with hocr-to-epub (v.1.0.0)</p>
        </div>
      </body>
    </html>
    """

    private let realBookContent = """
    <html><head><title>Page 1</title></head>
    <body><p>The history of the world is the history of the warfare between secret societies.</p>
    <p>It was the year when they finally immanentized the Eschaton.</p></body></html>
    """

    func testDetectsIANoticeAsFrontMatter() {
        let result = EPUBFrontMatterDetector.detect(spineItems: [
            .init(href: "notice.html", plainTextStartOffset: 0, html: verbatimIANotice),
            .init(href: "page_1.html", plainTextStartOffset: 1500, html: realBookContent)
        ])
        XCTAssertEqual(result.skipUntilOffset, 1500,
                       "Skip offset should advance to the start of the first non-front-matter item")
        XCTAssertEqual(result.frontMatterHrefs, ["notice.html"])
    }

    func testFlagsAllFrontMatterCandidatesEvenWhenInterleaved() {
        // Task 4 #5 (2026-05-03): the detector now scans ALL
        // candidates rather than break-on-first-non-match. The
        // Illuminatus IA-pipeline EPUB has nav.xhtml at spine[0]
        // (not front matter) and notice.html at spine[1] (real
        // disclaimer); the old break-on-first behavior missed
        // notice.html entirely. Flagging by href lets the importer
        // strip every match regardless of position.
        let result = EPUBFrontMatterDetector.detect(spineItems: [
            .init(href: "notice.html", plainTextStartOffset: 0, html: verbatimIANotice),
            .init(href: "page_0.html", plainTextStartOffset: 1500, html: realBookContent),
            .init(href: "second_notice.html", plainTextStartOffset: 2000, html: verbatimIANotice),
            .init(href: "page_1.html", plainTextStartOffset: 2500, html: realBookContent)
        ])
        XCTAssertEqual(
            result.frontMatterHrefs,
            ["notice.html", "second_notice.html"],
            "All front-matter-shaped items must be flagged; importer strips them by href"
        )
    }

    func testReturnsZeroSkipOnAllRealContent() {
        let result = EPUBFrontMatterDetector.detect(spineItems: [
            .init(href: "page_1.html", plainTextStartOffset: 0, html: realBookContent),
            .init(href: "page_2.html", plainTextStartOffset: 1000, html: realBookContent)
        ])
        XCTAssertEqual(result.skipUntilOffset, 0)
        XCTAssertTrue(result.frontMatterHrefs.isEmpty)
    }

    func testReturnsZeroSkipOnEmptyInput() {
        let result = EPUBFrontMatterDetector.detect(spineItems: [])
        XCTAssertEqual(result.skipUntilOffset, 0)
        XCTAssertTrue(result.frontMatterHrefs.isEmpty)
    }

    func testHandlesAllFrontMatterCorpus() {
        // Edge case: a doc that is entirely front matter. Detector
        // should not silence the document — skip offset stays at the
        // last known body start (which is "no item after notice"),
        // i.e. 0. Better to read the disclaimer aloud than to play
        // silence and confuse the user.
        let result = EPUBFrontMatterDetector.detect(spineItems: [
            .init(href: "notice.html", plainTextStartOffset: 0, html: verbatimIANotice)
        ])
        XCTAssertEqual(result.skipUntilOffset, 0,
                       "All-front-matter EPUBs must not be silenced — leave skip at 0")
        XCTAssertEqual(result.frontMatterHrefs, ["notice.html"],
                       "The href is still flagged so synthesized TOC can filter it")
    }

    func testDoesNotFlagWordNoticeInBodyProse() {
        // Prose mentioning "notice" in body text must not trip the
        // detector. The <title>Notice</title> heuristic is bracket-
        // anchored to the title element specifically.
        let proseWithWordNotice = """
        <html><head><title>Chapter 1</title></head>
        <body><p>He took notice of the strange light in the sky.</p></body></html>
        """
        let result = EPUBFrontMatterDetector.detect(spineItems: [
            .init(href: "chapter_1.html", plainTextStartOffset: 0, html: proseWithWordNotice)
        ])
        XCTAssertEqual(result.skipUntilOffset, 0)
        XCTAssertTrue(result.frontMatterHrefs.isEmpty)
    }

    func testCaseInsensitiveMatching() {
        // Uppercase variants of the IA marker should still match — IA
        // could change capitalisation in a future update without
        // changing the substantive disclaimer.
        let upper = verbatimIANotice
            .replacingOccurrences(of: "Internet Archive", with: "INTERNET ARCHIVE")
            .replacingOccurrences(of: "Notice", with: "NOTICE")
        let result = EPUBFrontMatterDetector.detect(spineItems: [
            .init(href: "notice.html", plainTextStartOffset: 0, html: upper),
            .init(href: "page_1.html", plainTextStartOffset: 1000, html: realBookContent)
        ])
        XCTAssertEqual(result.frontMatterHrefs, ["notice.html"])
    }
}
// ========== BLOCK 01: FRONT-MATTER DETECTOR TESTS - END ==========


// ========== BLOCK 02: END-TO-END EPUB IMPORT WITH FRONT MATTER - START ==========
/// Higher-level test: import a synthetic EPUB tree that mimics the
/// Internet Archive's hocr-to-epub layout (notice.html + page_*.html
/// with empty nav + NCX) and confirm the parsed document carries the
/// right `playbackSkipUntilOffset` and that the synthesized TOC
/// excludes the notice file.
final class EPUBImportFrontMatterIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posey-frontmatter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testIAStyleEPUBStripsFrontMatterFromExtractedText() throws {
        // Task 4 #5 (2026-05-03): front matter is now STRIPPED from
        // extracted plainText entirely (was: kept-with-skip-offset).
        // Contract:
        //   - plainText does not contain the disclaimer body
        //   - synthesized TOC does not include the notice entry
        //   - first surviving TOC entry is the first real body page
        // playbackSkipUntilOffset is no longer the load-bearing field
        // (front matter is gone, so there's nothing to skip past).
        try writeContainerXML()
        try writePackageOPF(spineHrefs: ["notice.html", "page_0.html", "page_1.html"])
        try writeEmptyNav()
        try writeEmptyNCX()
        try writeNoticeFile()
        try writePage(filename: "page_0.html", title: "Page 0",
                      body: "<p>Real content begins here. " + String(repeating: "x ", count: 500) + "</p>")
        try writePage(filename: "page_1.html", title: "Page 1",
                      body: "<p>And continues. " + String(repeating: "y ", count: 500) + "</p>")

        let parsed = try EPUBDocumentImporter().loadDocument(from: tempDir)

        XCTAssertFalse(
            parsed.plainText.contains("Internet Archive"),
            "IA disclaimer body must be removed from extracted plainText"
        )
        XCTAssertTrue(
            parsed.plainText.contains("Real content begins here"),
            "Real body content must remain after front-matter strip"
        )
        XCTAssertFalse(
            parsed.tocEntries.contains { $0.title.lowercased() == "notice" },
            "Synthesized TOC must exclude IA notice entry. Got titles: \(parsed.tocEntries.map { $0.title })"
        )
        XCTAssertEqual(parsed.tocEntries.first?.title, "Page 0")
    }

    func testNonIAEPUBHasZeroSkipOffset() throws {
        // EPUB with no front matter — skip offset must remain 0.
        try writeContainerXML()
        try writePackageOPF(spineHrefs: ["chapter_1.html", "chapter_2.html"])
        try writeEmptyNav()
        try writeEmptyNCX()
        try writePage(filename: "chapter_1.html", title: "Chapter 1",
                      body: "<p>Real content from the start.</p>")
        try writePage(filename: "chapter_2.html", title: "Chapter 2",
                      body: "<p>And continues.</p>")

        let parsed = try EPUBDocumentImporter().loadDocument(from: tempDir)
        XCTAssertEqual(parsed.playbackSkipUntilOffset, 0,
                       "Non-IA EPUBs must keep skip offset at 0")
    }

    // MARK: - Synthetic EPUB tree helpers (subset of fallback-test helpers)

    private func writeContainerXML() throws {
        let dir = tempDir.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="EPUB/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try xml.write(to: dir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
    }

    private func writePackageOPF(spineHrefs: [String]) throws {
        let epubDir = tempDir.appendingPathComponent("EPUB", isDirectory: true)
        try FileManager.default.createDirectory(at: epubDir, withIntermediateDirectories: true)
        var manifest = ""
        for (i, href) in spineHrefs.enumerated() {
            manifest += #"<item id="ch\#(i)" href="\#(href)" media-type="application/xhtml+xml"/>\#n"#
        }
        manifest += #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\#n"#
        manifest += #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\#n"#
        var spine = ""
        for (i, _) in spineHrefs.enumerated() {
            spine += #"<itemref idref="ch\#(i)"/>\#n"#
        }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Test EPUB</dc:title>
            <dc:identifier id="bookid">test-id</dc:identifier>
          </metadata>
          <manifest>\(manifest)</manifest>
          <spine toc="ncx">\(spine)</spine>
        </package>
        """
        try opf.write(to: epubDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
    }

    private func writeEmptyNav() throws {
        let xml = """
        <?xml version='1.0' encoding='utf-8'?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title></title></head>
          <body><nav epub:type="toc" role="doc-toc"><h2></h2><ol/></nav></body>
        </html>
        """
        try xml.write(
            to: tempDir.appendingPathComponent("EPUB").appendingPathComponent("nav.xhtml"),
            atomically: true, encoding: .utf8
        )
    }

    private func writeEmptyNCX() throws {
        let xml = """
        <?xml version='1.0' encoding='utf-8'?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta content="test" name="dtb:uid"/></head>
          <docTitle><text></text></docTitle>
          <navMap/>
        </ncx>
        """
        try xml.write(
            to: tempDir.appendingPathComponent("EPUB").appendingPathComponent("toc.ncx"),
            atomically: true, encoding: .utf8
        )
    }

    private func writeNoticeFile() throws {
        let xml = """
        <?xml version='1.0' encoding='utf-8'?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
          <head><title>Notice</title></head>
          <body>
            <div class="offset">
              <p dir="ltr">This book was produced in EPUB format by the Internet Archive.</p>
              <p>The book pages were scanned and converted to EPUB format automatically.</p>
              <p>Created with hocr-to-epub (v.1.0.0)</p>
            </div>
          </body>
        </html>
        """
        try xml.write(
            to: tempDir.appendingPathComponent("EPUB").appendingPathComponent("notice.html"),
            atomically: true, encoding: .utf8
        )
    }

    private func writePage(filename: String, title: String, body: String) throws {
        let xml = """
        <?xml version='1.0' encoding='utf-8'?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>\(title)</title></head>
          <body>\(body)</body>
        </html>
        """
        try xml.write(
            to: tempDir.appendingPathComponent("EPUB").appendingPathComponent(filename),
            atomically: true, encoding: .utf8
        )
    }
}
// ========== BLOCK 02: END-TO-END EPUB IMPORT WITH FRONT MATTER - END ==========


// ========== BLOCK 03: EMBEDDED TOC STRIP (Task 8 #2) - START ==========
/// Tests for the spine-embedded TOC stripper added 2026-05-03 so TTS
/// doesn't read the navigation list aloud. Three patterns we observed
/// in real-world EPUBs: Project Gutenberg's `<p class="toc">`,
/// Calibre's `<div class="toc">`, and the EPUB 3 ARIA
/// `<nav epub:type="toc">`.
final class EPUBEmbeddedTOCStripTests: XCTestCase {

    func testStripsProjectGutenbergPClassTOC() throws {
        // Real-world shape pulled from Pride and Prejudice (Gutenberg
        // EPUB) — `<p class="toc">` containing chapter anchors.
        let html = """
        <html><body>
          <h1>Pride and Prejudice</h1>
          <p>Real prose follows the table of contents.</p>
          <p class="toc">
            <a href="#CHAPTER_I">I.</a>, <a href="#CHAPTER_II">II.</a>,
            <a href="#CHAPTER_III">III.</a>
          </p>
          <p>This paragraph survives the strip.</p>
        </body></html>
        """
        let stripped = String(
            data: EPUBDocumentImporter.stripEmbeddedTOC(from: Data(html.utf8)),
            encoding: .utf8
        )!
        XCTAssertFalse(stripped.contains("CHAPTER_I"),
                       "TOC anchors must be stripped from spine HTML")
        XCTAssertFalse(stripped.contains("II."),
                       "TOC chapter labels must be stripped")
        XCTAssertTrue(stripped.contains("This paragraph survives"),
                      "Surrounding prose must be preserved")
        XCTAssertTrue(stripped.contains("Pride and Prejudice"),
                      "Title above the TOC must be preserved")
    }

    func testStripsCalibreDivClassTOC() throws {
        let html = """
        <html><body>
          <div class="toc">
            <p><a>Foreword</a></p>
            <p><a>Chapter 1</a></p>
          </div>
          <p>Body content.</p>
        </body></html>
        """
        let stripped = String(
            data: EPUBDocumentImporter.stripEmbeddedTOC(from: Data(html.utf8)),
            encoding: .utf8
        )!
        XCTAssertFalse(stripped.contains("Foreword"))
        XCTAssertFalse(stripped.contains("Chapter 1"))
        XCTAssertTrue(stripped.contains("Body content"))
    }

    func testStripsEPUB3ARIANavTOC() throws {
        let html = """
        <html><body>
          <nav epub:type="toc">
            <ol><li><a>One</a></li><li><a>Two</a></li></ol>
          </nav>
          <h1>Chapter 1</h1>
          <p>The story begins.</p>
        </body></html>
        """
        let stripped = String(
            data: EPUBDocumentImporter.stripEmbeddedTOC(from: Data(html.utf8)),
            encoding: .utf8
        )!
        XCTAssertFalse(stripped.contains("<ol>"),
                       "<nav epub:type=toc> body must be stripped")
        XCTAssertTrue(stripped.contains("Chapter 1"),
                      "Real chapter heading must survive")
        XCTAssertTrue(stripped.contains("The story begins"))
    }

    func testDoesNotStripUnrelatedClasses() throws {
        // Defensive: classes that happen to contain "toc" as a
        // substring (stockton, photocopy) must not match. The strip
        // requires "toc" as a distinct word-boundary-anchored token.
        let html = """
        <html><body>
          <p class="stockton">This stockton text must survive.</p>
          <p class="photocopy">Photocopy too.</p>
        </body></html>
        """
        let stripped = String(
            data: EPUBDocumentImporter.stripEmbeddedTOC(from: Data(html.utf8)),
            encoding: .utf8
        )!
        XCTAssertTrue(stripped.contains("stockton text"))
        XCTAssertTrue(stripped.contains("Photocopy too"))
    }
}
// ========== BLOCK 03: EMBEDDED TOC STRIP (Task 8 #2) - END ==========
