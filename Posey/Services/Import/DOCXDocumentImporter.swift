import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// ========== BLOCK 01: ERRORS - START ==========
struct DOCXDocumentImporter {
    enum ImportError: LocalizedError, Equatable {
        case unreadableDocument
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "Posey could not read that DOCX file."
            case .emptyDocument:
                return "The DOCX file is empty."
            }
        }
    }
// ========== BLOCK 01: ERRORS - END ==========


// ========== BLOCK 02: ENTRY POINTS - START ==========
    /// Legacy entry point: returns text only. Used by callers that
    /// don't need the displayText/plainText distinction or inline
    /// image bytes (existing tests, ad-hoc previews).
    func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return try loadText(fromData: data)
    }

    func loadText(fromData data: Data) throws -> String {
        try loadDocument(fromData: data).plainText
    }

    /// Task 8 #3 + #4 (2026-05-03): rich import that returns both
    /// rendered displayText (with inline `[[POSEY_VISUAL_PAGE:0:uuid]]`
    /// markers at each `<w:drawing>` position) and plainText (markers
    /// stripped, suitable for TTS + embeddings + search), plus the
    /// collected `PageImageRecord` set ready for
    /// `databaseManager.insertImage`.
    ///
    /// Detects and SKIPS Word-managed Table of Contents fields:
    /// `<w:fldChar fldCharType="begin"/> ... <w:instrText>TOC ...
    /// </w:instrText> <w:fldChar fldCharType="separate"/> ... [TOC
    /// content] ... <w:fldChar fldCharType="end"/>`. Without this,
    /// TTS reads the whole TOC aloud (chapter title + page reference
    /// for every entry).
    func loadDocument(from url: URL) throws -> (displayText: String, plainText: String, images: [PageImageRecord]) {
        let data = try Data(contentsOf: url)
        return try loadDocument(fromData: data)
    }

    func loadDocument(fromData data: Data) throws -> (displayText: String, plainText: String, images: [PageImageRecord]) {
        let archive = try archive(from: data)
        let documentXML = try archive.entryData(named: "word/document.xml")

        // rId → archive path mapping for inline images. Best-effort —
        // a missing rels file yields an empty mapping (images won't
        // be extracted, text + TOC stripping still work).
        let rels = (try? archive.entryData(named: "word/_rels/document.xml.rels"))
            .flatMap { try? RelationshipMapping.parse($0) }
            ?? RelationshipMapping(empty: ())

        // Extract image bytes for every image-typed relationship up
        // front. Cheaper than loading on demand and lets us hand the
        // extractor a stable id→bytes lookup table.
        var imagePool: [String: PageImageRecord] = [:]
        for (rId, target) in rels.imageTargets {
            // Targets are relative to "word/" (e.g. "media/image1.png").
            let archivePath = "word/\(target)"
            guard let bytes = try? archive.entryData(named: archivePath), !bytes.isEmpty else {
                continue
            }
            imagePool[rId] = PageImageRecord(imageID: UUID().uuidString, data: bytes)
        }

        let extracted = try WordDocumentXMLExtractor.extract(
            from: documentXML,
            imagePool: imagePool
        )

        let normalizedDisplay = normalizeDisplay(extracted.displayText)
        let plainText = stripVisualPageMarkers(from: normalizedDisplay)
        let normalizedPlain = normalizePlain(plainText)
        guard !normalizedPlain.isEmpty else { throw ImportError.emptyDocument }

        // Filter image pool to only those actually emitted (some
        // .docx archives include unused images).
        let usedImages = extracted.usedImageIDs.compactMap { id -> PageImageRecord? in
            imagePool.values.first(where: { $0.imageID == id })
        }
        return (normalizedDisplay, normalizedPlain, usedImages)
    }
// ========== BLOCK 02: ENTRY POINTS - END ==========


// ========== BLOCK 03: NORMALIZATION - START ==========
    /// Display normalization preserves visual-page markers; plain-text
    /// normalization is applied after marker strip.
    private func normalizeDisplay(_ text: String) -> String {
        TextNormalizer.stripMojibakeAndControlCharacters(text)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ ]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizePlain(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[ ]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripVisualPageMarkers(from text: String) -> String {
        let pattern = #"\u{000C}?\[\[POSEY_VISUAL_PAGE:[^\]]+\]\]\u{000C}?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
    }
// ========== BLOCK 03: NORMALIZATION - END ==========


// ========== BLOCK 04: ARCHIVE - START ==========
    private func archive(from data: Data) throws -> ZIPArchive {
        do {
            return try ZIPArchive(data: data)
        } catch {
            throw ImportError.unreadableDocument
        }
    }
}
// ========== BLOCK 04: ARCHIVE - END ==========


