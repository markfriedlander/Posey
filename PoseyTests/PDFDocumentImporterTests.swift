import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import Posey

final class PDFDocumentImporterTests: XCTestCase {
    func testLoadDocumentExtractsReadableTextAndTitleFromPDF() throws {
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "pdf")

        let document = try PDFDocumentImporter().loadDocument(from: fixtureURL)

        XCTAssertEqual(document.title, "Structured Sample PDF")
        XCTAssertTrue(document.displayText.contains("\u{000C}"))
        XCTAssertTrue(document.plainText.contains("Serious Reading in PDF"))
        XCTAssertTrue(document.plainText.contains("Dense pages still need a calm reading flow."))
        XCTAssertTrue(document.plainText.contains("Second page reminder: preserve context across page breaks."))
    }

    func testLoadDocumentRejectsImageOnlyPDF() throws {
        let data = try makeImageOnlyPDFData()

        XCTAssertThrowsError(try PDFDocumentImporter().loadDocument(fromData: data)) { error in
            XCTAssertEqual(error as? PDFDocumentImporter.ImportError, .scannedDocument)
        }
    }

    func testLoadDocumentPreservesVisualOnlyPagesInDisplayText() throws {
        let data = try makeMixedTextAndVisualPDFData()

        let document = try PDFDocumentImporter().loadDocument(fromData: data)

        XCTAssertTrue(document.displayText.contains("[[POSEY_VISUAL_PAGE:2:"))
        XCTAssertTrue(document.plainText.contains("Page one keeps the reading flow grounded."))
        XCTAssertTrue(document.plainText.contains("Page three resumes after the visual pause."))
        XCTAssertFalse(document.plainText.contains("POSEY_VISUAL_PAGE"))
    }

    /// Audit fix #3 end-to-end: a real (generated) PDF with a visual
    /// middle page must NOT drift the Go-to-page offsets. Exercises the
    /// REAL pipeline — PDFDocumentImporter → ContentUnitBuilder.units
    /// FromPDFDisplayText → DocumentPageMap.buildForPDF — not synthetic
    /// units. Page 2 is image-only (no text); page 3's offset must land
    /// exactly where its text begins in the unit-derived plainText, with
    /// the visual page contributing zero (no phantom "\n\n").
    func testGoToPageMapHasNoDriftAcrossVisualPage() throws {
        let data = try makeMixedTextAndVisualPDFData()
        let document = try PDFDocumentImporter().loadDocument(fromData: data)

        let docID = UUID()
        let units = ContentUnitBuilder.unitsFromPDFDisplayText(document.displayText,
                                                               documentID: docID)

        // Reconstruct the reader's global plainText offset map exactly as
        // ReaderViewModel.computeContentFromUnits does.
        var offsetByUnit: [UUID: Int] = [:]
        var cumulative = 0
        for u in units {
            offsetByUnit[u.id] = cumulative
            if u.kind.carriesProseText { cumulative += u.text.count + 2 }
        }
        let plainText = units.filter { $0.kind.carriesProseText }
            .map(\.text).joined(separator: "\n\n")

        let map = DocumentPageMap.buildForPDF(units: units,
                                              plainTextOffsetByUnitID: offsetByUnit)

        XCTAssertEqual(map.pageCount, 3, "three PDF pages → three page-map entries")
        XCTAssertEqual(map.offset(forPage: 1), 0)

        // Page 3's text really starts here in the unit-derived plainText.
        let p3 = try XCTUnwrap(plainText.range(of: "Page three"))
        let expectedP3 = plainText.distance(from: plainText.startIndex, to: p3.lowerBound)
        XCTAssertEqual(map.offset(forPage: 3), expectedP3,
                       "page 3 offset must match its real plainText position — no drift from the visual page")
        // The visual page 2 carries no text → resolves to the next text (page 3).
        XCTAssertEqual(map.offset(forPage: 2), map.offset(forPage: 3),
                       "a visual page resolves to the next text content")
    }

    private func makeImageOnlyPDFData() throws -> Data {
        try makePDFData { context in
            context.setFillColor(gray: 0.85, alpha: 1)
            context.fill(CGRect(x: 72, y: 72, width: 468, height: 648))
        }
    }

    private func makeMixedTextAndVisualPDFData() throws -> Data {
        let pages: [(CGContext) -> Void] = [
            { context in
                self.draw(text: "Page one keeps the reading flow grounded.", in: CGRect(x: 72, y: 620, width: 468, height: 120), context: context)
            },
            { context in
                context.setFillColor(gray: 0.85, alpha: 1)
                context.fillEllipse(in: CGRect(x: 156, y: 240, width: 300, height: 300))
            },
            { context in
                self.draw(text: "Page three resumes after the visual pause.", in: CGRect(x: 72, y: 620, width: 468, height: 120), context: context)
            }
        ]

        return try makePDFData(pages: pages)
    }

    private func makePDFData(drawPage: @escaping (CGContext) -> Void) throws -> Data {
        try makePDFData(pages: [drawPage])
    }

    private func makePDFData(pages: [(CGContext) -> Void]) throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFDocumentImporter.ImportError.unreadableDocument
        }

        for drawPage in pages {
            context.beginPDFPage(nil)
            drawPage(context)
            context.endPDFPage()
        }
        context.closePDF()

        return try Data(contentsOf: outputURL)
    }

    private func draw(text: String, in rect: CGRect, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0, alpha: 1)
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)

        context.textPosition = CGPoint(x: rect.minX, y: rect.minY)
        CTLineDraw(line, context)
    }
}
