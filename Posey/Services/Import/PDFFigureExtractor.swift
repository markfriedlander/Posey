import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// PDFFigureExtractor (2026-07-03, CC#22) — pull the REAL embedded figures out of
// a PDF and place them in reading order.
//
// THE PROBLEM this solves: the importer previously rendered a whole page to an
// image ONLY when the page had almost no text (`pdfText.count < 200`). Real
// figures live on pages that ALSO have body text, so every one of them was
// dropped; the only "images" captured were near-blank watermark/nav pages
// (junk). Verified on real docs: Crypto references ~39 figures, importer stored
// 6 blank pages; GEB has ~157 real figures, none placed.
//
// THE APPROACH (validated off-device on Crypto + GEB before wiring in): scan a
// page's content stream for image-XObject draw operations, tracking the CTM so
// each image's rectangle on the page is known. Keep the ones that are
// figure-SIZED and drop the tiny recurring furniture (nav buttons ~62x15pt on
// every page, converter watermarks). Render each surviving figure's page region
// to PNG (region-render, not raw-XObject-decode, so vector labels/callouts drawn
// on top of the raster are preserved). The rect's vertical position anchors the
// figure among the page's text lines for reading-order placement.
//
// SIGNALS ARE PLATFORM-INDEPENDENT: image geometry (CTM, XObject dims) and page
// rendering are identical on macOS and iOS — unlike FONT signals, which macOS
// PDFKit zeroes. So the off-device harness that compiles THIS file is a faithful
// proxy; the phone remains the acceptance surface.

// ========== BLOCK 01: MODELS - START ==========

/// One embedded raster figure located on a PDF page.
struct ExtractedFigure: Sendable {
    /// 0-based sheet index (matches `PDFTextLine.pageIndex` — the true PDFKit page).
    let pageIndex: Int
    /// Top edge of the figure in PDF page points (y-UP: larger = higher on the
    /// page). Placement anchor — compared against `PDFTextLine.yTop` to interleave
    /// the figure among that page's lines in reading order.
    let yTop: Double
    /// Rendered PNG bytes of the figure's page region.
    let pngData: Data
    let widthPoints: Double
    let heightPoints: Double
}

/// A lightweight record of one image-XObject draw (before rendering) — used for
/// the size + recurrence filtering that decides which draws are real figures.
struct PDFImageDraw: Sendable {
    let pageIndex: Int
    /// Placement rectangle in PDF page points (y-up), from the CTM at draw time.
    let rect: CGRect
    /// Source pixel dimensions of the image XObject. Identical dims reused across
    /// many pages is the "same reused graphic" (furniture) signal.
    let srcW: Int
    let srcH: Int
    /// The page's mediaBox size (points). Used to reject a near-full-page image —
    /// i.e. a SCANNED page whose whole sheet is one image (its text comes from an
    /// OCR layer), which must NOT be re-added as a "figure" (would duplicate the
    /// page). Measured: Learning (scanned) has 28 such; Crypto/GEB have zero.
    let pageWidth: Double
    let pageHeight: Double

    /// Fraction of the page this image covers (0…1).
    var pageCoverage: Double {
        let pageArea = pageWidth * pageHeight
        guard pageArea > 0 else { return 0 }
        return Double(rect.width * rect.height) / pageArea
    }
}

// ========== BLOCK 01: MODELS - END ==========

// ========== BLOCK 02: CONTENT-STREAM SCAN (CTM-tracked image draws) - START ==========

/// Mutable state carried through the C content-stream scan via the scanner's
/// info pointer (the `@convention(c)` callbacks below can't capture Swift state).
private final class FigureScanState {
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var resources: CGPDFDictionaryRef?
    var draws: [(rect: CGRect, w: Int, h: Int)] = []
}

// `cm`: concatenate a transform onto the CTM (operands pop in reverse order).
private func pfe_cm(_ s: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    var f: CGPDFReal = 0, e: CGPDFReal = 0, d: CGPDFReal = 0, c: CGPDFReal = 0, b: CGPDFReal = 0, a: CGPDFReal = 0
    guard CGPDFScannerPopNumber(s, &f), CGPDFScannerPopNumber(s, &e), CGPDFScannerPopNumber(s, &d),
          CGPDFScannerPopNumber(s, &c), CGPDFScannerPopNumber(s, &b), CGPDFScannerPopNumber(s, &a) else { return }
    let st = Unmanaged<FigureScanState>.fromOpaque(info!).takeUnretainedValue()
    st.ctm = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f).concatenating(st.ctm)
}
// `q`/`Q`: save/restore the CTM.
private func pfe_q(_ s: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    let st = Unmanaged<FigureScanState>.fromOpaque(info!).takeUnretainedValue(); st.stack.append(st.ctm)
}
private func pfe_Q(_ s: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    let st = Unmanaged<FigureScanState>.fromOpaque(info!).takeUnretainedValue(); if let t = st.stack.popLast() { st.ctm = t }
}
// `Do`: execute an XObject. If it's an image, record its rect (unit square under
// the CTM) + source pixel dims.
private func pfe_Do(_ s: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    var name: UnsafePointer<Int8>?
    guard CGPDFScannerPopName(s, &name), let nm = name else { return }
    let st = Unmanaged<FigureScanState>.fromOpaque(info!).takeUnretainedValue()
    guard let res = st.resources else { return }
    var xoDict: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(res, "XObject", &xoDict), let xo = xoDict else { return }
    var strm: CGPDFStreamRef?
    guard CGPDFDictionaryGetStream(xo, nm, &strm), let stream = strm,
          let sd = CGPDFStreamGetDictionary(stream) else { return }
    var subtype: UnsafePointer<Int8>?
    guard CGPDFDictionaryGetName(sd, "Subtype", &subtype), let sub = subtype,
          strcmp(sub, "Image") == 0 else { return }
    var w: CGPDFInteger = 0, h: CGPDFInteger = 0
    CGPDFDictionaryGetInteger(sd, "Width", &w); CGPDFDictionaryGetInteger(sd, "Height", &h)
    let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(st.ctm)
    st.draws.append((rect, Int(w), Int(h)))
}