// ========== BLOCK 05: RELATIONSHIPS PARSER - START ==========
/// Tiny parser for `word/_rels/document.xml.rels` — we only need the
/// rId → image-target mapping for inline-image extraction. Anything
/// else (hyperlinks, settings, fontTable) is ignored.
private struct RelationshipMapping {
    /// rId → relative-to-word target (e.g. "media/image1.png").
    let imageTargets: [String: String]

    init(empty: ()) { self.imageTargets = [:] }

    static func parse(_ data: Data) throws -> RelationshipMapping {
        let parser = XMLParser(data: data)
        let delegate = RelsDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw DOCXDocumentImporter.ImportError.unreadableDocument
        }
        return RelationshipMapping(imageTargets: delegate.imageTargets)
    }

    private final class RelsDelegate: NSObject, XMLParserDelegate {
        var imageTargets: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
            guard elementName == "Relationship" else { return }
            guard let id = attributeDict["Id"],
                  let target = attributeDict["Target"],
                  let type = attributeDict["Type"] else { return }
            // Image relationship type:
            // .../officeDocument/2006/relationships/image
            if type.hasSuffix("/image") {
                imageTargets[id] = target
            }
        }
    }

    private init(imageTargets: [String: String]) {
        self.imageTargets = imageTargets
    }
}
// ========== BLOCK 05: RELATIONSHIPS PARSER - END ==========


// ========== BLOCK 06: DOCUMENT XML EXTRACTOR (TOC + IMAGES) - START ==========
/// Walks `word/document.xml` and emits paragraph text. Tracks two
/// special structures:
///
/// 1. **TOC fields.** Word stores its managed TOC as a field:
///    `<w:fldChar fldCharType="begin"/> ... <w:instrText> TOC \o ...
///    </w:instrText> <w:fldChar fldCharType="separate"/> ... [TOC
///    content] ... <w:fldChar fldCharType="end"/>`. Once we see
///    "TOC" in the field instructions, the rendered TOC content
///    between `separate` and the matching `end` is suppressed.
///    Nested fields (PAGEREF inside the TOC, etc.) are tracked by
///    depth so we don't end the TOC region prematurely.
///
/// 2. **Inline images.** `<w:drawing>` blocks contain `<a:blip
///    r:embed="rIdN"/>` references. When we see one, we look up the
///    rId in the supplied image pool and emit a paragraph containing
///    `[[POSEY_VISUAL_PAGE:0:<imageID>]]`. The pool is built upstream
///    from the rels file + media archive entries.
private final class WordDocumentXMLExtractor: NSObject, XMLParserDelegate {
    struct Result {
        let displayText: String
        let usedImageIDs: [String]
    }

    static func extract(from data: Data, imagePool: [String: PageImageRecord]) throws -> Result {
        let extractor = WordDocumentXMLExtractor(imagePool: imagePool)
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        guard parser.parse() else {
            throw DOCXDocumentImporter.ImportError.unreadableDocument
        }
        return Result(
            displayText: extractor.paragraphs.joined(separator: "\n\n"),
            usedImageIDs: extractor.usedImageIDs
        )
    }

    private let imagePool: [String: PageImageRecord]
    private var paragraphs: [String] = []
    private var currentParagraph = ""
    private var currentRun = ""
    private var insideTextNode = false
    private var insideInstrText = false
    private var currentInstrText = ""

    /// Field nesting depth. Increments on every `<w:fldChar
    /// fldCharType="begin">`, decrements on `"end"`. Independent of
    /// TOC tracking — we use it to decide which `end` matches the
    /// outermost TOC field.
    private var fieldDepth = 0
    /// Depth at which the TOC field opened. -1 when no TOC is active.
    private var tocFieldStartDepth = -1
    /// True between the TOC field's `separate` and matching `end`.
    /// Suppresses paragraph + run accumulation for TOC content.
    private var insideTOCContent = false

    /// Captured imageIDs in document order (one per emitted marker).
    private(set) var usedImageIDs: [String] = []

