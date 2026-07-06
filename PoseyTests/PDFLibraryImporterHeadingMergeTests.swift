import XCTest
@testable import Posey

final class PDFLibraryImporterHeadingMergeTests: XCTestCase {
    private let cbaFixturePath = "/Users/markfriedlander/Desktop/Posey-backup-before-history-rewrite-20260519-222856/Posey Test Materials/2005 Codified Basic Agreement - Theatrical Motion Pictures.pdf"

    func testNormalizeTOCTitleStripsLeadingProseBeforeSectionMarker() {
        let dirtyTitle = "The references herein to payment to SAG shall mean payments to SAG for rateable distribution to the performers involved. 5.1 SUPPLEMENTAL MARKETS EXHIBITION OF"

        XCTAssertEqual(
            PDFLibraryImporter.normalizeTOCTitle(dirtyTitle),
            "5.1 SUPPLEMENTAL MARKETS EXHIBITION OF"
        )
    }

    func testNormalizeTOCTitlePreservesAlreadyCleanSectionTitle() {
        let cleanTitle = "5.2 SUPPLEMENTAL MARKETS EXHIBITION OF THEATRICAL MOTION PICTURES"

        XCTAssertEqual(PDFLibraryImporter.normalizeTOCTitle(cleanTitle), cleanTitle)
    }

    func testNormalizeTOCTitleStripsDuplicatedRomanPrefixBeforeHeadingMarker() {
        let dirtyTitle = "II Part II EGB Prelude"

        XCTAssertEqual(
            PDFLibraryImporter.normalizeTOCTitle(dirtyTitle),
            "Part II EGB Prelude"
        )
    }

    func testCoalesceWrappedTOCEntriesMergesNumberedContinuationLine() {
        let entries = [
            PDFTOCEntry(
                title: "5.1 Supplemental Markets Exhibition Of",
                plainTextOffset: 5200,
                playOrder: 5,
                level: 1
            ),
            PDFTOCEntry(
                title: "Theatrical Motion Pictures, The Principal Photography Of Which Commenced After",
                plainTextOffset: 5300,
                playOrder: 6,
                level: 1
            ),
            PDFTOCEntry(
                title: "5.2 Supplemental Markets Exhibition Of",
                plainTextOffset: 5400,
                playOrder: 7,
                level: 1
            )
        ]

        let merged = PDFLibraryImporter.coalesceWrappedTOCEntries(entries)

        XCTAssertEqual(merged.map(\.title), [
            "5.1 Supplemental Markets Exhibition Of Theatrical Motion Pictures, The Principal Photography Of Which Commenced After",
            "5.2 Supplemental Markets Exhibition Of"
        ])
        XCTAssertEqual(merged.map(\.playOrder), [5, 7])
    }

    func testCoalesceWrappedTOCEntriesMergesNearbyShortPrefixWithoutCueWord() {
        let entries = [
            PDFTOCEntry(
                title: "5.1 Supplemental Markets Exhibition",
                plainTextOffset: 5200,
                playOrder: 5,
                level: 1
            ),
            PDFTOCEntry(
                title: "Of Theatrical Motion Pictures, The Principal Photography Of Which Commenced After",
                plainTextOffset: 5260,
                playOrder: 6,
                level: 1
            )
        ]

        let merged = PDFLibraryImporter.coalesceWrappedTOCEntries(entries)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(
            merged[0].title,
            "5.1 Supplemental Markets Exhibition Of Theatrical Motion Pictures, The Principal Photography Of Which Commenced After"
        )
    }

    func testCoalesceWrappedTOCEntriesDoesNotMergeFarApartUnnumberedEntry() {
        let entries = [
            PDFTOCEntry(
                title: "5.1 Supplemental Markets Exhibition Of",
                plainTextOffset: 5200,
                playOrder: 5,
                level: 1
            ),
            PDFTOCEntry(
                title: "Special Introduction",
                plainTextOffset: 8600,
                playOrder: 6,
                level: 1
            )
        ]

        let merged = PDFLibraryImporter.coalesceWrappedTOCEntries(entries)

        XCTAssertEqual(merged.map(\.title), entries.map(\.title))
    }

