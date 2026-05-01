import XCTest
@testable import Posey

final class PDFTOCDetectorTests: XCTestCase {

    // MARK: - Real-world TOC (taken verbatim from "The Internet Steps to the Beat.pdf")

    /// Page 1 of the actual scholarly paper Mark imported. Contains a
    /// classic dot-leader TOC with numbered roman headings, lettered
    /// subheadings, numeric subsubheadings, and lower-case sub-sub-sub.
    /// Every entry must be detected so the reader skips past it.
    private let realTOCPage = """
    The Internet Steps to the Beat 9/11/25, 1:33 PM The Wayback Machine - https://web.archive.org/web/20010522040702/http://www.linkvibe.com:80/mark/internetdrum.html The Internet Steps to the Beat Of a Different Drum: The R.I.A.A., mp3.com Saga. Information wants to be free…. - Anonymous Mark Friedlander Telecommunications Law Scholarly Writing Paper Fall 2000 Table of Contents I. Introduction.... 3 II. Technology...... 6 A. The Internet..... 6 B. mp3 9 C. my.mp3.com.. 11 D. Beam-it™. 12 E. User Identification 13 F. Compact Disk Verification 14 III. Copyright, Music, and Technology Law. 15 A. Elements of a Valid Copyright... 16 B. Exclusive Rights of the Copyright Holder.... 17 1. Reproduction, Distribution, and Performance.. 17 D. Fair Use. 20 1. Audio Home Recording Act 21 a. Time Shifting. 21 b. Space Shifting. 22 G. Contributory Infringement and Vicarious Liability... 23 1. ISP Safe Harbor.. 23 III. RIAA v. mp3.com and Other Potential Claims 24 A. Reproduction of the Compact Disks 26 B. Reproduction During Verification 28 C. Distribution and Performance on the Internet 29 D. Other Defenses.... 30 IIII. Conclusions, Policy and Recommendations 31 V. Bibliography... 36 https://web.archive.org/web/20010522040702/http://www.linkvibe.com/mark/internetdrum.html Page 1 of 15
    """

    private let realBodyPage1 = """
    The Internet Steps to the Beat 9/11/25, 1:33 PM I. Introduction Imagine it is the end of a long hard workweek. Finally, its here and you are on your way to your best friend's house for a potluck dinner to celebrate the beginning of a well-deserved weekend. Some of the guests were told to bring food, others wine. However, you, a disk jockey by trade, were told to bring the music. Your friends love to listen to you play from your extensive music collection but unfortunately when you arrive across town you realize that you have forgotten the tunes.
    """

    func testDetectsRealWorldTOCRegion() {
        let result = PDFTOCDetector.detect(pageTexts: [realTOCPage, realBodyPage1])
        XCTAssertNotNil(result, "detector failed to identify the TOC page")
        guard let result else { return }
        XCTAssertEqual(result.regionStartOffset, 0,
                       "TOC starts on page 1 ⇒ region begins at offset 0")
        // End offset should land just past page 1 + the "\n\n" separator.
        XCTAssertEqual(result.regionEndOffset, realTOCPage.count + 2)
    }

    func testParsesEntriesFromRealTOC() {
        let result = PDFTOCDetector.detect(pageTexts: [realTOCPage, realBodyPage1])
        guard let result else { return XCTFail("no result") }
        // Don't pin every entry — title parsing is best-effort. Verify
        // we picked up the major headings and the page numbers match.
        let titles = result.entries.map(\.title)
        let hasIntroduction = titles.contains(where: { $0.contains("Introduction") })
        let hasTechnology   = titles.contains(where: { $0.contains("Technology") })
        let hasBibliography = titles.contains(where: { $0.contains("Bibliography") })
        XCTAssertTrue(hasIntroduction, "missing 'Introduction' entry; got: \(titles)")
        XCTAssertTrue(hasTechnology, "missing 'Technology' entry; got: \(titles)")
        XCTAssertTrue(hasBibliography, "missing 'Bibliography' entry; got: \(titles)")
        // At least 8 entries (the TOC has many more — roughly 25 — but we
        // accept best-effort).
        XCTAssertGreaterThanOrEqual(result.entries.count, 8,
                                    "expected at least 8 detected entries; got \(result.entries.count)")
    }

    func testNoFalsePositiveOnNonTOCDocument() {
        // A document with prose only — no TOC anchor, no dot-leader entries.
        let pages = [
            """
            Chapter One. The reader settled into the chair and opened the book.
            Difficult prose rewards patience above all else. The cadence of
            careful argument is itself an argument.
            """,
            """
            Chapter Two. When read aloud, prose finds its truer shape.
            A page of dense text is also a topography. The eye learns the page;
            the mind learns the thought.
            """
        ]
        XCTAssertNil(PDFTOCDetector.detect(pageTexts: pages),
                     "detector triggered on a document with no TOC")
    }

    func testNoFalsePositiveOnTOCAnchorWithoutDotLeaders() {
        // The phrase "Table of Contents" appearing in body prose without
        // any actual entries should NOT trigger a skip region — that
        // would silently swallow real content.
        let pages = [
            "The Table of Contents in modern publishing has evolved over time. " +
            "Authors today consider how readers navigate documents. The structure " +
            "matters. Discussions about Contents pages fill chapters of bibliographic theory.",
            "Body content continues here with normal prose."
        ]
        XCTAssertNil(PDFTOCDetector.detect(pageTexts: pages))
    }

    func testDetectsMultiPageTOCContinuation() {
        // Synthetic two-page TOC — the second page has no anchor but still
        // looks dominated by entries.
        let tocPage1 = """
        Table of Contents
        I. Introduction................. 3
        II. Background................ 12
        III. Method................... 24
        IV. Results.................. 35
        V. Discussion................ 47
        """
        let tocPage2 = """
        VI. Conclusion............... 58
        VII. References.............. 70
        VIII. Appendix A............. 82
        IX. Appendix B............... 88
        X. Index..................... 95
        """
        let bodyPage = """
        Introduction
        This is the actual body of the paper. It begins on page 3 of the
        original printing. Difficult prose rewards patience.
        """
        let result = PDFTOCDetector.detect(pageTexts: [tocPage1, tocPage2, bodyPage])
        XCTAssertNotNil(result)
        guard let result else { return }
        // Region should span both TOC pages.
        let expectedEnd = tocPage1.count + 2 + tocPage2.count + 2
        XCTAssertEqual(result.regionEndOffset, expectedEnd,
                       "TOC region should extend across both TOC pages")
    }

    func testDoesNotPickUpTOCAnchorOutsideEarlyPages() {
        // A TOC-looking page found late in the document (page 6) is
        // suspect — could be an inline TOC inside a section. Detector
        // is configured to only look in the first 5 pages.
        let bodyPage = """
        The reader settled into the chair. Difficult prose rewards patience.
        """
        let lateTOCPage = """
        Table of Contents
        I. Late TOC.................. 1
        II. Should not match........ 2
        III. Detector ignores....... 3
        IV. Anything past page 5.... 4
        V. So this is fine.......... 5
        """
        let pages = Array(repeating: bodyPage, count: 5) + [lateTOCPage]
        XCTAssertNil(PDFTOCDetector.detect(pageTexts: pages))
    }
}
