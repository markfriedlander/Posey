import XCTest
@testable import Posey

// ========== BLOCK 01: GOLDEN CORPUS HARNESS - START ==========
//
// True-state read + automated regression for the 7 importers.
//
// WHY THIS EXISTS (2026-06-15, salvage): the old 600-cell accuracy
// matrix used a *manual phone verification* as the unit of regression.
// Every shared-importer change decayed hundreds of cells back to
// "re-verify", and re-verifying meant a human-paced phone loop. It
// never converged. This harness replaces decay's MECHANISM (not its
// goal): it re-runs every importer against the real corpus in seconds,
// off-device, and diffs the structured output (content units: reading
// order, kind, heading level, full text) against a committed golden.
// A regression = a golden diff, caught automatically on every commit.
//
// ONE TEST METHOD PER DOCUMENT — so a Swift trap in one importer is
// isolated by Xcode's crash-restart (the runner relaunches and
// continues to the next test), the survey always completes, and each
// document is an independently green/red regression cell.
//
// MODE: a golden is auto-written when missing (bootstrap — the
// true-state dump, NOT yet "blessed"); once it exists, the test FAILS
// on any diff. To re-bless after an intended importer change, delete
// that doc's file under __golden__/ and re-run.
//
// Real corpus only (Rule 7): files come from `Posey Test Materials/`.
//
final class GoldenCorpusDumpTests: XCTestCase {

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PoseyTests/
        .deletingLastPathComponent()   // repo root
    static let corpusDir = repoRoot.appendingPathComponent("Posey Test Materials")
    static let goldenDir = repoRoot.appendingPathComponent("PoseyTests/__golden__")

    enum Fmt { case txt, md, rtf, docx, epub, html, pdf }

    // ----- one method per document -----
    // TXT
    func test_txt_dracula()            async throws { try await check("dracula_345.txt", .txt) }
    func test_txt_mobydick()           async throws { try await check("02701_moby-dick.txt", .txt) }
    func test_txt_pride()              async throws { try await check("01342_pride-and-prejudice.txt", .txt) }
    func test_txt_timemachine()        async throws { try await check("time-machine_35.txt", .txt) }
    func test_txt_modestproposal()     async throws { try await check("modest-proposal_1080.txt", .txt) }
    func test_txt_dickinson()          async throws { try await check("dickinson-poems_12242.txt", .txt) }
    // MD
    func test_md_setext()              async throws { try await check("md_setext-headings.md", .md) }
    func test_md_vscode()              async throws { try await check("vscode_README.md", .md) }
    func test_md_pytorch()             async throws { try await check("pytorch_README.md", .md) }
    func test_md_pandoc()              async throws { try await check("md_pandoc-manual_book-length.md", .md) }
    // RTF
    func test_rtf_styled()             async throws { try await check("rtf_styled-headings.rtf", .rtf) }
    func test_rtf_letter()             async throws { try await check("rtf_business-letter.rtf", .rtf) }
    func test_rtf_image()              async throws { try await check("rtf_with-image.rtf", .rtf) }
    func test_rtf_aibook()             async throws { try await check("AI Book Collaboration Project.rtf", .rtf) }
    // DOCX
    func test_docx_headingstyles()     async throws { try await check("docx_heading-styles.docx", .docx) }
    func test_docx_boldheadings()      async throws { try await check("docx_bold-paragraph-headings.docx", .docx) }
    func test_docx_tablesimages()      async throws { try await check("docx_tables-and-images.docx", .docx) }
    func test_docx_proposal()          async throws { try await check("Proposal_Assistant_Article_Draft.docx", .docx) }
    // EPUB
    func test_epub_alice()             async throws { try await check("00011_alice-in-wonderland.epub", .epub) }
    func test_epub_frankenstein()      async throws { try await check("00084_frankenstein.epub", .epub) }
    func test_epub_pride()             async throws { try await check("01342_pride-and-prejudice.epub", .epub) }
    func test_epub_dracula()           async throws { try await check("dracula_345.epub", .epub) }
    func test_epub_mobydick()          async throws { try await check("02701_moby-dick.epub", .epub) }
    func test_epub_sherlock()          async throws { try await check("01661_adventures-of-sherlock-holmes.epub", .epub) }
    // HTML
    func test_html_mobydick()          async throws { try await check("02701_moby-dick.html", .html) }
    func test_html_wikipedia()         async throws { try await check("Wikipedia-Pride-and-Prejudice.html", .html) }
    func test_html_codinghorror()      async throws { try await check("codinghorror_no-code.html", .html) }
    func test_html_mdn()               async throws { try await check("mdn_http-caching.html", .html) }
    func test_html_taleoftwocities()   async throws { try await check("tale-of-two-cities_98.html", .html) }
    // PDF
    func test_pdf_resume()             async throws { try await check("Resume Sept 2001.pdf", .pdf) }
    func test_pdf_scannedtoc()         async throws { try await check("scanned-toc-test.pdf", .pdf) }
    func test_pdf_irs1040()            async throws { try await check("irs-1040-form.pdf", .pdf) }
    func test_pdf_attention()          async throws { try await check("attention-is-all-you-need_arxiv.pdf", .pdf) }
    func test_pdf_geb()                async throws { try await check("GEBen.pdf", .pdf) }

