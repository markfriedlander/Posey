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
    /// One TOC entry surfaced from a heading-styled paragraph in the
    /// `.docx`. Title is the paragraph text; offset is the byte offset
    /// of that paragraph's first character in the final plainText.
    struct DOCXHeadingEntry {
        let level: Int
        let title: String
        let plainTextOffset: Int
    }

    func loadDocument(from url: URL) throws -> (displayText: String, plainText: String, images: [PageImageRecord], headings: [DOCXHeadingEntry], coreTitle: String?) {
        let data = try Data(contentsOf: url)
        return try loadDocument(fromData: data)
    }

    func loadDocument(fromData data: Data) throws -> (displayText: String, plainText: String, images: [PageImageRecord], headings: [DOCXHeadingEntry], coreTitle: String?) {
        let archive = try archive(from: data)
        let documentXML = try archive.entryData(named: "word/document.xml")
        // **Bundle 2a — DOCX `<dc:title>` extraction.** The
        // `docProps/core.xml` part carries Dublin Core metadata
        // including `<dc:title>`. Plenty of real-world DOCXs have
        // this populated; we read it (best-effort) and pass it up
        // to the library importer for use as the document title.
        let coreTitle: String? = {
            guard let coreData = try? archive.entryData(named: "docProps/core.xml"),
                  let coreString = String(data: coreData, encoding: .utf8) else { return nil }
            // Quick regex match — core.xml has exactly one <dc:title>.
            guard let range = coreString.range(of: #"<dc:title[^>]*>([\s\S]*?)</dc:title>"#,
                                               options: [.regularExpression, .caseInsensitive]) else { return nil }
            let raw = String(coreString[range])
            let inner = raw
                .replacingOccurrences(of: #"<dc:title[^>]*>"#, with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "</dc:title>", with: "",
                                      options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }()

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

        // 2026-05-06 (parity #2) — displayText KEEPS the visual-page
        // markers; DOCXDisplayParser converts them to .visualPlaceholder
        // blocks at render time. plainText is the marker-stripped form
        // used for TTS / search / RAG / character count.
        let normalizedDisplay = normalizeDisplay(extracted.displayText)
        let plainText = stripVisualPageMarkers(from: normalizedDisplay)
        let normalizedPlain = normalizePlain(plainText)
        guard !normalizedPlain.isEmpty else { throw ImportError.emptyDocument }

        // Filter image pool to only those actually emitted (some
        // .docx archives include unused images).
        let usedImages = extracted.usedImageIDs.compactMap { id -> PageImageRecord? in
            imagePool.values.first(where: { $0.imageID == id })
        }

        // 2026-05-06 — Heading → TOC offset mapping. The extractor
        // gives us paragraph indexes; the displayText was assembled
        // by joining paragraphs with "\n\n". Compute each heading's
        // offset by walking the paragraph list and accumulating
        // lengths. Then map that to the plainText (which has
        // visual-page markers stripped — for headings, which sit in
        // ordinary text paragraphs, the offsets are unchanged).
        var paragraphStartOffsets: [Int] = []
        var runningOffset = 0
        for (idx, p) in extracted.headings.map({ $0.paragraphIndex }).enumerated() { _ = idx; _ = p }  // placeholder; we walk paragraphs below
        var paragraphs: [String] = []
        // Re-derive paragraph list by splitting displayText. The
        // extractor's joined output isn't normalized, so split on the
        // original "\n\n" separator before normalization for accurate
        // index mapping.
        paragraphs = extracted.displayText.components(separatedBy: "\n\n")
        for (i, p) in paragraphs.enumerated() {
            paragraphStartOffsets.append(runningOffset)
            runningOffset += p.count
            if i < paragraphs.count - 1 {
                runningOffset += 2 // the "\n\n" separator
            }
        }
        // The normalizedDisplay → plainText transform strips visual-
        // page markers, which contain the marker substring only. For
        // heading paragraphs (which never contain markers), offsets
        // before the heading paragraph could shift if any earlier
        // paragraph held a marker. Compute a "marker-loss" prefix
        // sum so each heading's plainText offset = its displayText
        // offset minus the total marker-character length before it.
        let markerPattern = "\\x{000C}?\\[\\[POSEY_VISUAL_PAGE:[^\\]]+\\]\\]\\x{000C}?"
        let regex = try? NSRegularExpression(pattern: markerPattern)
        var markerLossPrefix: [Int] = Array(repeating: 0, count: paragraphs.count + 1)
        if let regex {
            for (i, p) in paragraphs.enumerated() {
                let nsP = p as NSString
                let matches = regex.matches(in: p, range: NSRange(location: 0, length: nsP.length))
                let markerChars = matches.reduce(0) { $0 + $1.range.length }
                markerLossPrefix[i + 1] = markerLossPrefix[i] + markerChars
            }
        }
        // NOTE (2026-06-02) — these heading offsets are computed in the
        // displayText `\n\n`-split coordinate, which DIVERGES from the units
        // coordinate the reader navigates whenever a paragraph contains internal
        // `<w:br/>` line breaks (single `\n`): such a paragraph is ONE entry here
        // but its lines can become separate units, so the offset lands early.
        // The value is also non-robust — it shifted from units-aligned to drifted
        // purely from recompiling the shared module (traced 2026-06-02). It is no
        // longer authoritative for navigation: `DatabaseManager.persistParsedDocument`
        // re-anchors every TOC entry to its heading UNIT
        // (`ContentUnitBuilder.reanchorTOCToHeadingUnits`), which is the canonical,
        // units-coordinate source of truth. These offsets remain only as the input
        // the re-anchor disambiguates against (nearest-offset) and as the TOC-skip
        // hint; both tolerate the imprecision.
        let docxHeadings: [DOCXHeadingEntry] = extracted.headings.compactMap { h in
            guard h.paragraphIndex >= 0, h.paragraphIndex < paragraphStartOffsets.count else {
                return nil
            }
            // 2026-06-13 (DEFECT-docx-italic-underscore-leak / #10) — the
            // heading/TOC path is separate from the body normalizer, so DOCX
            // italic/bold runs that the extractor serialized as Markdown emphasis
            // (`_continued_`, `(_Kept in shorthand._)`) leaked their literal `_`/`*`
            // into heading + Contents-sheet titles. Strip the emphasis markup, and
            // DROP a wholly-parenthetical "heading" — a bold aside like "(Kept in
            // shorthand.)" was wrongly promoted into the TOC; a real heading is
            // never fully wrapped in parentheses.
            let cleanedTitle = Self.cleanHeadingTitle(h.title)
            guard !cleanedTitle.isEmpty,
                  !(cleanedTitle.hasPrefix("(") && cleanedTitle.hasSuffix(")")) else {
                return nil
            }
            let displayOffset = paragraphStartOffsets[h.paragraphIndex]
            let plainOffset = max(0, displayOffset - markerLossPrefix[h.paragraphIndex])
            return DOCXHeadingEntry(level: h.level, title: cleanedTitle, plainTextOffset: plainOffset)
        }
        return (normalizedDisplay, normalizedPlain, usedImages, docxHeadings, coreTitle)
    }
// ========== BLOCK 02: ENTRY POINTS - END ==========


// ========== BLOCK 03: NORMALIZATION - START ==========
    /// Display normalization preserves visual-page markers; plain-text
    /// normalization is applied after marker strip.
    ///
    /// 2026-06-08 (normalizer-parity pass): both route through the single
    /// shared `TextNormalizer.normalizeUniversal` — replacing the prior
    /// hand-rolled subset — so DOCX gets the SAME cleanup as every other
    /// format, including `stripGutenbergItalics` (`_Mem._` → `Mem.`) and
    /// CP1252 mojibake repair it previously lacked. hardWrapped:false (DOCX
    /// emits real paragraphs). The `[[POSEY_VISUAL_PAGE:…]]` markers contain
    /// no `_`/hyphen-wrap patterns, so the universal passes leave them intact.
    private func normalizeDisplay(_ text: String) -> String {
        TextNormalizer.normalizeUniversal(text)
    }

    private func normalizePlain(_ text: String) -> String {
        TextNormalizer.normalizeUniversal(text)
    }

    /// 2026-06-13 — Clean a DOCX heading/TOC title. The extractor serializes
    /// italic/bold runs as Markdown emphasis (`_word_`, `*word*`, `**word**`,
    /// `__word__`); in the BODY the plain-text normalizer removes it, but the
    /// heading/TOC path is separate and leaked the literal markup into titles +
    /// the Contents sheet (DEFECT-docx-italic-underscore-leak). Unwrap each
    /// emphasis span to its inner text. CATEGORY (Rule 10): any DOCX heading whose
    /// run carries emphasis; clean titles are untouched (no emphasis → no-op).
    private static func cleanHeadingTitle(_ s: String) -> String {
        var t = s
        for pattern in [#"\*\*([^*]+)\*\*"#, #"__([^_]+)__"#, #"\*([^*]+)\*"#, #"_([^_]+)_"#] {
            t = t.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripVisualPageMarkers(from text: String) -> String {
        // ICU-style hex escape (no braces) for U+000C form feed; plus
        // explicit char-class escape for the brackets.
        let pattern = "\\x{000C}?\\[\\[POSEY_VISUAL_PAGE:[^\\]]+\\]\\]\\x{000C}?"
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
    /// One TOC entry candidate captured from a heading-styled paragraph.
    /// `paragraphIndex` lets us compute the displayText offset after the
    /// extractor finishes (paragraphs are joined with `\n\n`).
    struct Heading {
        let level: Int
        let title: String
        let paragraphIndex: Int
    }

    struct Result {
        let displayText: String
        let usedImageIDs: [String]
        let headings: [Heading]
    }

    static func extract(from data: Data, imagePool: [String: PageImageRecord]) throws -> Result {
        let extractor = WordDocumentXMLExtractor(imagePool: imagePool)
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        guard parser.parse() else {
            throw DOCXDocumentImporter.ImportError.unreadableDocument
        }
        // **Heading inference fallback (Mark-requested 2026-05-26).**
        //
        // DOCXs authored without explicit `Heading1/HeadingN` style
        // tags (hand-rolled docs, exports from minimal editors, the
        // StructuredSample fixture) yield zero headings from the
        // `<w:pStyle>` pass — even when the document obviously has
        // a chapter title at the top. Heuristic fallback: scan the
        // collected paragraphs for "title-like" lines and synthesize
        // heading entries.
        //
        // A paragraph qualifies as an implicit heading when ALL of:
        //   1. Length ≤ 80 chars (titles are short)
        //   2. Doesn't end with `.`, `!`, `?`, `:`, `;`, `,` (no
        //      sentence-terminal punctuation — prose paragraphs do)
        //   3. Doesn't start with `• ` (not a list item — the
        //      bullet marker is prepended by the extractor)
        //   4. The next non-empty paragraph is "prose-shaped" —
        //      ends with `.`, `!`, or `?` (so we're confident this
        //      is a title introducing prose, not a header that's
        //      part of a list of headers)
        //
        // Only runs when the structured-style pass produced zero
        // headings — defensive: if even one Heading style is
        // present, the doc was authored with structure and we
        // shouldn't second-guess it.
        var finalHeadings = extractor.headings
        if finalHeadings.isEmpty {
            for (idx, paragraph) in extractor.paragraphs.enumerated() {
                guard paragraph.count <= 80,
                      !paragraph.hasPrefix("• "),
                      let lastChar = paragraph.last,
                      !".!?:;,".contains(lastChar) else { continue }
                // Look at next paragraph(s) for prose shape.
                var nextIdx = idx + 1
                while nextIdx < extractor.paragraphs.count {
                    let next = extractor.paragraphs[nextIdx]
                    if !next.isEmpty {
                        if let nextLast = next.last,
                           ".!?".contains(nextLast) {
                            // Idiomatic heading — paragraph that introduces prose.
                            // Level 1 for the first inferred heading at the document
                            // start; level 2 for subsequent ones (rough subsection
                            // pattern; better than not detecting at all).
                            let level = finalHeadings.isEmpty ? 1 : 2
                            finalHeadings.append(Heading(
                                level: level,
                                title: paragraph,
                                paragraphIndex: idx
                            ))
                        }
                        break
                    }
                    nextIdx += 1
                }
            }
        }
        return Result(
            displayText: extractor.paragraphs.joined(separator: "\n\n"),
            usedImageIDs: extractor.usedImageIDs,
            headings: finalHeadings
        )
    }

    private let imagePool: [String: PageImageRecord]
    private var paragraphs: [String] = []
    private var currentParagraph = ""
    private var currentRun = ""
    private var insideTextNode = false
    private var insideInstrText = false
    private var currentInstrText = ""

    /// Heading level for the paragraph currently being assembled, or
    /// nil if it isn't styled as a heading. Set when we encounter
    /// `<w:pStyle w:val="HeadingN"/>` (or "Heading", "Title").
    private var currentHeadingLevel: Int?
    private(set) var headings: [Heading] = []

    /// Whether the paragraph currently being assembled is a list item.
    /// Set true when we encounter `<w:numPr>` inside the paragraph's
    /// properties. v1 limitation (per DECISIONS.md "List markers"):
    /// every list item is rendered as a bullet because reliably
    /// distinguishing bullet from numbered requires resolving the
    /// `numId` against the doc's `numbering.xml`, a much larger lift.
    /// Numbered DOCX lists rendered as bullets is documented as a
    /// known v1 limitation in NEXT.md.
    private var currentIsListItem = false

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

    // ── Table state (2026-06-15). DOCX tables (`<w:tbl>`) previously had no
    // grouping: each cell's `<w:p>` flushed as a loose top-level paragraph, so a
    // grid became a meaningless run of fragments (docx_tables-and-images:
    // "Chapter","Words","Notes","78","real prose"…). We now capture the row/cell
    // structure and emit ONE coherent block (rows = lines, cells joined " | "),
    // which is readable + searchable. (Image rasterization of the table — Mark's
    // table-as-image plan — layers on top of this captured structure next.)
    private var tableDepth = 0
    private var tableRows: [[String]] = []
    private var currentRow: [String] = []
    private var cellParagraphs: [String] = []
    private var insideCell = false

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

        // ── Table structure. `matches` is an exact local-name check, so "tbl"
        // won't catch "tblPr"/"tblGrid", "tc" won't catch "tcPr", "tr" won't
        // catch "trPr". Nested tables increment tableDepth; we assemble only when
        // it returns to 0 (a nested table's cells fold into the outer cell).
        if matches(elementName, suffix: "tbl") {
            if tableDepth == 0 { tableRows = []; currentRow = [] }
            tableDepth += 1
            return
        }
        if tableDepth > 0 {
            if matches(elementName, suffix: "tr") { currentRow = []; return }
            if matches(elementName, suffix: "tc") { cellParagraphs = []; insideCell = true; return }
        }

        if matches(elementName, suffix: "t") {
            insideTextNode = true
            currentRun = ""
            return
        }

        // 2026-05-06 (parity #4) — List item detection. Word writes
        // `<w:numPr>` inside `<w:pPr>` for any paragraph that
        // participates in a list (bullet or numbered). When we see it
        // we mark the in-progress paragraph as a list item; the marker
        // gets prepended at paragraph-flush time.
        if matches(elementName, suffix: "numPr") {
            currentIsListItem = true
            return
        }

        // 2026-05-06 — Heading style detection. `<w:pStyle w:val="HeadingN"/>`
        // marks the current paragraph as a heading at level N. Word also
        // uses `Title` for the document title, treated as level 1.
        if matches(elementName, suffix: "pStyle") {
            let raw = (attributeDict["w:val"] ?? attributeDict["val"] ?? "")
            // Match "Heading1", "Heading2", ..., or "Title" (case-insensitive).
            // Real-world docs sometimes use "heading1" / "Heading 1" — be tolerant.
            let lower = raw.lowercased().replacingOccurrences(of: " ", with: "")
            if lower == "title" {
                currentHeadingLevel = 1
            } else if lower.hasPrefix("heading"),
                      let level = Int(lower.replacingOccurrences(of: "heading", with: "")),
                      level >= 1 && level <= 9 {
                currentHeadingLevel = level
            }
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
        // ── Table assembly (close tags).
        if tableDepth > 0, matches(elementName, suffix: "tc") {
            currentRow.append(cellParagraphs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
            cellParagraphs = []
            insideCell = false
            return
        }
        if tableDepth > 0, matches(elementName, suffix: "tr") {
            tableRows.append(currentRow)
            currentRow = []
            return
        }
        if matches(elementName, suffix: "tbl") {
            tableDepth = max(0, tableDepth - 1)
            if tableDepth == 0 {
                // One coherent block: rows = lines, cells joined by " | ".
                // Readable + searchable now; the table-as-image step rasterizes
                // from this same captured structure.
                let rendered = tableRows
                    .map { $0.joined(separator: " | ") }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rendered.isEmpty { paragraphs.append(rendered) }
                tableRows = []
                currentRow = []
            }
            return
        }

        if matches(elementName, suffix: "p") {
            let paragraph = currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            // Inside a table cell: collect into the cell, not the top-level
            // paragraph list, and skip heading detection (cells are data).
            if insideCell {
                if !paragraph.isEmpty { cellParagraphs.append(paragraph) }
                currentParagraph = ""
                currentHeadingLevel = nil
                currentIsListItem = false
                return
            }
            if !paragraph.isEmpty {
                // Prepend a bullet marker for list-item paragraphs.
                // Skip the marker on heading-styled list items (rare
                // but possible) so the heading typography still wins.
                let final: String
                if currentIsListItem && currentHeadingLevel == nil {
                    final = "• " + paragraph
                } else {
                    final = paragraph
                }
                let paragraphIndex = paragraphs.count
                paragraphs.append(final)
                if let level = currentHeadingLevel {
                    headings.append(Heading(level: level, title: final, paragraphIndex: paragraphIndex))
                }
            }
            currentParagraph = ""
            currentHeadingLevel = nil
            currentIsListItem = false
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
