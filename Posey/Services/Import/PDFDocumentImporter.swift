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
    /// Detected TOC region in plainText. When non-zero, the reader auto-skips
    /// the active sentence past `tocSkipUntilOffset` on first open so the
    /// listener doesn't have to hear the TOC read aloud (a uniformly poor
    /// TTS experience). Zero means no TOC was detected.
    let tocSkipUntilOffset: Int
    /// Detected TOC entries (best-effort). Persisted via the existing
    /// `document_toc` table so the existing TOC sheet shows them.
    let tocEntries: [PDFTOCEntry]
}

/// Carries a parsed TOC entry from importer to library to DB.
struct PDFTOCEntry: Sendable {
    let title: String
    /// Character offset in plainText where the chapter actually begins. The
    /// importer searches for the entry's title text after the TOC region to
    /// compute this.
    let plainTextOffset: Int
    let playOrder: Int
    /// Heading level. From `PDFOutline` traversal depth when the outline
    /// fallback is used; from the text-pattern detector this is always 1
    /// (no level signal in the dot-leader pattern).
    let level: Int
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
                // If the page also contains PDF image XObjects (figures, photos, charts),
                // preserve them as a visual stop immediately after the text. Neither is dropped.
                if pageHasImageXObjects(page) {
                    let imageID = UUID().uuidString
                    if let pngData = renderPageToPNG(page) {
                        imageRecords.append(PageImageRecord(imageID: imageID, data: pngData))
                    }
                    pageContents.append(.visualPlaceholder(pageNumber: index + 1, imageID: imageID))
                }
            } else {
                // PDFKit found no text — report progress then try Vision OCR.
                progress?(.ocr(page: index + 1, of: pageCount))
                let ocr = ocrText(from: page)
                // Require at least 10 chars of OCR text before treating a page as readable.
                // Fewer than that (page numbers, "iii", lone captions) means the page is
                // effectively visual — render it as an image stop instead.
                if ocr.count >= 10 {
                    pageContents.append(.text(ocr))
                    readableTextPages.append(ocr)
                } else if pageIsEffectivelyBlank(page) {
                    // Task 8 #5 (2026-05-03 — pixel-uniformity
                    // blank detection): genuinely blank section-
                    // divider page (no extractable text + < 10 OCR
                    // chars + pixel-uniformity scoring confirms
                    // ≥99% of sampled pixels share the dominant
                    // colour within a tight delta). Pausing TTS
                    // for these pages is an annoyance, not an
                    // affordance — flow through. Antifa corpus
                    // had 11 such pages all firing visual stops
                    // before this gate.
                    dbgLog("PDF import: skipping blank visual stop on page %d", index + 1)
                } else {
                    // Truly visual page — render to PNG and emit
                    // a visual stop so the user sees the figure
                    // inline.
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

        // Join pages, then run a second collapseLineBreakHyphens pass so that
        // hyphens spanning a page boundary (word-\x0cword) are collapsed too.
        // Per-page normalize() can't catch these because it runs before joining.
        let joinedDisplay = pageContents
            .map { content -> String in
                switch content {
                case .text(let text):
                    return text
                case .visualPlaceholder(let n, let imageID):
                    return Self.visualPageMarker(for: n, imageID: imageID)
                }
            }
            .joined(separator: "\u{000C}")
        let displayText = TextNormalizer.stripLineBreakHyphens(joinedDisplay)

        let plainText = readableTextPages.joined(separator: "\n\n")
        let rawTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Discard titles that look like file paths (Windows or Unix) — use filename fallback instead.
        let title: String? = rawTitle.flatMap { t in
            (t.contains("\\") || t.contains("/") || t.hasSuffix(".pdf") || t.hasSuffix(".obd")) ? nil : t
        }

        // Detect a Table of Contents region. When found, the reader auto-skips
        // past it on first open so the TOC isn't read aloud (uniformly poor
        // listening experience). Entries (best-effort) are persisted so the
        // existing TOC sheet can navigate the document.
        let tocResult = PDFTOCDetector.detect(pageTexts: readableTextPages)
        let tocSkipUntilOffset = tocResult?.regionEndOffset ?? 0
        var tocEntries: [PDFTOCEntry] = tocResult.map { result in
            buildEntries(for: result.entries,
                         in: plainText,
                         postTOCOffset: result.regionEndOffset)
        } ?? []

        // 2026-05-06 — PDF native outline (PDFKit's outlineRoot) as a
        // fallback when text-pattern TOC detection found nothing.
        // Many PDFs (papers, ebooks) ship a structural outline even
        // when they don't print a visible table-of-contents page.
        if tocEntries.isEmpty,
           let outline = document.outlineRoot, outline.numberOfChildren > 0 {
            tocEntries = extractOutlineEntries(from: outline,
                                               in: document,
                                               readableTextPages: readableTextPages)
        }

        return ParsedPDFDocument(
            title: title,
            displayText: displayText,
            plainText: plainText,
            images: imageRecords,
            tocSkipUntilOffset: tocSkipUntilOffset,
            tocEntries: tocEntries
        )
    }

    /// For each detector entry, find the title's first occurrence in plainText
    /// AFTER the TOC region. That offset is where the chapter actually begins
    /// and is what the TOC sheet will jump to.
    private func buildEntries(for entries: [PDFTOCDetector.Entry],
                              in plainText: String,
                              postTOCOffset: Int) -> [PDFTOCEntry] {
        guard postTOCOffset >= 0, postTOCOffset <= plainText.count else { return [] }
        let startIndex = plainText.index(plainText.startIndex, offsetBy: postTOCOffset)
        let body = plainText[startIndex...]
        var built: [PDFTOCEntry] = []
        for (index, entry) in entries.enumerated() {
            // Try the title with its label ("I. Introduction") first, then
            // fall back to the bare title ("Introduction") since the body
            // header may not include the outline label.
            let bareTitle = entry.title.split(separator: " ", maxSplits: 1).last.map(String.init) ?? entry.title
            let needles = [entry.title, bareTitle]
            var found: Int? = nil
            for needle in needles {
                guard !needle.isEmpty else { continue }
                if let r = body.range(of: needle, options: .caseInsensitive) {
                    found = postTOCOffset + body.distance(from: body.startIndex, to: r.lowerBound)
                    break
                }
            }
            // Fall back to the post-TOC offset if we can't locate the title
            // — better than dropping the entry entirely.
            built.append(PDFTOCEntry(title: entry.title,
                                     plainTextOffset: found ?? postTOCOffset,
                                     playOrder: index,
                                     level: 1))
        }
        return built
    }

    /// 2026-05-06 — Walk the PDF native outline tree and emit
    /// `PDFTOCEntry` rows. Fallback used when the text-pattern TOC
    /// detector finds nothing. For each outline entry, resolve its
    /// destination page (PDFOutline.destination?.page) and compute a
    /// plainText offset by summing the lengths of all earlier
    /// readable-text pages plus separators.
    private func extractOutlineEntries(from root: PDFOutline,
                                       in document: PDFDocument,
                                       readableTextPages: [String]) -> [PDFTOCEntry] {
        // Precompute the start offset of each page in the joined
        // plainText. plainText was joined with "\n\n" between pages.
        var pageStartOffsets: [Int] = []
        var running = 0
        for (i, p) in readableTextPages.enumerated() {
            pageStartOffsets.append(running)
            running += p.count
            if i < readableTextPages.count - 1 { running += 2 }
        }

        var entries: [PDFTOCEntry] = []
        var order = 0
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty,
                   let dest = child.destination,
                   let page = dest.page,
                   let pageIndex = document.index(for: page) as Int?,
                   pageIndex >= 0,
                   pageIndex < pageStartOffsets.count {
                    order += 1
                    entries.append(PDFTOCEntry(
                        title: title,
                        plainTextOffset: pageStartOffsets[pageIndex],
                        playOrder: order,
                        level: max(1, min(6, depth + 1))
                    ))
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return entries
    }
}

// ========== BLOCK 03: CORE PAGE PARSING - END ==========

// ========== BLOCK 04: OCR - START ==========

extension PDFDocumentImporter {
    /// Minimum average Vision confidence to treat OCR output as readable text.
    /// Pages below this threshold are garbled scan content — better shown as
    /// a visual stop than read as potentially meaningless character soup.
    private static let ocrConfidenceThreshold: Float = 0.75

    /// Renders the PDF page to a CGImage and runs Vision text recognition on it.
    /// Returns normalised plain text, or an empty string if nothing could be read
    /// or if the average recognition confidence is below `ocrConfidenceThreshold`.
    /// Runs synchronously — `VNImageRequestHandler.perform` blocks until complete.
    private func ocrText(from page: PDFPage) -> String {
        guard let image = renderPageToCGImage(page, colorSpace: CGColorSpaceCreateDeviceGray()) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }

        let observations = request.results ?? []
        let candidates = observations.compactMap { $0.topCandidates(1).first }
        guard !candidates.isEmpty else { return "" }

        // Gate on average confidence. Low confidence = garbled scan or form
        // page — surface as a visual block instead of reading garbage aloud.
        let avgConfidence = candidates.map(\.confidence).reduce(0, +) / Float(candidates.count)
        guard avgConfidence >= Self.ocrConfidenceThreshold else { return "" }

        let lines = candidates.map(\.string)
        guard !lines.isEmpty else { return "" }

        return normalize(lines.joined(separator: " "))
    }

    /// Task 8 #5 (2026-05-03): is the page effectively blank?
    /// Renders a low-resolution grayscale snapshot, samples pixels on
    /// a regular grid, and scores luminance variance. Returns true
    /// when ≥99 % of samples are within a tight delta of the dominant
    /// luminance (i.e., the page is essentially uniform — section
    /// divider, intentional blank, or page-break filler). Conservative
    /// thresholds prevent false positives on light watercolour /
    /// faint-grey artwork.
    private func pageIsEffectivelyBlank(_ page: PDFPage) -> Bool {
        // Render at 0.25× to keep the buffer tiny (a US Letter page
        // becomes ~153×198 px). Variance on such a small render is
        // a robust proxy for the full page — a single dark glyph
        // still produces detectable variance at this scale.
        guard let cgImage = renderPageToCGImage(
            page,
            colorSpace: CGColorSpaceCreateDeviceGray(),
            scale: 0.25
        ) else {
            return false
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return false }

        // Pull bytes via a fresh DeviceGray context so the row stride
        // is predictable (one byte per pixel).
        let bytesPerRow = width
        let totalBytes = bytesPerRow * height
        guard let data = malloc(totalBytes) else { return false }
        defer { free(data) }
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let buf = data.assumingMemoryBound(to: UInt8.self)

        // Sample on a regular grid — 32×32 = 1024 samples. Cheap,
        // covers the whole page, robust against gradients.
        let sampleStride = 32
        let stepX = max(1, width / sampleStride)
        let stepY = max(1, height / sampleStride)
        var samples: [UInt8] = []
        samples.reserveCapacity(sampleStride * sampleStride)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                samples.append(buf[y * bytesPerRow + x])
                x += stepX
            }
            y += stepY
        }
        guard !samples.isEmpty else { return false }

        // Find the dominant luminance bucket (each bucket = 8
        // grayscale levels). Then count samples within ±deltaLuma
        // of its center. If ≥99 % match, the page is uniform.
        var buckets = [Int](repeating: 0, count: 32) // 256 / 8 = 32
        for s in samples { buckets[Int(s) / 8] += 1 }
        guard let domIdx = buckets.indices.max(by: { buckets[$0] < buckets[$1] }) else {
            return false
        }
        let domCenter = domIdx * 8 + 4
        let deltaLuma = 12 // tolerance ≈ 5 % of 0–255 range
        var withinDelta = 0
        for s in samples {
            if abs(Int(s) - domCenter) <= deltaLuma { withinDelta += 1 }
        }
        let ratio = Double(withinDelta) / Double(samples.count)
        return ratio >= 0.99
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
        // Task 8 (2026-05-03 — format parity): delegate the shared
        // passes to `TextNormalizer.normalize(_:)` (BOM strip, soft
        // hyphen + zero-width strip, line-ending normalize, trailing
        // whitespace trim, hyphen collapse, spaced-letter/digit
        // collapse, tab→space, blank-line collapse). Then layer
        // PDF-specific behavior on top: single-newline → space (PDF
        // text extraction emits soft line breaks within paragraphs
        // that would otherwise read as hard breaks). The page-
        // boundary `collapseLineBreakHyphens` pass still runs once
        // more in `loadDocument` after pages are joined with `\f`.
        var t = TextNormalizer.normalize(text)
        t = t.replacingOccurrences(of: #"\n(?!\n)"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 2026-05-03 (Task 8 — format parity): the PDF importer's local
    // `collapseLineBreakHyphens`, `collapseSpacedDigits`, and
    // `collapseSpacedLetters` helpers were removed. Their behavior
    // moved to `TextNormalizer` (full Unicode-aware passes) and is
    // now invoked via `TextNormalizer.normalize(_:)` inside
    // `normalize(_:)` and via `TextNormalizer.stripLineBreakHyphens(_:)`
    // for the page-boundary join in `loadDocument`. Every importer
    // now reaches the same passes — TXT/MD/RTF/DOCX/HTML/EPUB/PDF.


    /// Returns true if the page's PDF resource dictionary contains at least one
    /// Image-type XObject — indicating the page has embedded figures, photos, or
    /// charts in addition to any extractable text.
    ///
    /// Uses the CGPDFPage resource dictionary directly so the check is fast (no
    /// rendering needed). False negatives are possible for unusual PDF constructs
    /// (images in Form XObjects or pattern streams) but those are rare.
    private func pageHasImageXObjects(_ page: PDFPage) -> Bool {
        guard let cgPage = page.pageRef,
              let pageDict = cgPage.dictionary else { return false }

        var resourcesDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resourcesDict),
              let res = resourcesDict else { return false }

        var xObjDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xObjDict),
              let xObj = xObjDict else { return false }

        var found = false
        // CGPDFDictionaryApplyFunction uses a C function pointer; pass &found as
        // context. The closure is non-capturing so it satisfies @convention(c).
        withUnsafeMutablePointer(to: &found) { ptr in
            CGPDFDictionaryApplyFunction(xObj, { _, obj, ctx in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(obj, .stream, &stream),
                      let st = stream,
                      let stDict = CGPDFStreamGetDictionary(st) else { return }
                var subtype: UnsafePointer<Int8>?
                guard CGPDFDictionaryGetName(stDict, "Subtype", &subtype),
                      let st = subtype else { return }
                if strcmp(st, "Image") == 0 {
                    ctx?.assumingMemoryBound(to: Bool.self).pointee = true
                }
            }, ptr)
        }
        return found
    }
}

// ========== BLOCK 05: HELPERS - END ==========
