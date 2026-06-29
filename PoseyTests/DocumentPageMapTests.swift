import XCTest
@testable import Posey

// ========== BLOCK 01: PAGE MAP TESTS - START ==========
/// Coverage for `DocumentPageMap`. The map is built from existing
/// document data (no schema migration in v1), so the tests assert
/// the per-format derivation rules behave as expected.
final class DocumentPageMapTests: XCTestCase {

    // MARK: - Empty / hasPages contract

    func testEmptyMapReportsNoPages() {
        let map = DocumentPageMap.empty
        XCTAssertFalse(map.hasPages)
        XCTAssertEqual(map.pageCount, 0)
        XCTAssertNil(map.pageRange)
        XCTAssertNil(map.offset(forPage: 1))
    }

    func testNonPaginatedFileTypesProduceEmptyMap() {
        let txt = makeDocument(fileType: "txt", displayText: "abc", plainText: "abc")
        let md  = makeDocument(fileType: "md",  displayText: "abc", plainText: "abc")
        let rtf = makeDocument(fileType: "rtf", displayText: "abc", plainText: "abc")
        let docx = makeDocument(fileType: "docx", displayText: "abc", plainText: "abc")
        let html = makeDocument(fileType: "html", displayText: "abc", plainText: "abc")
        for doc in [txt, md, rtf, docx, html] {
            let map = DocumentPageMap.build(for: doc, tocEntries: [])
            XCTAssertFalse(map.hasPages, "\(doc.fileType) must produce an empty map")
        }
    }

    // MARK: - PDF builder (units-based — audit fix #3, 2026-06-08)

    /// Three plain text pages, no visual pages. Offsets must match the
    /// global plainText space (prose units joined by "\n\n"):
    ///   page 1 → 0
    ///   page 2 → len(page1) + 2
    ///   page 3 → len(page1) + 2 + len(page2) + 2
    func testPDFThreePlainPagesMapsCorrectOffsets() {
        let units = pdfUnits(pages: [.text("Hello"),            // 5
                                     .text("World again"),       // 11
                                     .text("Final page text.")]) // 16
        let map = DocumentPageMap.buildForPDF(
            units: units, plainTextOffsetByUnitID: offsetMap(for: units))
        XCTAssertEqual(map.pageCount, 3)
        XCTAssertEqual(map.offset(forPage: 1), 0)
        XCTAssertEqual(map.offset(forPage: 2), 5 + 2)
        XCTAssertEqual(map.offset(forPage: 3), 5 + 2 + 11 + 2)
        XCTAssertNil(map.offset(forPage: 0))
        XCTAssertNil(map.offset(forPage: 4))
    }

    /// THE DRIFT REGRESSION (audit confirmed finding #4). A visual /
    /// cover / figure page contributes nothing to plainText, so it must
    /// NOT add a phantom "\n\n" separator. Page 2 here is visual; page 3's
    /// text begins right after page 1 + "\n\n" = 11. The OLD form-feed
    /// implementation drifted page 3 to 13 (it added a separator for the
    /// visual page). The visual page itself resolves to the next text (11).
    func testPDFVisualPageDoesNotDriftOffsets() {
        let units = pdfUnits(pages: [.text("Page one."),        // 9 chars
                                     .visual,                    // contributes 0
                                     .text("Page three text.")]) // 16 chars
        let map = DocumentPageMap.buildForPDF(
            units: units, plainTextOffsetByUnitID: offsetMap(for: units))
        XCTAssertEqual(map.pageCount, 3)
        XCTAssertEqual(map.offset(forPage: 1), 0)
        // Visual page 2 → next text content (start of page 3), no drift.
        XCTAssertEqual(map.offset(forPage: 2), 9 + 2)
        // Page 3 starts at 11 — NOT 13. No phantom separator for the visual page.
        XCTAssertEqual(map.offset(forPage: 3), 9 + 2)
    }

    /// A leading visual cover page (the common case) must not push the
    /// body's offsets off by the cover.
    func testPDFLeadingCoverPage() {
        let units = pdfUnits(pages: [.visual,                    // cover
                                     .text("Chapter one begins.")])
        let map = DocumentPageMap.buildForPDF(
            units: units, plainTextOffsetByUnitID: offsetMap(for: units))
        XCTAssertEqual(map.pageCount, 2)
        XCTAssertEqual(map.offset(forPage: 1), 0)   // cover → start of body
        XCTAssertEqual(map.offset(forPage: 2), 0)   // body text starts at 0
    }

