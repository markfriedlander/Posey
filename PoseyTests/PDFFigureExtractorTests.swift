import XCTest
@testable import Posey

final class PDFFigureExtractorTests: XCTestCase {
    func testSelectFiguresKeepsMostlyVisualPlatePage() {
        let plate = PDFImageDraw(
            pageIndex: 12,
            rect: CGRect(x: 20, y: 30, width: 560, height: 700),
            srcW: 1400,
            srcH: 1750,
            pageWidth: 612,
            pageHeight: 792,
            pageTextCharacters: 18
        )

        let selected = PDFFigureExtractor.selectFigures(from: [plate])

        XCTAssertEqual(selected.count, 1)
    }

    func testSelectFiguresRejectsScannedTextPage() {
        let scannedPage = PDFImageDraw(
            pageIndex: 4,
            rect: CGRect(x: 0, y: 0, width: 612, height: 792),
            srcW: 2448,
            srcH: 3168,
            pageWidth: 612,
            pageHeight: 792,
            pageTextCharacters: 900
        )

        let selected = PDFFigureExtractor.selectFigures(from: [scannedPage])

        XCTAssertTrue(selected.isEmpty)
    }
}
