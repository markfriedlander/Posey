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

    // MARK: - PDF builder

    /// Three pages of unequal length, no visual markers. Expected
    /// offsets:
    ///   page 1 → 0
    ///   page 2 → len(page1) + 2  (the "\n\n" separator in plainText)
    ///   page 3 → len(page1) + 2 + len(page2) + 2
    func testPDFThreePlainPagesMapsCorrectOffsets() {
        let p1 = "Hello"            // 5 chars
        let p2 = "World again"       // 11 chars
        let p3 = "Final page text."  // 16 chars
        let displayText = "\(p1)\u{000C}\(p2)\u{000C}\(p3)"
        let map = DocumentPageMap.buildForPDF(displayText: displayText)
        XCTAssertEqual(map.pageCount, 3)
        XCTAssertEqual(map.offset(forPage: 1), 0)
        XCTAssertEqual(map.offset(forPage: 2), 5 + 2)
        XCTAssertEqual(map.offset(forPage: 3), 5 + 2 + 11 + 2)
        XCTAssertNil(map.offset(forPage: 0))
        XCTAssertNil(map.offset(forPage: 4))
    }

    /// Visual page markers must NOT contribute to the plainText
    /// offset — they're stripped during plainText construction.
    func testPDFVisualPageMarkersAreStripped() {
        let marker = "[[POSEY_VISUAL_PAGE:2:abc-uuid]]"
        let p1 = "Page one."                      // 9 chars in plainText
        let p2 = marker                            // visual-only → 0 chars in plainText
        let p3 = "Page three text."                // 16 chars in plainText
        let displayText = "\(p1)\u{000C}\(p2)\u{000C}\(p3)"
        let map = DocumentPageMap.buildForPDF(displayText: displayText)
        XCTAssertEqual(map.pageCount, 3)
        XCTAssertEqual(map.offset(forPage: 1), 0)
        // Page 2 starts after page 1 + "\n\n".
        XCTAssertEqual(map.offset(forPage: 2), 9 + 2)
        // Page 3 starts after page 1 + "\n\n" + (visual page contributes 0) + "\n\n".
        XCTAssertEqual(map.offset(forPage: 3), 9 + 2 + 0 + 2)
    }

    func testPDFEmptyDisplayTextProducesEmptyMap() {
        XCTAssertFalse(DocumentPageMap.buildForPDF(displayText: "").hasPages)
    }

    func testPDFSingleNoFormFeedDocument() {
        let map = DocumentPageMap.buildForPDF(displayText: "Single page document.")
        XCTAssertEqual(map.pageCount, 1)
        XCTAssertEqual(map.offset(forPage: 1), 0)
    }

    // MARK: - EPUB builder

    /// hocr-to-epub-style: spine items titled "Page N" with monotonic
    /// offsets. Expected map matches the entries verbatim.
    func testEPUBPageTitledTOCBuildsDenseMap() {
        let entries: [StoredTOCEntry] = [
            .init(title: "Page 1", plainTextOffset: 0,    playOrder: 1),
            .init(title: "Page 2", plainTextOffset: 1500, playOrder: 2),
            .init(title: "Page 3", plainTextOffset: 3000, playOrder: 3),
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
            .init(title: "Page 3", plainTextOffset: 3000, playOrder: 3),
            .init(title: "Page 1", plainTextOffset: 0,    playOrder: 1),
            .init(title: "Page 2", plainTextOffset: 1500, playOrder: 2),
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
            .init(title: "Page 1", plainTextOffset: 0,    playOrder: 1),
            .init(title: "Page 2", plainTextOffset: 1500, playOrder: 2),
            // No "Page 3" entry — gap.
            .init(title: "Page 4", plainTextOffset: 4500, playOrder: 4),
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
            .init(title: "Introduction",        plainTextOffset: 0,    playOrder: 1),
            .init(title: "Chapter One",         plainTextOffset: 5000, playOrder: 2),
            .init(title: "Chapter Two: Onward", plainTextOffset: 9000, playOrder: 3),
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
            .init(title: "Pageant of Empire",  plainTextOffset: 0,    playOrder: 1),
            .init(title: "Backstage Pages 5",  plainTextOffset: 1500, playOrder: 2),
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
            .init(title: "Page 1", plainTextOffset: 0,    playOrder: 1),
            .init(title: "Page 2", plainTextOffset: -1,   playOrder: 2),
            .init(title: "Page 3", plainTextOffset: 3000, playOrder: 3),
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
