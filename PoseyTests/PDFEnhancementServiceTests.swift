import XCTest
@testable import Posey

final class PDFEnhancementServiceTests: XCTestCase {
    func testShouldRedetectStructureWhenTOCIsMissing() {
        let documentID = UUID()
        let units = [
            ContentUnit(documentID: documentID, sequence: 0, kind: .pageBreak, text: "",
                        metadata: ContentUnitMetadata(pageNumber: 0)),
            ContentUnit(documentID: documentID, sequence: 1, kind: .prose, text: "Chapter body.")
        ]

        XCTAssertTrue(
            PDFEnhancementService.shouldRedetectStructure(
                tocEntries: [],
                units: units,
                skipOffset: 0
            )
        )
    }

    func testShouldRedetectStructureWhenTOCContainsDanglingAnchor() {
        let documentID = UUID()
        let liveHeadingID = UUID()
        let missingHeadingID = UUID()
        let units = [
            ContentUnit(documentID: documentID, sequence: 0, kind: .pageBreak, text: "",
                        metadata: ContentUnitMetadata(pageNumber: 0)),
            ContentUnit(id: liveHeadingID, documentID: documentID, sequence: 1, kind: .heading,
                        text: "54. DEFINITION OF NETWORK")
        ]
        let toc = [
            StoredTOCEntry(title: "51. ALCOHOLISM AND DRUG ABUSE PROGRAM",
                           plainTextOffset: 100, unitID: missingHeadingID,
                           playOrder: 51, level: 1),
            StoredTOCEntry(title: "54. DEFINITION OF NETWORK",
                           plainTextOffset: 400, unitID: liveHeadingID,
                           playOrder: 54, level: 1)
        ]

        XCTAssertTrue(
            PDFEnhancementService.shouldRedetectStructure(
                tocEntries: toc,
                units: units,
                skipOffset: 0
            )
        )
    }

    func testShouldNotRedetectStructureWhenTOCAnchorsAreHealthy() {
        let documentID = UUID()
        let headingID = UUID()
        let units = [
            ContentUnit(documentID: documentID, sequence: 0, kind: .pageBreak, text: "",
                        metadata: ContentUnitMetadata(pageNumber: 0)),
            ContentUnit(id: headingID, documentID: documentID, sequence: 1, kind: .heading,
                        text: "Chapter 1")
        ]
        let toc = [
            StoredTOCEntry(title: "Chapter 1",
                           plainTextOffset: 100, unitID: headingID,
                           playOrder: 1, level: 1)
        ]

        XCTAssertFalse(
            PDFEnhancementService.shouldRedetectStructure(
                tocEntries: toc,
                units: units,
                skipOffset: 120
            )
        )
    }
}