// ========== BLOCK 02: CONTENT-STREAM SCAN - END ==========

// ========== BLOCK 03: EXTRACTOR API - START ==========

enum PDFFigureExtractor {

    /// A figure must be at least this many points on its short side AND cover at
    /// least this area — the discriminator that drops nav-buttons / rule lines /
    /// tiny spacer images. Calibrated on Crypto (real figures 158x103, 350x222;
    /// nav buttons 62x15) + GEB (figures 345x428 … 425x645). Tunable.
    static let minShortSidePoints: Double = 60
    static let minAreaPoints: Double = 8000

    /// The same reused graphic drawn on at least this many DISTINCT pages is
    /// furniture (a large converter watermark / masthead / logo), not a figure.
    /// Absolute floor (mirrors the text furniture detector's `runnerMinPages`):
    /// a real figure is one-off; a page decoration repeats. Belt-and-suspenders
    /// beyond the size filter, for PDFs whose furniture is large.
    static let recurrenceFurnitureFloor = 6

    /// An image covering at least this fraction of its page is treated as the
    /// PAGE ITSELF (a scanned sheet), not an embedded figure — so it is not
    /// re-added as a figure alongside its OCR text. Measured: this drops all 28
    /// of Learning's page-scans while keeping every Crypto/GEB figure (their
    /// largest cover well under this). Tunable; a genuine full-bleed full-page
    /// plate above this bar is the known edge to watch on the phone.
    static let maxPageCoverage: Double = 0.85

    /// Every image-XObject draw on a page, with its page-space rectangle. No
    /// rendering (cheap) — call once per page during the import loop, then feed
    /// the whole document's draws to `selectFigures`.
    static func imageDraws(on page: PDFPage, pageIndex: Int) -> [PDFImageDraw] {
        guard let cgPage = page.pageRef else { return [] }
        let pageBounds = page.bounds(for: .mediaBox)
        let state = FigureScanState()
        if let pageDict = cgPage.dictionary {
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pageDict, "Resources", &res) { state.resources = res }
        }
        guard let table = CGPDFOperatorTableCreate() else { return [] }
        CGPDFOperatorTableSetCallback(table, "cm", pfe_cm)
        CGPDFOperatorTableSetCallback(table, "q", pfe_q)
        CGPDFOperatorTableSetCallback(table, "Q", pfe_Q)
        CGPDFOperatorTableSetCallback(table, "Do", pfe_Do)
        let cs = CGPDFContentStreamCreateWithPage(cgPage)
        let scanner = CGPDFScannerCreate(cs, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(cs)
        return state.draws.map {
            PDFImageDraw(pageIndex: pageIndex, rect: $0.rect, srcW: $0.w, srcH: $0.h,
                         pageWidth: Double(pageBounds.width), pageHeight: Double(pageBounds.height))
        }
    }

    /// True when a draw is large enough to be a real figure (not decoration) and
    /// not so large it IS the page (a scanned sheet).
    static func isFigureSized(_ d: PDFImageDraw) -> Bool {
        min(d.rect.width, d.rect.height) >= minShortSidePoints
            && (d.rect.width * d.rect.height) >= minAreaPoints
            && d.pageCoverage < maxPageCoverage
    }

    /// From every image draw in the document, select the real figures: keep
    /// figure-SIZED draws (and not full-page scans), then drop any whose source
    /// image (by pixel dims) is reused as furniture on `recurrenceFurnitureFloor`+
    /// distinct pages.
    static func selectFigures(from allDraws: [PDFImageDraw]) -> [PDFImageDraw] {
        let sized = allDraws.filter(isFigureSized)
        // Recurrence by source-pixel dimensions = "the same graphic reused."
        var pagesBySig: [String: Set<Int>] = [:]
        for d in sized { pagesBySig["\(d.srcW)x\(d.srcH)", default: []].insert(d.pageIndex) }
        let furnitureSigs = Set(pagesBySig.filter { $0.value.count >= recurrenceFurnitureFloor }.keys)
        return sized.filter { !furnitureSigs.contains("\($0.srcW)x\($0.srcH)") }
    }

    /// Render a selected figure's page region to PNG. Region-render (not raw
    /// XObject decode) so vector overlays / labels drawn atop the raster are
    /// captured, and to sidestep decoding arbitrary PDF image filters/colorspaces.
    static func render(_ d: PDFImageDraw, on page: PDFPage, scale: CGFloat = 2.0) -> ExtractedFigure? {
        guard let cgPage = page.pageRef else { return nil }
        let rect = d.rect
        let pxW = max(1, Int(rect.width * scale))
        let pxH = max(1, Int(rect.height * scale))
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)   // map the figure region to the origin
        ctx.drawPDFPage(cgPage)
        guard let cgImage = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return ExtractedFigure(pageIndex: d.pageIndex, yTop: Double(rect.maxY),
                               pngData: out as Data,
                               widthPoints: Double(rect.width), heightPoints: Double(rect.height))
    }
}

// ========== BLOCK 03: EXTRACTOR API - END ==========