    // ----- bootstrap-or-compare for one document -----
    private func check(_ file: String, _ fmt: Fmt) async throws {
        let src = Self.corpusDir.appendingPathComponent(file)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "corpus file missing: \(file)")

        let dump = try await renderDump(file: src, fmt: fmt)

        try? FileManager.default.createDirectory(at: Self.goldenDir, withIntermediateDirectories: true)
        let goldenURL = Self.goldenDir.appendingPathComponent(file + ".golden.txt")
        let existing = try? String(contentsOf: goldenURL, encoding: .utf8)

        let unitCount = dump.components(separatedBy: "\n").filter { $0.hasPrefix("#") }.count
        print("SURVEY \(file) units=\(unitCount) bytes=\(dump.utf8.count)\(existing == nil ? " [NEW]" : "")")

        if existing == nil {
            try dump.write(to: goldenURL, atomically: true, encoding: .utf8)
        } else {
            XCTAssertEqual(existing, dump, "golden diff for \(file)")
        }
    }

    // ----- import via the SAME importer the app uses, dump units -----
    // @MainActor because the app imports on @MainActor (LibraryViewModel):
    // EPUB/HTML parse XHTML via NSAttributedString, which uses WebKit and
    // hard-asserts the main thread (HTMLDocumentImporter.loadText
    // dispatchPrecondition). Running off-main would trap — a harness bug,
    // not an app bug.
    @MainActor
    private func renderDump(file url: URL, fmt: Fmt) async throws -> String {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let db = try DatabaseManager(databaseURL: dbURL)

        let doc: Document
        switch fmt {
        case .txt:  doc = try TXTLibraryImporter(databaseManager: db).importDocument(from: url)
        case .md:   doc = try MarkdownLibraryImporter(databaseManager: db).importDocument(from: url)
        case .rtf:  doc = try RTFLibraryImporter(databaseManager: db).importDocument(from: url)
        case .docx: doc = try DOCXLibraryImporter(databaseManager: db).importDocument(from: url)
        case .epub: doc = try await EPUBLibraryImporter(databaseManager: db).importDocument(from: url)
        case .pdf:  doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: url)
        case .html: doc = try await HTMLLibraryImporter(databaseManager: db).importDocument(from: url)
        }

        let units = try db.units(for: doc.id)
        let refs = (try? db.unitSkipReferences(for: doc.id)) ?? (skipUnitID: nil, contentEndUnitID: nil)
        return format(doc: doc, units: units,
                      contentStart: refs.skipUnitID, contentEnd: refs.contentEndUnitID)
    }

    private func format(doc: Document, units: [ContentUnit],
                        contentStart: UUID?, contentEnd: UUID?) -> String {
        let sorted = units.sorted(by: { $0.sequence < $1.sequence })
        // How much the reader hides: units before content-start (skipped
        // front matter) and at/after content-end (trailing boilerplate).
        let startIdx = contentStart.flatMap { id in sorted.firstIndex(where: { $0.id == id }) }
        let endIdx   = contentEnd.flatMap { id in sorted.firstIndex(where: { $0.id == id }) }
        var out = ""
        out += "TITLE: \(doc.title)\n"
        out += "FILETYPE: \(doc.fileType)\n"
        out += "UNITS: \(units.count)\n"
        out += "READER-OPENS-AT-UNIT-INDEX: \(startIdx.map(String.init) ?? "0 (no skip)")\n"
        out += "READER-STOPS-AT-UNIT-INDEX: \(endIdx.map(String.init) ?? "\(sorted.count) (no trim)")\n"
        out += "----\n"
        for u in sorted {
            var tag = u.kind.rawValue
            if let lvl = u.metadata.headingLevel { tag += "(L\(lvl))" }
            if let m = u.metadata.listMarker { tag += "[\(m)]" }
            if let p = u.metadata.pageNumber { tag += "{p\(p)}" }
            if let img = u.metadata.imageID { tag += " img:\(img)" }
            var marker = ""
            if u.id == contentStart { marker = "  <<<< READER OPENS HERE" }
            if u.id == contentEnd   { marker = "  <<<< READER STOPS HERE (this + below hidden)" }
            let text = u.text.replacingOccurrences(of: "\n", with: "\\n")
            out += String(format: "#%04d  %-18@ | %@%@\n",
                          u.sequence, tag as NSString, text as NSString, marker as NSString)
        }
        // Image IDs are random per-import UUIDs (UUID().uuidString) — they
        // appear in the `img:` tag AND in placeholder text markers
        // ([[POSEY_VISUAL_PAGE:0:<uuid>]]). Redact them to a stable token so
        // the golden is deterministic. Image *count* and *position* still diff
        // if they genuinely change (the line count / sequence shifts); only the
        // random value is neutralized.
        return out.replacingOccurrences(
            of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "<UUID>", options: .regularExpression)
    }
}
// ========== BLOCK 01: GOLDEN CORPUS HARNESS - END ==========