    private init(imagePool: [String: PageImageRecord]) {
        self.imagePool = imagePool
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
        if matches(elementName, suffix: "fldChar") {
            let fldType = attributeDict["w:fldCharType"]
                       ?? attributeDict["fldCharType"]
                       ?? ""
            switch fldType {
            case "begin":
                fieldDepth += 1
                currentInstrText = ""
            case "separate":
                // If the most recently begun field's instruction
                // matched a TOC pattern, the rendered TOC content
                // begins now.
                if isTOCInstruction(currentInstrText), tocFieldStartDepth == -1 {
                    tocFieldStartDepth = fieldDepth
                    insideTOCContent = true
                }
                currentInstrText = ""
            case "end":
                // If we're at the depth where the TOC field opened,
                // close the TOC suppression region.
                if tocFieldStartDepth == fieldDepth {
                    tocFieldStartDepth = -1
                    insideTOCContent = false
                }
                fieldDepth = max(0, fieldDepth - 1)
            default:
                break
            }
            return
        }

        if matches(elementName, suffix: "fldSimple") {
            // Single-element variant: `<w:fldSimple w:instr="TOC \o …"/>`
            // surrounding rendered TOC content. If it's a TOC, we
            // suppress everything up to the matching closing tag.
            let instr = attributeDict["w:instr"] ?? attributeDict["instr"] ?? ""
            if isTOCInstruction(instr) {
                fieldDepth += 1
                tocFieldStartDepth = fieldDepth
                insideTOCContent = true
            }
            return
        }

        if matches(elementName, suffix: "instrText") {
            insideInstrText = true
            currentInstrText = ""
            return
        }

        if matches(elementName, suffix: "t") {
            insideTextNode = true
            currentRun = ""
            return
        }

        // Inline image: `<a:blip r:embed="rIdN">`. The element name
        // is `a:blip` (DrawingML namespace). Look up the rId in the
        // image pool and emit a marker paragraph (image stops are
        // their own block in the rendered text).
        if matches(elementName, suffix: "blip") {
            let rId = attributeDict["r:embed"]
                   ?? attributeDict["embed"]
                   ?? ""
            if !rId.isEmpty, !insideTOCContent,
               let record = imagePool[rId] {
                // Flush any in-progress paragraph first so the marker
                // gets its own block.
                if !currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    paragraphs.append(currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines))
                    currentParagraph = ""
                }
                let marker = "\u{000C}[[POSEY_VISUAL_PAGE:0:\(record.imageID)]]\u{000C}"
                paragraphs.append(marker)
                usedImageIDs.append(record.imageID)
            }
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideInstrText {
            currentInstrText.append(string)
            return
        }
        // Suppress text content while we're inside a TOC field's
        // rendered region.
        guard !insideTOCContent else { return }
        if insideTextNode {
            currentRun.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        if matches(elementName, suffix: "instrText") {
            insideInstrText = false
            return
        }
        if matches(elementName, suffix: "fldSimple") {
            // Mirror the start handler: drop one level if we opened
            // a TOC scope on this element.
            if tocFieldStartDepth == fieldDepth {
                tocFieldStartDepth = -1
                insideTOCContent = false
                fieldDepth = max(0, fieldDepth - 1)
            }
            return
        }

        // Suppress all run/paragraph machinery while inside TOC.
        if insideTOCContent {
            if matches(elementName, suffix: "t") { insideTextNode = false }
            return
        }

        if matches(elementName, suffix: "t") {
            currentParagraph.append(currentRun)
            currentRun = ""
            insideTextNode = false
            return
        }
        if matches(elementName, suffix: "tab") {
            currentParagraph.append("\t")
            return
        }
        if matches(elementName, suffix: "br") || matches(elementName, suffix: "cr") {
            currentParagraph.append("\n")
            return
        }
        if matches(elementName, suffix: "p") {
            let paragraph = currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty {
                paragraphs.append(paragraph)
            }
            currentParagraph = ""
        }
    }

    private func matches(_ elementName: String, suffix: String) -> Bool {
        elementName == suffix || elementName.hasSuffix(":\(suffix)")
    }

    private func isTOCInstruction(_ raw: String) -> Bool {
        // Whitespace-tolerant prefix match. Real instructions look
        // like ` TOC \o "1-3" \h \z \u ` or just `TOC`.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        // Token boundary: the instruction starts with TOC followed
        // by whitespace or end-of-string. Don't false-match TOCREF or
        // similar.
        let upper = trimmed.uppercased()
        if upper == "TOC" { return true }
        if upper.hasPrefix("TOC ") { return true }
        if upper.hasPrefix("TOC\t") { return true }
        return false
    }
}
// ========== BLOCK 06: DOCUMENT XML EXTRACTOR - END ==========
