import XCTest
@testable import Posey

final class PDFHeadingKeyDeriverTests: XCTestCase {
    func testResolveHeadingsStepsBackToStartOfWrappedHeading() {
        let lines = [
            positionedLine("Body intro paragraph", font: 11, gap: 8, page: 0, top: 760, bottom: 748),
            positionedLine("Ten Do's", font: 18, gap: 28, page: 0, top: 720, bottom: 708),
            positionedLine("and Don'ts", font: 18, gap: 10, page: 0, top: 704, bottom: 692),
            positionedLine("Body paragraph follows here.", font: 11, gap: 24, page: 0, top: 664, bottom: 652),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Ten Do's and Don'ts"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.line.text, "Ten Do's")
    }

    func testResolveHeadingsIgnoresContentsLeaderListings() {
        let lines = [
            line("Chapter 7 The Real Work ........ 120", font: 18, gap: 28, page: 0),
            line("Body intro paragraph", font: 11, gap: 14, page: 0),
            line("Chapter 7 The Real Work", font: 18, gap: 32, page: 1),
            line("Body paragraph follows here.", font: 11, gap: 20, page: 1),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Chapter 7 The Real Work"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.line.pageIndex, 1)
        XCTAssertEqual(resolved.first?.line.text, "Chapter 7 The Real Work")
    }

    func testResolveHeadingsDropsLowPurityCoincidentalMatches() {
        let lines = [
            line("\"IS COMPOSED OF FIVE WORDS\" IS COMPOSED OF", font: 18, gap: 28, page: 0),
            line("Words of Thanks", font: 18, gap: 28, page: 1),
        ]

        let quality = PDFHeadingKeyDeriver.matchQuality(
            titleSet: Set(["words", "of", "thanks"]),
            text: lines[0].text
        )
        XCTAssertTrue(quality.matches)
        XCTAssertLessThan(quality.linePurity, 0.5)

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Words of Thanks"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.line.pageIndex, 1)
        XCTAssertEqual(resolved.first?.line.text, "Words of Thanks")
    }

    func testResolveHeadingsFallsBackWhenFontSignalIsMissing() {
        let lines = [
            line("Three-Part Invention 29", font: 0, gap: 2, page: 0),
            line("Three-Part Invention", font: 0, gap: 0, page: 1),
            line("Two-Part Invention", font: 0, gap: 0, page: 2),
            line("Meaning and Form", font: 0, gap: 28, page: 3),
            line("in Mathematics", font: 0, gap: 10, page: 3),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: [
                "Three-Part Invention",
                "Two-Part Invention",
                "Chapter II: Meaning and Form in Mathematics",
            ],
            allLines: lines,
            bodyStartIndex: 1
        )

        XCTAssertEqual(resolved.map(\.title), [
            "Three-Part Invention",
            "Two-Part Invention",
            "Chapter II: Meaning and Form in Mathematics",
        ])
        XCTAssertEqual(resolved.map(\.line.text), [
            "Three-Part Invention",
            "Two-Part Invention",
            "Meaning and Form",
        ])
    }

    func testResolveHeadingsPrefersClusteredChapterOpeningOverLaterRunningHeader() {
        let lines = [
            positionedLine("Body paragraph before chapter break.", font: 11, gap: 8, page: 0, top: 760, bottom: 748),
            positionedLine("CHAPTER XX", font: 18, gap: 0, page: 0, top: 720, bottom: 708),
            positionedLine("Strange Loops,", font: 18, gap: 14.6, page: 0, top: 694, bottom: 682),
            positionedLine("Or Tangled Hierarchies", font: 18, gap: 0.8, page: 0, top: 680, bottom: 668),
            positionedLine("Can Machines Possess", font: 16, gap: 14.5, page: 0, top: 654, bottom: 642),
            positionedLine("Originality?", font: 16, gap: 0.6, page: 0, top: 640, bottom: 628),
            positionedLine("Opening body prose begins here.", font: 11, gap: 14.1, page: 0, top: 614, bottom: 602),
            positionedLine("Body text continues across the chapter.", font: 11, gap: 8, page: 1, top: 760, bottom: 748),
            positionedLine("Strange Loops, Or Tangled Hierarchies", font: 18, gap: 13.0, page: 1, top: 710, bottom: 698),
            positionedLine("Running-header-adjacent prose continues immediately.", font: 11, gap: 0, page: 1, top: 696, bottom: 684),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Chapter XX: Strange Loops, Or Tangled Hierarchies"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.line.pageIndex, 0)
        XCTAssertEqual(resolved.first?.line.text, "CHAPTER XX")
    }

    func testResolveHeadingsPrefersTightTitleUnderChapterLabelOverLaterEmphasizedBodyQuestion() {
        let lines = [
            positionedLine("Bridge paragraph before chapter.", font: 11, gap: 8, page: 0, top: 760, bottom: 748),
            positionedLine("CHAPTER XX", font: 18, gap: 24, page: 0, top: 720, bottom: 708),
            positionedLine("Strange Loops, Or Tangled Hierarchies", font: 11, gap: 6, page: 0, top: 700, bottom: 688),
            positionedLine("Opening body prose begins here.", font: 11, gap: 14, page: 0, top: 660, bottom: 648),
            positionedLine("What is wrong with this Devil's advocate point of view? It is obviously the assumption that a machine cannot do Strange Loops, Or Tangled Hierarchies", font: 24, gap: 28, page: 1, top: 720, bottom: 708),
            positionedLine("Body prose continues after the emphasized question.", font: 11, gap: 10, page: 1, top: 690, bottom: 678),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Chapter XX: Strange Loops, Or Tangled Hierarchies"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.line.pageIndex, 0)
        XCTAssertEqual(resolved.first?.line.text, "CHAPTER XX")
    }

    func testResolveHeadingsAcceptsWrappedClusterUnderChapterLabelOverLaterBodyMention() {
        let lines = [
            positionedLine("Bridge paragraph before chapter.", font: 11, gap: 8, page: 0, top: 760, bottom: 748),
            positionedLine("CHAPTER XX", font: 18, gap: 24, page: 0, top: 720, bottom: 708),
            positionedLine("Strange Loops,", font: 11, gap: 6, page: 0, top: 700, bottom: 688),
            positionedLine("Or Tangled Hierarchies", font: 11, gap: 2, page: 0, top: 684, bottom: 672),
            positionedLine("Opening body prose begins here.", font: 11, gap: 14, page: 0, top: 660, bottom: 648),
            positionedLine("What is wrong with this Devil's advocate point of view? It is obviously the assumption that a machine cannot do Strange Loops, Or Tangled Hierarchies", font: 24, gap: 28, page: 1, top: 720, bottom: 708),
            positionedLine("Body prose continues after the emphasized question.", font: 11, gap: 10, page: 1, top: 690, bottom: 678),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Chapter XX: Strange Loops, Or Tangled Hierarchies"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.line.pageIndex, 0)
        XCTAssertEqual(resolved.first?.line.text, "CHAPTER XX")
    }

    func testResolveHeadingsDoesNotBorrowPreviousSectionContinuationForNextNumberedTitle() {
        let lines = [
            positionedLine("5.1 SUPPLEMENTAL MARKETS EXHIBITION OF", font: 16, gap: 18, page: 0, top: 610, bottom: 592),
            positionedLine("THEATRICAL MOTION PICTURES, THE PRINCIPAL", font: 16, gap: 4, page: 0, top: 591, bottom: 573),
            positionedLine("PHOTOGRAPHY OF WHICH COMMENCED AFTER", font: 16, gap: 4, page: 0, top: 572, bottom: 554),
            positionedLine("JUNE 30, 1971 BUT PRIOR TO JULY 21, 1980", font: 16, gap: 4, page: 0, top: 553, bottom: 535),
            positionedLine("5.2 SUPPLEMENTAL MARKETS EXHIBITION OF", font: 16, gap: 22, page: 0, top: 510, bottom: 492),
            positionedLine("THEATRICAL MOTION PICTURES, THE PRINCIPAL", font: 16, gap: 4, page: 0, top: 491, bottom: 473),
            positionedLine("PHOTOGRAPHY OF WHICH COMMENCED AFTER OCTOBER 6, 1980", font: 16, gap: 4, page: 0, top: 472, bottom: 454),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: [
                "5.1 Supplemental Markets Exhibition of Theatrical Motion Pictures, the Principal Photography of which Commenced After June 30, 1971 but prior to July 21, 1980",
                "5.2 Supplemental Markets Exhibition of Theatrical Motion Pictures, the Principal Photography of which Commenced after October 6, 1980",
            ],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].line.text, "5.1 SUPPLEMENTAL MARKETS EXHIBITION OF")
        XCTAssertEqual(resolved[1].line.text, "5.2 SUPPLEMENTAL MARKETS EXHIBITION OF")
    }

    func testResolveHeadingsAcceptsRunInChapterHeadingThatStartsWithTitle() {
        let lines = [
            positionedLine("Prelude text before chapter.", font: 11, gap: 8, page: 0, top: 760, bottom: 748),
            positionedLine(
                "CHAPTER IX Mumon and Gödel What Is Zen? I'M NOT SURE I know what Zen is.",
                font: 11,
                gap: 28,
                page: 1,
                top: 720,
                bottom: 708
            ),
            positionedLine("Later body paragraph continues here.", font: 11, gap: 12, page: 1, top: 680, bottom: 668),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Chapter IX: Mumon and Gödel"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(
            resolved.first?.line.text,
            "CHAPTER IX Mumon and Gödel What Is Zen? I'M NOT SURE I know what Zen is."
        )
    }

    func testResolveHeadingsPrefersLargeGapRunInChapterOverTightSynopsisLine() {
        let lines = [
            positionedLine(
                "Chapter IX: Mumon and Gödel. An attempt is made to talk about the strange ideas of Zen Buddhism.",
                font: 11,
                gap: 4,
                page: 0,
                top: 760,
                bottom: 748
            ),
            positionedLine("Bridge paragraph", font: 11, gap: 10, page: 0, top: 730, bottom: 718),
            positionedLine(
                "CHAPTER IX Mumon and Gödel What Is Zen? I'M NOT SURE I know what Zen is.",
                font: 11,
                gap: 26,
                page: 1,
                top: 700,
                bottom: 688
            ),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Chapter IX: Mumon and Gödel"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(
            resolved.first?.line.text,
            "CHAPTER IX Mumon and Gödel What Is Zen? I'M NOT SURE I know what Zen is."
        )
    }

    func testMatchQualityStripsChapterPrefixWhenBodyHeadingOnlyCarriesTailTitle() {
        let quality = PDFHeadingKeyDeriver.matchQuality(
            title: "Chapter XI: Brains and Thoughts",
            text: "Brains and Thoughts"
        )

        XCTAssertTrue(quality.matches)
        XCTAssertEqual(quality.titleCoverage, 1.0, accuracy: 0.001)
    }

    func testResolveHeadingsStepsBackFromTailOnlyChapterTitleToLabelLine() {
        let lines = [
            positionedLine("Bridge paragraph before chapter.", font: 11, gap: 8, page: 0, top: 760, bottom: 748),
            positionedLine("CHAPTER XI", font: 18, gap: 28, page: 1, top: 720, bottom: 708),
            positionedLine("Brains and Thoughts", font: 18, gap: 8, page: 1, top: 700, bottom: 688),
            positionedLine("New Perspectives on Thought", font: 16, gap: 10, page: 1, top: 680, bottom: 668),
            positionedLine("Opening body prose begins here.", font: 11, gap: 16, page: 1, top: 648, bottom: 636),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Chapter XI: Brains and Thoughts"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.line.text, "CHAPTER XI")
    }

    func testResolveHeadingsAcceptsRomanDigitDriftInRunInHeadingPrefix() {
        let lines = [
            positionedLine("Bridge paragraph before chapter.", font: 11, gap: 8, page: 0, top: 760, bottom: 748),
            positionedLine(
                "CHAPTER 11 Meaning and Form in Mathematics. THIS Two-Part Invention was the inspiration for my two characters.",
                font: 11,
                gap: 28,
                page: 1,
                top: 720,
                bottom: 708
            ),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Chapter II: Meaning and Form in Mathematics"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(
            resolved.first?.line.text,
            "CHAPTER 11 Meaning and Form in Mathematics. THIS Two-Part Invention was the inspiration for my two characters."
        )
    }

    func testResolveHeadingsAcceptsTrailingCommaBeforeRunInBody() {
        let lines = [
            positionedLine("Bridge paragraph before chapter.", font: 11, gap: 8, page: 0, top: 760, bottom: 748),
            positionedLine(
                "CHAPTER XVI11 Artificial Intelligence: Retrospects Turing IN 1950, ALAN TURING wrote a most prophetic article.",
                font: 18,
                gap: 30,
                page: 1,
                top: 720,
                bottom: 708
            ),
        ]

        let resolved = PDFHeadingKeyDeriver.resolveHeadings(
            titles: ["Chapter XVIII: Artificial Intelligence: Retrospects"],
            allLines: lines
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(
            resolved.first?.line.text,
            "CHAPTER XVI11 Artificial Intelligence: Retrospects Turing IN 1950, ALAN TURING wrote a most prophetic article."
        )
    }

    private func line(_ text: String, font: Double, gap: Double, page: Int) -> PDFTextLine {
        positionedLine(
            text,
            font: font,
            gap: gap,
            page: page,
            top: 700 - Double(page * 100),
            bottom: 688 - Double(page * 100)
        )
    }

    private func positionedLine(
        _ text: String,
        font: Double,
        gap: Double,
        page: Int,
        top: Double,
        bottom: Double
    ) -> PDFTextLine {
        PDFTextLine(
            text: text,
            fontSize: font,
            isBold: font >= 16,
            isAllCaps: false,
            indentX: 72,
            midX: 200,
            yTop: top,
            yBottom: bottom,
            gapAbove: gap,
            pageIndex: page
        )
    }
}
