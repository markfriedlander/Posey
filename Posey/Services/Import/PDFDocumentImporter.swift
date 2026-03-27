import Foundation
import ImageIO
import PDFKit
import UIKit
import Vision

// ========== BLOCK 01: MODELS AND ERRORS - START ==========

/// Image data captured from a single visual page during import.
/// Stored as PNG (lossless) for fidelity on detailed artwork.
struct PageImageRecord: Sendable {
    let imageID: String  // UUID string — embedded in the visual-page marker
    let data: Data       // PNG bytes
}

/// Explicit Sendable so ParsedPDFDocument can cross actor boundaries safely.
struct ParsedPDFDocument: Sendable {
    let title: String?
    let displayText: String
    let plainText: String
    /// One record per visual page that was rendered to an image.
    /// Empty for text-only PDFs.
    let images: [PageImageRecord]
}

struct PDFDocumentImporter {
    private static let visualPageMarkerPrefix = "[[POSEY_VISUAL_PAGE:"
    private static let visualPageMarkerSuffix = "]]"

    /// Progress events emitted during import. Sent only when OCR is needed.
    /// Conforms to Sendable so the callback can cross actor boundaries.
    enum ImportProgress: Sendable {
        /// Emitted once per page that requires Vision OCR (PDFKit found no text).
        case ocr(page: Int, of: Int)

        var message: String {
            switch self {
            case .ocr(let page, let total): return "OCR: page \(page) of \(total)"
            }
        }
    }

    enum ImportError: LocalizedError, Equatable {
        case unreadableDocument
        case emptyDocument
        case scannedDocument

        var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "Posey could not read that PDF file."
            case .emptyDocument:
                return "The PDF file is empty."
            case .scannedDocument:
                return "Posey could not extract text from this PDF, even after attempting OCR. The document may be too low quality or in a format that could not be recognised."
            }
        }
    }
}

// ========== BLOCK 01: MODELS AND ERRORS - END ==========

// ========== BLOCK 02: IMPORT ENTRY POINTS - START ==========

extension PDFDocumentImporter {
    func loadDocument(
        from url: URL,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) throws -> ParsedPDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw ImportError.unreadableDocument
        }
        return try parsedDocument(from: document, progress: progress)
    }

    func loadDocument(
        fromData data: Data,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) throws -> ParsedPDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw ImportError.unreadableDocument
        }
        return try parsedDocument(from: document, progress: progress)
    }
}

// ========== BLOCK 02: IMPORT ENTRY POINTS - END ==========

// ========== BLOCK 03: CORE PAGE PARSING - START ==========

extension PDFDocumentImporter {
    private func parsedDocument(
        from document: PDFDocument,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) throws -> ParsedPDFDocument {
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ImportError.emptyDocument
        }

        enum PageContent {
            case text(String)
            case visualPlaceholder(pageNumber: Int, imageID: String)
        }

        var pageContents: [PageContent] = []
        pageContents.reserveCapacity(pageCount)
        var readableTextPages: [String] = []
        readableTextPages.reserveCapacity(pageCount)
        var imageRecords: [PageImageRecord] = []

        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }

            let pdfText = normalize(page.string ?? "")
            if !pdfText.isEmpty {
                pageContents.append(.text(pdfText))
                readableTextPages.append(pdfText)
            } else {
                // PDFKit found no text — report progress then try Vision OCR.
                progress?(.ocr(page: index + 1, of: pageCount))
                let ocr = ocrText(from: page)
                if !ocr.isEmpty {
                    pageContents.append(.text(ocr))
                    readableTextPages.append(ocr)
                } else {
                    // Purely visual page — render to PNG for inline display.
                    let imageID = UUID().uuidString
                    if let pngData = renderPageToPNG(page) {
                        imageRecords.append(PageImageRecord(imageID: imageID, data: pngData))
                    }
                    pageContents.append(.visualPlaceholder(pageNumber: index + 1, imageID: imageID))
                }
            }
        }

        guard !readableTextPages.isEmpty else {
            throw ImportError.scannedDocument
        }

        let displayText = pageContents
            .map { content -> String in
                switch content {
                case .text(let text):
                    return text
                case .visualPlaceholder(let n, let imageID):
                    return Self.visualPageMarker(for: n, imageID: imageID)
                }
            }
            .joined(separator: "\u{000C}")

        let plainText = readableTextPages.joined(separator: "\n\n")
        let rawTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Discard titles that look like file paths (Windows or Unix) — use filename fallback instead.
        let title: String? = rawTitle.flatMap { t in
            (t.contains("\\") || t.contains("/") || t.hasSuffix(".pdf") || t.hasSuffix(".obd")) ? nil : t
        }

        return ParsedPDFDocument(
            title: title,
            displayText: displayText,
            plainText: plainText,
            images: imageRecords
        )
    }
}

// ========== BLOCK 03: CORE PAGE PARSING - END ==========

// ========== BLOCK 04: OCR - START ==========