    func testMergeResolvedHeadingLinesAbsorbsNumericLabelLine() {
        let label = PDFTextLine(
            text: "8.",
            fontSize: 18,
            isBold: true,
            isAllCaps: false,
            indentX: 72,
            midX: 82,
            yTop: 500,
            yBottom: 484,
            gapAbove: 16,
            pageIndex: 0
        )
        let title = PDFTextLine(
            text: "ORIGINAL EMPLOYMENT - PAY TELEVISION, VIDEODISC/VIDEOCASSETTE MARKETS",
            fontSize: 18,
            isBold: true,
            isAllCaps: true,
            indentX: 108,
            midX: 230,
            yTop: 500,
            yBottom: 484,
            gapAbove: 4,
            pageIndex: 0
        )
        let prose = PDFTextLine(
            text: "The provisions applicable to the employment of performers...",
            fontSize: 11,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 240,
            yTop: 430,
            yBottom: 416,
            gapAbove: 18,
            pageIndex: 0
        )

        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [(title.text, title)],
            allLines: [label, title, prose]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].line.text, "8. ORIGINAL EMPLOYMENT - PAY TELEVISION, VIDEODISC/VIDEOCASSETTE MARKETS")
        XCTAssertEqual(merged[0].consumedLines, [label, title])
    }

    func testMergeResolvedHeadingLinesDoesNotAbsorbSameRowProse() {
        let title = PDFTextLine(
            text: "WET, SNOW AND SMOKE WORK; EXTERIOR WORK",
            fontSize: 18,
            isBold: true,
            isAllCaps: true,
            indentX: 108,
            midX: 220,
            yTop: 500,
            yBottom: 484,
            gapAbove: 16,
            pageIndex: 0
        )
        let prose = PDFTextLine(
            text: "Background Actors Cooperative Committee and its decision of such dispute shall be final and binding.",
            fontSize: 11,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 240,
            yTop: 500,
            yBottom: 484,
            gapAbove: 12,
            pageIndex: 0
        )

        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [(title.text, title)],
            allLines: [prose, title]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].line.text, title.text)
        XCTAssertEqual(merged[0].consumedLines, [title])
    }

    func testMergeResolvedHeadingLinesDoesNotPullNextSectionNumberIntoPreviousHeading() {
        let sectionSeven = PDFTextLine(
            text: "THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED PRIOR TO FEBRUARY 1, 1960",
            fontSize: 18,
            isBold: true,
            isAllCaps: true,
            indentX: 108,
            midX: 240,
            yTop: 540,
            yBottom: 524,
            gapAbove: 16,
            pageIndex: 0
        )
        let sectionEightLabel = PDFTextLine(
            text: "8.",
            fontSize: 18,
            isBold: true,
            isAllCaps: false,
            indentX: 72,
            midX: 82,
            yTop: 500,
            yBottom: 484,
            gapAbove: 20,
            pageIndex: 0
        )
        let sectionEightTitle = PDFTextLine(
            text: "ORIGINAL EMPLOYMENT - PAY TELEVISION, VIDEODISC/VIDEOCASSETTE MARKETS",
            fontSize: 18,
            isBold: true,
            isAllCaps: true,
            indentX: 108,
            midX: 230,
            yTop: 500,
            yBottom: 484,
            gapAbove: 4,
            pageIndex: 0
        )

        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [(sectionSeven.text, sectionSeven), (sectionEightTitle.text, sectionEightTitle)],
            allLines: [sectionSeven, sectionEightLabel, sectionEightTitle]
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].line.text, sectionSeven.text)
        XCTAssertEqual(merged[0].consumedLines, [sectionSeven])
        XCTAssertEqual(merged[1].line.text, "8. ORIGINAL EMPLOYMENT - PAY TELEVISION, VIDEODISC/VIDEOCASSETTE MARKETS")
        XCTAssertEqual(merged[1].consumedLines, [sectionEightLabel, sectionEightTitle])
    }

    func testMergeResolvedHeadingLinesDoesNotAbsorbForwardProseFromContaminatedTOCTitle() {
        let headingStart = PDFTextLine(
            text: "THEATRICAL MOTION PICTURES, THE PRINCIPAL",
            fontSize: 18,
            isBold: true,
            isAllCaps: true,
            indentX: 108,
            midX: 220,
            yTop: 520,
            yBottom: 504,
            gapAbove: 16,
            pageIndex: 0
        )
        let headingEnd = PDFTextLine(
            text: "PHOTOGRAPHY OF WHICH COMMENCED BETWEEN",
            fontSize: 18,
            isBold: true,
            isAllCaps: true,
            indentX: 108,
            midX: 220,
            yTop: 500,
            yBottom: 484,
            gapAbove: 4,
            pageIndex: 0
        )
        let prose = PDFTextLine(
            text: "Theatrical motion pictures produced under a prior Producer-Screen Actors Guild agreement...",
            fontSize: 11,
            isBold: false,
            isAllCaps: false,
            indentX: 108,
            midX: 240,
            yTop: 480,
            yBottom: 464,
            gapAbove: 16,
            pageIndex: 0
        )

        let contaminatedTitle = "4. THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED BETWEEN JANUARY 31, 1960 AND JULY 21, 1980 RELEASED TO FREE TELEVISION Theatrical motion pictures produced under a prior Producer-Screen Actors Guild agreement..."
        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [(contaminatedTitle, headingStart)],
            allLines: [headingStart, headingEnd, prose]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(
            merged[0].line.text,
            "THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED BETWEEN"
        )
        XCTAssertEqual(merged[0].consumedLines, [headingStart, headingEnd])
    }

    func testMergeResolvedHeadingLinesUsesNormalizedWrappedSectionTitle() {
        let headingLabel = PDFTextLine(
            text: "5.1",
            fontSize: 18,
            isBold: true,
            isAllCaps: false,
            indentX: 72,
            midX: 82,
            yTop: 500,
            yBottom: 484,
            gapAbove: 16,
            pageIndex: 0
        )
        let headingStart = PDFTextLine(
            text: "SUPPLEMENTAL MARKETS EXHIBITION OF",
            fontSize: 18,
            isBold: true,
            isAllCaps: true,
            indentX: 108,
            midX: 220,
            yTop: 500,
            yBottom: 484,
            gapAbove: 4,
            pageIndex: 0
        )
        let headingEnd = PDFTextLine(
            text: "THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED AFTER",
            fontSize: 18,
            isBold: true,
            isAllCaps: true,
            indentX: 108,
            midX: 240,
            yTop: 480,
            yBottom: 464,
            gapAbove: 4,
            pageIndex: 0
        )

        let normalizedTitle = PDFLibraryImporter.normalizeTOCTitle(
            "The references herein to payment to SAG shall mean payments to SAG for rateable distribution to the performers involved. 5.1 SUPPLEMENTAL MARKETS EXHIBITION OF THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED AFTER"
        )
        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [(normalizedTitle, headingStart)],
            allLines: [headingLabel, headingStart, headingEnd]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(
            merged[0].line.text,
            "5.1 SUPPLEMENTAL MARKETS EXHIBITION OF THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED AFTER"
        )
        XCTAssertEqual(merged[0].consumedLines, [headingLabel, headingStart, headingEnd])
    }

    func testMergeResolvedHeadingLinesUsesTruncatedWrappedSectionTitle() {
        let headingLabel = PDFTextLine(
            text: "5.1",
            fontSize: 18,
            isBold: true,
            isAllCaps: false,
            indentX: 72,
            midX: 82,
            yTop: 500,
            yBottom: 484,
            gapAbove: 16,
            pageIndex: 0
        )
        let headingStart = PDFTextLine(
            text: "SUPPLEMENTAL MARKETS EXHIBITION OF",
            fontSize: 18,
            isBold: true,
            isAllCaps: true,
            indentX: 108,
            midX: 220,
            yTop: 500,
            yBottom: 484,
            gapAbove: 4,
            pageIndex: 0
        )
        let headingEnd = PDFTextLine(
            text: "THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED AFTER",
            fontSize: 18,
            isBold: true,
            isAllCaps: true,
            indentX: 108,
            midX: 240,
            yTop: 480,
            yBottom: 464,
            gapAbove: 4,
            pageIndex: 0
        )

        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [("5.1 SUPPLEMENTAL MARKETS EXHIBITION OF", headingStart)],
            allLines: [headingLabel, headingStart, headingEnd]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(
            merged[0].line.text,
            "5.1 SUPPLEMENTAL MARKETS EXHIBITION OF THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED AFTER"
        )
        XCTAssertEqual(merged[0].consumedLines, [headingLabel, headingStart, headingEnd])
    }

    func testMergeResolvedHeadingLinesAbsorbsShortDateTailFragment() {
        let headingLabel = PDFTextLine(
            text: "5.2 SUPPLEMENTAL MARKETS EXHIBITION OF",
            fontSize: 16,
            isBold: false,
            isAllCaps: true,
            indentX: 72,
            midX: 220,
            yTop: 610,
            yBottom: 592,
            gapAbove: 18,
            pageIndex: 0
        )
        let headingMiddle = PDFTextLine(
            text: "THEATRICAL MOTION PICTURES, THE PRINCIPAL",
            fontSize: 16,
            isBold: false,
            isAllCaps: true,
            indentX: 72,
            midX: 220,
            yTop: 591,
            yBottom: 573,
            gapAbove: 4,
            pageIndex: 0
        )
        let headingEnd = PDFTextLine(
            text: "PHOTOGRAPHY OF WHICH COMMENCED AFTER",
            fontSize: 16,
            isBold: false,
            isAllCaps: true,
            indentX: 72,
            midX: 220,
            yTop: 572,
            yBottom: 554,
            gapAbove: 4,
            pageIndex: 0
        )
        let tail = PDFTextLine(
            text: "OCTOBER 6, 19804",
            fontSize: 16,
            isBold: false,
            isAllCaps: true,
            indentX: 72,
            midX: 220,
            yTop: 553,
            yBottom: 535,
            gapAbove: 4,
            pageIndex: 0
        )

        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [("5.2 Supplemental Markets Exhibition of Theatrical Motion Pictures, the Principal Photography of which Commenced after October 6, 1980", headingLabel)],
            allLines: [headingLabel, headingMiddle, headingEnd, tail]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(
            merged[0].line.text,
            "5.2 SUPPLEMENTAL MARKETS EXHIBITION OF THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED AFTER OCTOBER 6, 19804"
        )
        XCTAssertEqual(merged[0].consumedLines, [headingLabel, headingMiddle, headingEnd, tail])
    }

    func testMergeResolvedHeadingLinesAbsorbsMixedCaseWrappedChapterTitleAfterLabel() {
        let chapterLabel = PDFTextLine(
            text: "CHAPTER X",
            fontSize: 18,
            isBold: false,
            isAllCaps: true,
            indentX: 72,
            midX: 200,
            yTop: 540,
            yBottom: 522,
            gapAbove: 22,
            pageIndex: 0
        )
        let titleLineA = PDFTextLine(
            text: "Levels of Description,",
            fontSize: 18,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 220,
            yTop: 519,
            yBottom: 501,
            gapAbove: 4,
            pageIndex: 0
        )
        let titleLineB = PDFTextLine(
            text: "and Computer Systems",
            fontSize: 18,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 220,
            yTop: 500,
            yBottom: 482,
            gapAbove: 4,
            pageIndex: 0
        )
        let prose = PDFTextLine(
            text: "Godel's string G, and a Bach fugue: they both have the property that they can be understood on different levels.",
            fontSize: 11,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 260,
            yTop: 460,
            yBottom: 442,
            gapAbove: 18,
            pageIndex: 0
        )

        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [("Chapter X: Levels of Description, and Computer Systems", chapterLabel)],
            allLines: [chapterLabel, titleLineA, titleLineB, prose]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(
            merged[0].line.text,
            "CHAPTER X Levels of Description, and Computer Systems"
        )
        XCTAssertEqual(merged[0].consumedLines, [chapterLabel, titleLineA, titleLineB])
    }

    func testMergeResolvedHeadingLinesAbsorbsShortSingleWordTailWhenTitlePrefixAdvances() {
        let label = PDFTextLine(
            text: "CHAPTER II",
            fontSize: 18,
            isBold: false,
            isAllCaps: true,
            indentX: 72,
            midX: 200,
            yTop: 540,
            yBottom: 522,
            gapAbove: 22,
            pageIndex: 0
        )
        let titleLine = PDFTextLine(
            text: "Meaning and Form",
            fontSize: 20,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 220,
            yTop: 519,
            yBottom: 501,
            gapAbove: 4,
            pageIndex: 0
        )
        let shortTail = PDFTextLine(
            text: "in Mathematics",
            fontSize: 20,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 220,
            yTop: 500,
            yBottom: 482,
            gapAbove: 4,
            pageIndex: 0
        )
        let prose = PDFTextLine(
            text: "Body paragraph starts after the heading.",
            fontSize: 11,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 250,
            yTop: 460,
            yBottom: 442,
            gapAbove: 20,
            pageIndex: 0
        )

        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [("Chapter II: Meaning and Form in Mathematics", label)],
            allLines: [label, titleLine, shortTail, prose]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(
            merged[0].line.text,
            "CHAPTER II Meaning and Form in Mathematics"
        )
        XCTAssertEqual(merged[0].consumedLines, [label, titleLine, shortTail])
    }

    func testMergeResolvedHeadingLinesAbsorbsSharedPrefixTailWithoutStealingBody() {
        let label = PDFTextLine(
            text: "CHAPTER XIX",
            fontSize: 18,
            isBold: false,
            isAllCaps: true,
            indentX: 72,
            midX: 200,
            yTop: 540,
            yBottom: 522,
            gapAbove: 22,
            pageIndex: 0
        )
        let titleLine = PDFTextLine(
            text: "Artificial Intelligence:",
            fontSize: 20,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 220,
            yTop: 519,
            yBottom: 501,
            gapAbove: 4,
            pageIndex: 0
        )
        let tail = PDFTextLine(
            text: "Prospects",
            fontSize: 20,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 220,
            yTop: 500,
            yBottom: 482,
            gapAbove: 4,
            pageIndex: 0
        )
        let prose = PDFTextLine(
            text: "The preceding dialogue triggers a discussion of how knowledge is represented.",
            fontSize: 11,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 260,
            yTop: 460,
            yBottom: 442,
            gapAbove: 20,
            pageIndex: 0
        )

        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [("Chapter XIX: Artificial Intelligence: Prospects", label)],
            allLines: [label, titleLine, tail, prose]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(
            merged[0].line.text,
            "CHAPTER XIX Artificial Intelligence: Prospects"
        )
        XCTAssertEqual(merged[0].consumedLines, [label, titleLine, tail])
    }

    func testMergeResolvedHeadingLinesAbsorbsMixedCaseTitleTailAfterColonLabel() {
        let label = PDFTextLine(
            text: "Introduction:",
            fontSize: 18,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 200,
            yTop: 520,
            yBottom: 502,
            gapAbove: 20,
            pageIndex: 0
        )
        let titleTail = PDFTextLine(
            text: "A Musico-Logical Offering",
            fontSize: 18,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 220,
            yTop: 501,
            yBottom: 483,
            gapAbove: 4,
            pageIndex: 0
        )
        let prose = PDFTextLine(
            text: "The book opens with the story of Bach's Musical Offering.",
            fontSize: 11,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 240,
            yTop: 462,
            yBottom: 444,
            gapAbove: 20,
            pageIndex: 0
        )

        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [("Introduction: A Musico-Logical Offering", label)],
            allLines: [label, titleTail, prose]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].line.text, "Introduction: A Musico-Logical Offering")
        XCTAssertEqual(merged[0].consumedLines, [label, titleTail])
    }

    func testMergeResolvedHeadingLinesDoesNotAbsorbProseSharingOnlyStopWords() {
        let proseA = PDFTextLine(
            text: "The references herein to payment to SAG shall mean",
            fontSize: 16,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 210,
            yTop: 664,
            yBottom: 646,
            gapAbove: 16,
            pageIndex: 0
        )
        let proseB = PDFTextLine(
            text: "payments to SAG for rateable distribution to the performers involved.",
            fontSize: 16,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 230,
            yTop: 646,
            yBottom: 628,
            gapAbove: 4,
            pageIndex: 0
        )
        let heading = PDFTextLine(
            text: "5.1 SUPPLEMENTAL MARKETS EXHIBITION OF",
            fontSize: 16,
            isBold: false,
            isAllCaps: true,
            indentX: 72,
            midX: 220,
            yTop: 609,
            yBottom: 591,
            gapAbove: 18,
            pageIndex: 0
        )

        let merged = PDFLibraryImporter.mergeResolvedHeadingLines(
            resolved: [("5.1 Supplemental Markets Exhibition of Theatrical Motion Pictures, the Principal Photography of which Commenced After June 30, 1971 but prior to July 21, 1980", heading)],
            allLines: [proseA, proseB, heading]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].line.text, heading.text)
        XCTAssertEqual(merged[0].consumedLines, [heading])
    }

    func testCoalesceWrappedTOCEntriesOnRealCBAFixture() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: cbaFixturePath),
            "CBA fixture not available on this machine"
        )

        let parsed = try PDFDocumentImporter().loadDocument(from: URL(fileURLWithPath: cbaFixturePath))
        let normalized = parsed.tocEntries.map(PDFLibraryImporter.normalizeTOCEntry)
        let coalesced = PDFLibraryImporter.coalesceWrappedTOCEntries(normalized)

        XCTAssertFalse(
            coalesced.contains { $0.title == "THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED AFTER JUNE 30, 1971 BUT PRIOR TO JULY 21, 1980" },
            "wrapped continuation should not survive as a standalone TOC row"
        )
        XCTAssertTrue(
            coalesced.contains {
                $0.title == "5.1 SUPPLEMENTAL MARKETS EXHIBITION OF THEATRICAL MOTION PICTURES, THE PRINCIPAL PHOTOGRAPHY OF WHICH COMMENCED AFTER JUNE 30, 1971 BUT PRIOR TO JULY 21, 1980"
            },
            "real CBA wrapped section should merge into one TOC title"
        )
    }
}