    /// A blank page is skipped by the importer (no pageBreak unit), leaving
    /// a gap in pageNumber. The dense map backfills it with the previous
    /// offset so a typed in-gap page lands reasonably, not out of range.
    func testPDFBlankPageGapBackfills() {
        // Pages 0 and 2 present (1-based: 1 and 3); page index 1 blank/skipped.
        let units = pdfUnits(pageNumbers: [0, 2],
                             pages: [.text("First page."),       // 11
                                     .text("Third page text.")]) // 16
        let map = DocumentPageMap.buildForPDF(
            units: units, plainTextOffsetByUnitID: offsetMap(for: units))
        XCTAssertEqual(map.pageCount, 3)
        XCTAssertEqual(map.offset(forPage: 1), 0)
        XCTAssertEqual(map.offset(forPage: 2), 0,
                       "Skipped blank page backfills to the previous offset")
        XCTAssertEqual(map.offset(forPage: 3), 11 + 2)
    }

    func testPDFEmptyUnitsProducesEmptyMap() {
        XCTAssertFalse(DocumentPageMap.buildForPDF(
            units: [], plainTextOffsetByUnitID: [:]).hasPages)
    }

    func testPDFSinglePage() {
        let units = pdfUnits(pages: [.text("Single page document.")])
        let map = DocumentPageMap.buildForPDF(
            units: units, plainTextOffsetByUnitID: offsetMap(for: units))
        XCTAssertEqual(map.pageCount, 1)
        XCTAssertEqual(map.offset(forPage: 1), 0)
    }

    // MARK: - EPUB builder

    /// hocr-to-epub-style: spine items titled "Page N" with monotonic
    /// offsets. Expected map matches the entries verbatim.
    func testEPUBPageTitledTOCBuildsDenseMap() {
        let entries: [StoredTOCEntry] = [
            .init(title: "Page 1", plainTextOffset: 0,    unitID: UUID(), playOrder: 1),
            .init(title: "Page 2", plainTextOffset: 1500, unitID: UUID(), playOrder: 2),
            .init(title: "Page 3", plainTextOffset: 3000, unitID: UUID(), playOrder: 3),
        ]
        let map = DocumentPageMap.buildForEPUB(tocEntries: entries)
        XCTAssertEqual(map.pageCount, 3)
        XCTAssertEqual(map.offset(forPage: 1), 0)
        XCTAssertEqual(map.offset(forPage: 2), 1500)
        XCTAssertEqual(map.offset(forPage: 3), 3000)
    }

    /// Out-of-order TOC entries must produce a sorted page map.
    func testEPUBOutOfOrderEntriesAreSorted() {
        let entries: [StoredTOCEntry] = [
            .init(title: "Page 3", plainTextOffset: 3000, unitID: UUID(), playOrder: 3),
            .init(title: "Page 1", plainTextOffset: 0,    unitID: UUID(), playOrder: 1),
            .init(title: "Page 2", plainTextOffset: 1500, unitID: UUID(), playOrder: 2),
        ]
        let map = DocumentPageMap.buildForEPUB(tocEntries: entries)
        XCTAssertEqual(map.offset(forPage: 1), 0)
        XCTAssertEqual(map.offset(forPage: 2), 1500)
        XCTAssertEqual(map.offset(forPage: 3), 3000)
    }

    /// Gaps in the page-numbering get backfilled with the last known
    /// offset so the lookup is safe (no out-of-range explosion) and
    /// jumps somewhere reasonable.
    func testEPUBGapsBackfillWithPreviousOffset() {
        let entries: [StoredTOCEntry] = [
            .init(title: "Page 1", plainTextOffset: 0,    unitID: UUID(), playOrder: 1),
            .init(title: "Page 2", plainTextOffset: 1500, unitID: UUID(), playOrder: 2),
            // No "Page 3" entry — gap.
            .init(title: "Page 4", plainTextOffset: 4500, unitID: UUID(), playOrder: 4),
        ]
        let map = DocumentPageMap.buildForEPUB(tocEntries: entries)
        XCTAssertEqual(map.pageCount, 4)
        XCTAssertEqual(map.offset(forPage: 3), 1500,
                       "Missing page should backfill to the previous known offset")
    }

    /// Non-page-titled TOC (chapter-only, e.g. a normal EPUB with a
    /// real navMap) → empty map. The Go-to-page input stays hidden in
    /// the UI for these docs; chapter-level navigation is the right
    /// affordance.
    func testEPUBChapterOnlyTOCProducesEmptyMap() {
        let entries: [StoredTOCEntry] = [
            .init(title: "Introduction",        plainTextOffset: 0,    unitID: UUID(), playOrder: 1),
            .init(title: "Chapter One",         plainTextOffset: 5000, unitID: UUID(), playOrder: 2),
            .init(title: "Chapter Two: Onward", plainTextOffset: 9000, unitID: UUID(), playOrder: 3),
        ]
        XCTAssertFalse(DocumentPageMap.buildForEPUB(tocEntries: entries).hasPages)
    }