extension PDFDocumentImporter {
    /// Renders the PDF page to a CGImage and runs Vision text recognition on it.
    /// Returns normalised plain text, or an empty string if nothing could be read.
    /// Runs synchronously — `VNImageRequestHandler.perform` blocks until complete.
    private func ocrText(from page: PDFPage) -> String {
        guard let image = renderPageToCGImage(page, colorSpace: CGColorSpaceCreateDeviceGray()) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return "" }

        return normalize(lines.joined(separator: " "))
    }

    /// Renders a page to PNG data using PDFPage.thumbnail — Apple's purpose-built,
    /// thread-safe renderer. 2× scale for fidelity on detailed artwork.
    private func renderPageToPNG(_ page: PDFPage, scale: CGFloat = 2.0) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image.pngData()
    }

    /// Renders a page to CGImage for Vision OCR. Uses DeviceGray to keep the
    /// buffer small. Not used for display — see renderPageToPNG for that.
    private func renderPageToCGImage(_ page: PDFPage, colorSpace: CGColorSpace, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width  = max(1, Int(bounds.width  * scale))
        let height = max(1, Int(bounds.height * scale))

        let bitmapInfo: UInt32 = colorSpace.model == .monochrome
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        if colorSpace.model == .monochrome {
            ctx.setFillColor(gray: 1, alpha: 1)
        } else {
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }
}

// ========== BLOCK 04: OCR - END ==========

// ========== BLOCK 05: HELPERS - START ==========

extension PDFDocumentImporter {
    /// Encodes a visual-page marker with the imageID embedded.
    /// Format: `[[POSEY_VISUAL_PAGE:<pageNumber>:<imageID>]]`
    static func visualPageMarker(for pageNumber: Int, imageID: String) -> String {
        "\(visualPageMarkerPrefix)\(pageNumber):\(imageID)\(visualPageMarkerSuffix)"
    }

    /// Parses both old-format `[[POSEY_VISUAL_PAGE:N]]` and new-format `[[POSEY_VISUAL_PAGE:N:UUID]]`.
    /// Returns `(pageNumber, imageID)` — imageID is nil for old-format markers.
    static func parseVisualPageMarker(from marker: String) -> (pageNumber: Int, imageID: String?)? {
        guard marker.hasPrefix(visualPageMarkerPrefix),
              marker.hasSuffix(visualPageMarkerSuffix) else { return nil }
        let start = marker.index(marker.startIndex, offsetBy: visualPageMarkerPrefix.count)
        let end   = marker.index(marker.endIndex,   offsetBy: -visualPageMarkerSuffix.count)
        let inner = String(marker[start..<end])
        if let colonRange = inner.range(of: ":") {
            let pageStr = String(inner[inner.startIndex..<colonRange.lowerBound])
            let imageID = String(inner[colonRange.upperBound...])
            guard let pageNumber = Int(pageStr) else { return nil }
            return (pageNumber, imageID.isEmpty ? nil : imageID)
        } else {
            guard let pageNumber = Int(inner) else { return nil }
            return (pageNumber, nil)
        }
    }

    private func normalize(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\r",   with: "\n")
        t = t.replacingOccurrences(of: #"[ \t]+\n"#,  with: "\n", options: .regularExpression)
        t = collapseLineBreakHyphens(t)
        t = collapseSpacedLetters(t)
        t = t.replacingOccurrences(of: #"\n(?!\n)"#,  with: " ",  options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#,    with: "\n\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ ]{2,}"#,   with: " ",  options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses PDF line-break hyphenation: "fas- cism" → "fascism".
    /// Only fires when a lowercase continuation follows "- ", distinguishing
    /// line-break hyphens from intentional compound words like "anti-fascist".
    private func collapseLineBreakHyphens(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z]+)-[ \n]([a-z]+)"#) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1$2"
        )
    }

    /// Collapses PDF glyph-positioning artifacts: "C O N T E N T S" → "CONTENTS".
    /// Only collapses runs of 3+ single letters that are all the same case,
    /// so normal prose (e.g. a sentence starting with "I") is left untouched.
    private func collapseSpacedLetters(_ text: String) -> String {
        // Two passes: one for all-uppercase runs, one for all-lowercase runs.
        let patterns = [#"(?<![A-Z])[A-Z](?: [A-Z]){2,}(?![A-Z])"#,
                        #"(?<![a-z])[a-z](?: [a-z]){2,}(?![a-z])"#]
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            var rebuilt = ""
            var lastEnd = result.startIndex
            regex.enumerateMatches(in: result, range: NSRange(result.startIndex..., in: result)) { match, _, _ in
                guard let match, let matchRange = Range(match.range, in: result) else { return }
                rebuilt += result[lastEnd..<matchRange.lowerBound]
                rebuilt += result[matchRange].replacingOccurrences(of: " ", with: "")
                lastEnd = matchRange.upperBound
            }
            rebuilt += result[lastEnd...]
            result = rebuilt
        }
        return result
    }
}

// ========== BLOCK 05: HELPERS - END ==========
