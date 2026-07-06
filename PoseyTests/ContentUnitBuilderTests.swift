import XCTest
@testable import Posey

final class ContentUnitBuilderTests: XCTestCase {
    func testReanchorTOCPreservesExplicitHeadingUnitIdentity() {
        let documentID = UUID()
        let earlyHeadingID = UUID()
        let lateHeadingID = UUID()

        let units: [ContentUnit] = [
            ContentUnit(
                id: earlyHeadingID,
                documentID: documentID,
                sequence: 0,
                kind: .heading,
                text: "Chapter II: Meaning and Form in Mathematics",
                metadata: .empty
            ),
            ContentUnit(
                id: UUID(),
                documentID: documentID,
                sequence: 1,
                kind: .prose,
                text: "Early chapter body text.",
                metadata: .empty
            ),
            ContentUnit(
                id: lateHeadingID,
                documentID: documentID,
                sequence: 2,
                kind: .heading,
                text: "Chapter II: Meaning and Form in Mathematics",
                metadata: .empty
            ),
            ContentUnit(
                id: UUID(),
                documentID: documentID,
                sequence: 3,
                kind: .prose,
                text: "Late repeated mention.",
                metadata: .empty
            ),
        ]

        let staleEntry = StoredTOCEntry(
            title: "Chapter II: Meaning and Form",
            plainTextOffset: 9_999,
            unitID: earlyHeadingID,
            playOrder: 7,
            level: 1
        )

        let reanchored = ContentUnitBuilder.reanchorTOCToHeadingUnits([staleEntry], units: units)

        XCTAssertEqual(reanchored.count, 1)
        XCTAssertEqual(reanchored[0].unitID, earlyHeadingID)
        XCTAssertEqual(reanchored[0].title, "Chapter II: Meaning and Form in Mathematics")
        XCTAssertEqual(reanchored[0].plainTextOffset, 0)
    }

    func testReanchorTOCFallsBackToTitleMatchWhenUnitIDIsMissing() {
        let documentID = UUID()
        let headingID = UUID()

        let units: [ContentUnit] = [
            ContentUnit(
                id: UUID(),
                documentID: documentID,
                sequence: 0,
                kind: .prose,
                text: "Front matter.",
                metadata: .empty
            ),
            ContentUnit(
                id: headingID,
                documentID: documentID,
                sequence: 1,
                kind: .heading,
                text: "Chapter I: The MU-puzzle",
                metadata: .empty
            ),
            ContentUnit(
                id: UUID(),
                documentID: documentID,
                sequence: 2,
                kind: .prose,
                text: "Body text.",
                metadata: .empty
            ),
        ]

        let unresolved = StoredTOCEntry(
            title: "Chapter I: The MU-puzzle",
            plainTextOffset: 500,
            unitID: UUID(),
            playOrder: 5,
            level: 1
        )

        let reanchored = ContentUnitBuilder.reanchorTOCToHeadingUnits([unresolved], units: units)

        XCTAssertEqual(reanchored.count, 1)
        XCTAssertEqual(reanchored[0].unitID, headingID)
        XCTAssertEqual(reanchored[0].plainTextOffset, "Front matter.".count + 2)
    }

    func testUnitsFromPDFLinesCarriesTitleLengthForRunInHeading() throws {
        let line = PDFTextLine(
            text: "CHAPTER IX Mumon and Gödel What Is Zen? I'M NOT SURE I know what Zen is.",
            fontSize: 11,
            isBold: false,
            isAllCaps: false,
            indentX: 72,
            midX: 200,
            yTop: 720,
            yBottom: 708,
            gapAbove: 28,
            pageIndex: 0
        )

        let units = ContentUnitBuilder.unitsFromPDFLines(
            [[line]],
            documentID: UUID(),
            isHeading: { _ in true },
            headingTitle: { _ in "Chapter IX: Mumon and Gödel" }
        )

        let heading = try XCTUnwrap(units.first(where: { $0.kind == .heading }))
        XCTAssertEqual(heading.metadata.titleLength, "CHAPTER IX Mumon and Gödel ".count)
    }
}