    /// "Page" must be a word boundary — entries titled "Pageant",
    /// "Backstage Pages", or other false-positive shapes must not be
    /// misread as page-numbered. The `\bpage\b` regex rejects both:
    ///   "Pageant" → 'page' is followed by 'a', not a word boundary
    ///   "Pages"   → 'page' is followed by 's', not a word boundary
    /// This locks the behavior down: real data is overwhelmingly
    /// "Page N" (singular) coming from the spine synthesizer for
    /// scanned EPUBs.
    func testEPUBWordBoundaryRespected() {
        let entries: [StoredTOCEntry] = [
            .init(title: "Pageant of Empire",  plainTextOffset: 0,    unitID: UUID(), playOrder: 1),
            .init(title: "Backstage Pages 5",  plainTextOffset: 1500, unitID: UUID(), playOrder: 2),
        ]
        let map = DocumentPageMap.buildForEPUB(tocEntries: entries)
        XCTAssertFalse(map.hasPages,
                       "Neither 'Pageant' nor 'Pages 5' should match the singular 'Page N' pattern")
    }

    /// Negative offsets indicate "couldn't resolve href" — those
    /// entries are skipped at map build time so the user can't end up
    /// at offset -1.
    func testEPUBSkipsEntriesWithUnresolvedOffset() {
        let entries: [StoredTOCEntry] = [
            .init(title: "Page 1", plainTextOffset: 0,    unitID: UUID(), playOrder: 1),
            .init(title: "Page 2", plainTextOffset: -1,   unitID: UUID(), playOrder: 2),
            .init(title: "Page 3", plainTextOffset: 3000, unitID: UUID(), playOrder: 3),
        ]
        let map = DocumentPageMap.buildForEPUB(tocEntries: entries)
        // Page 2 was skipped; gap-fill applies — Page 2 backfills
        // to Page 1's offset.
        XCTAssertEqual(map.offset(forPage: 1), 0)
        XCTAssertEqual(map.offset(forPage: 2), 0,
                       "Skipped entry's slot should backfill from the previous known offset")
        XCTAssertEqual(map.offset(forPage: 3), 3000)
    }

    func testEPUBEmptyEntriesProducesEmptyMap() {
        XCTAssertFalse(DocumentPageMap.buildForEPUB(tocEntries: []).hasPages)
    }

    // MARK: - PDF test helpers

    /// A page's content for the PDF unit builder below.
    fileprivate enum PDFPageContent {
        case text(String)
        case visual   // a cover/figure page → an .image unit (no prose)
    }

    /// Build the unit list the PDF importer would produce: a `pageBreak`
    /// unit (0-based pageNumber) before each page, then a prose or image
    /// unit. Mirrors `ContentUnitBuilder.unitsFromPDFDisplayText`.
    /// `pageNumbers` lets tests inject gaps (blank pages the importer skips).
    private func pdfUnits(pageNumbers: [Int]? = nil,
                          pages: [PDFPageContent]) -> [ContentUnit] {
        let docID = UUID()
        var units: [ContentUnit] = []
        var seq = 10
        for (i, page) in pages.enumerated() {
            let pn = pageNumbers?[i] ?? i
            units.append(ContentUnit(documentID: docID, sequence: seq, kind: .pageBreak,
                                     text: "", metadata: ContentUnitMetadata(pageNumber: pn)))
            seq += 10
            switch page {
            case .text(let t):
                units.append(ContentUnit(documentID: docID, sequence: seq, kind: .prose, text: t))
            case .visual:
                units.append(ContentUnit(documentID: docID, sequence: seq, kind: .image,
                                         text: "Visual content",
                                         metadata: ContentUnitMetadata(imageID: "img-\(i)")))
            }
            seq += 10
        }
        return units
    }

    /// Replicate `ReaderViewModel.computeContentFromUnits`'s global
    /// plainText offset assignment: each unit records the cumulative
    /// offset; only prose-bearing units advance it (text.count + 2 for the
    /// "\n\n" join). So pageBreak/image units record the offset of the next
    /// prose content — exactly what the production offset map carries.
    private func offsetMap(for units: [ContentUnit]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        var cumulative = 0
        for u in units {
            map[u.id] = cumulative
            if u.kind.carriesProseText { cumulative += u.text.count + 2 }
        }
        return map
    }

    // MARK: - Helpers

    private func makeDocument(fileType: String, displayText: String, plainText: String) -> Document {
        Document(
            id: UUID(),
            title: "Test",
            fileName: "test.\(fileType)",
            fileType: fileType,
            importedAt: .now,
            modifiedAt: .now,
            displayText: displayText,
            plainText: plainText,
            characterCount: plainText.count
        )
    }
}
// ========== BLOCK 01: PAGE MAP TESTS - END ==========
