import XCTest
@testable import Posey

// ========== BLOCK 01: SPINE-FALLBACK TOC TESTS - START ==========
/// Confirms that EPUB documents whose nav.xhtml / toc.ncx documents are
/// empty still produce a usable TOC. Auto-generated EPUBs from scanner
/// pipelines (notably the Internet Archive's hocr-to-epub) ship with
/// stub TOC files containing no entries, which previously left the
/// reader's TOC button hidden. The spine-based fallback synthesizes
/// one entry per spine item using:
///   1. first <h1>/<h2>/<h3> tag's inner text
///   2. <title> element's inner text  ← hocr-to-epub uses this
///   3. file name stem ("page_1" → "page 1")
///   4. generic "Chapter N"
///
/// We can't easily construct a full EPUB inline in a test (it's a
/// zip-with-prescribed-structure), so this suite uses the `loadDocument`
/// directory entry-loader hook by writing a synthetic EPUB tree to a
/// temp directory and pointing the loader at it.
final class EPUBSpineTOCFallbackTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posey-epub-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// hocr-to-epub-style: empty nav + NCX, many spine pages with only
    /// `<title>Page N</title>` populated. We expect the synthesised TOC
    /// to have one entry per spine item, each titled "Page N".
    func testEmptyNavAndNCXFallsBackToSpineEntries() throws {
        try writeContainerXML()
        try writePackageOPF(
            spineHrefs: ["page_1.xhtml", "page_2.xhtml", "page_3.xhtml"],
            includeNav: true,
            includeNCX: true,
            navIsEmpty: true,
            ncxIsEmpty: true
        )
        try writeEmptyNav()
        try writeEmptyNCX()
        try writePage(filename: "page_1.xhtml", title: "Page 1", body: "First page body.")
        try writePage(filename: "page_2.xhtml", title: "Page 2", body: "Second page body.")
        try writePage(filename: "page_3.xhtml", title: "Page 3", body: "Third page body.")

        let parsed = try EPUBDocumentImporter().loadDocument(from: tempDir)

        XCTAssertEqual(parsed.tocEntries.count, 3,
                       "Expected one synthesised entry per spine item.")
        XCTAssertEqual(parsed.tocEntries.map { $0.title }, ["Page 1", "Page 2", "Page 3"])
        // Offsets must be monotonically non-decreasing — each entry
        // points at or after the previous chapter's start.
        let offsets = parsed.tocEntries.map { $0.plainTextOffset }
        for pair in zip(offsets, offsets.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1,
                                     "TOC offsets must be monotonically non-decreasing")
        }
        // Play orders are 1-based contiguous so the existing TOC sheet
        // (which uses playOrder as the SwiftUI list ID) renders right.
        XCTAssertEqual(parsed.tocEntries.map { $0.playOrder }, [1, 2, 3])
    }

    /// Spine items with real `<h1>` headings should use those over
    /// the `<title>` fallback.
    func testHeadingsBeatTitleFallback() throws {
        try writeContainerXML()
        try writePackageOPF(
            spineHrefs: ["one.xhtml", "two.xhtml"],
            includeNav: true,
            includeNCX: true,
            navIsEmpty: true,
            ncxIsEmpty: true
        )
        try writeEmptyNav()
        try writeEmptyNCX()
        try writePage(
            filename: "one.xhtml",
            title: "Page 1",
            body: "<h1>The Eye in the Pyramid</h1><p>Body.</p>"
        )
        try writePage(
            filename: "two.xhtml",
            title: "Page 2",
            body: "<h1>The Golden Apple</h1><p>Body.</p>"
        )

        let parsed = try EPUBDocumentImporter().loadDocument(from: tempDir)
        XCTAssertEqual(parsed.tocEntries.map { $0.title },
                       ["The Eye in the Pyramid", "The Golden Apple"])
    }

    /// Mid-priority fallback: filename stem when neither heading nor
    /// title yields anything meaningful.
    func testFilenameStemFallsBack() throws {
        try writeContainerXML()
        try writePackageOPF(
            spineHrefs: ["the_introduction.xhtml"],
            includeNav: true,
            includeNCX: true,
            navIsEmpty: true,
            ncxIsEmpty: true
        )
        try writeEmptyNav()
        try writeEmptyNCX()
        // Title and headings both empty → fall back to stem.
        try writePage(filename: "the_introduction.xhtml", title: "", body: "Body.")

        let parsed = try EPUBDocumentImporter().loadDocument(from: tempDir)
        XCTAssertEqual(parsed.tocEntries.count, 1)
        XCTAssertEqual(parsed.tocEntries.first?.title, "the introduction")
    }

    /// When the EPUB DOES have a populated nav, we use it — fallback
    /// must NOT override an existing TOC.
    func testPopulatedNavWinsOverFallback() throws {
        try writeContainerXML()
        try writePackageOPF(
            spineHrefs: ["c1.xhtml", "c2.xhtml"],
            includeNav: true,
            includeNCX: false,
            navIsEmpty: false,
            ncxIsEmpty: false
        )
        try writePopulatedNav(
            entries: [("Real Chapter One", "c1.xhtml"), ("Real Chapter Two", "c2.xhtml")]
        )
        try writePage(filename: "c1.xhtml", title: "Page 1",
                      body: "<h1>Should Not Appear</h1>One.")
        try writePage(filename: "c2.xhtml", title: "Page 2",
                      body: "<h1>Should Not Appear</h1>Two.")

        let parsed = try EPUBDocumentImporter().loadDocument(from: tempDir)
        XCTAssertEqual(parsed.tocEntries.map { $0.title },
                       ["Real Chapter One", "Real Chapter Two"],
                       "Fallback must not override a populated nav")
    }

    // MARK: - Synthetic EPUB tree helpers

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

    private func writePackageOPF(
        spineHrefs: [String],
        includeNav: Bool,
        includeNCX: Bool,
        navIsEmpty: Bool,
        ncxIsEmpty: Bool
    ) throws {
        let epubDir = tempDir.appendingPathComponent("EPUB", isDirectory: true)
        try FileManager.default.createDirectory(at: epubDir, withIntermediateDirectories: true)
        var manifest = ""
        for (i, href) in spineHrefs.enumerated() {
            manifest += #"<item id="ch\#(i)" href="\#(href)" media-type="application/xhtml+xml"/>\#n"#
        }
        if includeNav {
            manifest += #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\#n"#
        }
        if includeNCX {
            manifest += #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\#n"#
        }
        var spine = ""
        for (i, _) in spineHrefs.enumerated() {
            spine += #"<itemref idref="ch\#(i)"/>\#n"#
        }
        let toc = includeNCX ? #" toc="ncx""# : ""
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Test EPUB</dc:title>
            <dc:identifier id="bookid">test-id</dc:identifier>
          </metadata>
          <manifest>
            \(manifest)
          </manifest>
          <spine\(toc)>
            \(spine)
          </spine>
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
          <head>
            <meta content="test" name="dtb:uid"/>
          </head>
          <docTitle><text></text></docTitle>
          <navMap/>
        </ncx>
        """
        try xml.write(
            to: tempDir.appendingPathComponent("EPUB").appendingPathComponent("toc.ncx"),
            atomically: true, encoding: .utf8
        )
    }

    private func writePopulatedNav(entries: [(title: String, href: String)]) throws {
        let lis = entries.map {
            #"<li><a href="\#($0.href)">\#($0.title)</a></li>"#
        }.joined(separator: "\n")
        let xml = """
        <?xml version='1.0' encoding='utf-8'?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>Contents</title></head>
          <body>
            <nav epub:type="toc" role="doc-toc">
              <h2>Contents</h2>
              <ol>
                \(lis)
              </ol>
            </nav>
          </body>
        </html>
        """
        try xml.write(
            to: tempDir.appendingPathComponent("EPUB").appendingPathComponent("nav.xhtml"),
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
// ========== BLOCK 01: SPINE-FALLBACK TOC TESTS - END ==========
