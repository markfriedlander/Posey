import Foundation

// ========== BLOCK 01: CONTENT UNIT BUILDER - START ==========

/// Shared helpers used by every format's library importer when
/// translating legacy parser output into `ContentUnit`s for the
/// rebuild's content-units store.
///
/// 2026-05-23 — introduced as part of the architecture rebuild.
enum ContentUnitBuilder {

    /// Convert a `DisplayBlock` list (produced by `MarkdownParser`,
    /// `DOCXDisplayParser`, `HTMLDisplayParser`, `EPUBDisplayParser`,
    /// `PDFDisplayParser`) into a `ContentUnit` list. One block → one
    /// unit. Sequence numbers increase by 10 so future in-place
    /// insertions don't force a renumber.
    static func units(from blocks: [DisplayBlock], documentID: UUID) -> [ContentUnit] {
        var units: [ContentUnit] = []
        var sequence = 10
        for block in blocks {
            units.append(unit(from: block, documentID: documentID, sequence: sequence))
            sequence += 10
        }
        return units
    }

    /// Build a plain-paragraph unit list from a plainText string.
    /// Used by formats whose display parser only emits blocks when
    /// the doc has rich content (images, tables) and returns empty
    /// for plain-paragraph documents — DOCX/HTML/RTF in the rebuild
    /// fall back to this when the display parser is empty.
    ///
    /// Same algorithm as TXT: split on blank-line boundaries, each
    /// non-empty paragraph becomes one `.prose` unit.
    static func proseUnits(fromPlainText plainText: String, documentID: UUID) -> [ContentUnit] {
        var units: [ContentUnit] = []
        var sequence = 10
        let paragraphs = plainText.components(separatedBy: "\n\n")
        for rawParagraph in paragraphs {
            let trimmed = rawParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            units.append(ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .prose,
                text: trimmed
            ))
            sequence += 10
        }
        return units
    }

    /// Convenience for importers that have both: try the display
    /// parser's blocks first, fall back to plainText paragraph
    /// splitting if the display parser came up empty.
    static func unitsPreferringBlocks(
        blocks: [DisplayBlock],
        plainText: String,
        documentID: UUID
    ) -> [ContentUnit] {
        if blocks.isEmpty {
            return proseUnits(fromPlainText: plainText, documentID: documentID)
        }
        return units(from: blocks, documentID: documentID)
    }

    /// PDF-specific: walk a form-feed-separated displayText, emit a
    /// `pageBreak` unit at each page boundary, then prose / image
    /// units for the page's content. Page numbers are 0-based and
    /// stored in `metadata.pageNumber`; the reader's page map is
    /// derived by querying for `pageBreak` units.
    ///
    /// VisualPageMarker recognition (`[[POSEY_VISUAL_PAGE:N:uuid]]`)
    /// is preserved from `PDFDisplayParser` — a page that consists
    /// entirely of one of these markers becomes a single `.image`
    /// unit.
    static func unitsFromPDFDisplayText(
        _ displayText: String,
        documentID: UUID
    ) -> [ContentUnit] {
        let pageSeparator = "\u{000C}"
        let normalized = displayText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var units: [ContentUnit] = []
        var sequence = 10
        let pages = normalized.components(separatedBy: pageSeparator)
        for (pageIndex, rawPage) in pages.enumerated() {
            let page = rawPage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !page.isEmpty else { continue }

            // Page break before each page's content.
            units.append(ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .pageBreak,
                text: "",
                metadata: ContentUnitMetadata(pageNumber: pageIndex)
            ))
            sequence += 10

            // Whole-page visual marker?
            if let (visualPageNumber, imageID) = PDFDocumentImporter.parseVisualPageMarker(from: page) {
                units.append(ContentUnit(
                    documentID: documentID,
                    sequence: sequence,
                    kind: .image,
                    text: "Visual content on page \(visualPageNumber)",
                    metadata: ContentUnitMetadata(imageID: imageID)
                ))
                sequence += 10
                continue
            }

            // Paragraph-split prose.
            let paragraphs = page
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for paragraph in paragraphs {
                units.append(ContentUnit(
                    documentID: documentID,
                    sequence: sequence,
                    kind: .prose,
                    text: paragraph
                ))
                sequence += 10
            }
        }
        return units
    }

    /// Single-block conversion, exposed so formats with mixed
    /// content (image interleaving, page breaks) can call it from
    /// their own loops.
    static func unit(from block: DisplayBlock, documentID: UUID, sequence: Int) -> ContentUnit {
        switch block.kind {
        case .heading(let level):
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .heading,
                text: block.text,
                metadata: ContentUnitMetadata(headingLevel: level)
            )
        case .paragraph:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .prose,
                text: block.text
            )
        case .bullet:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .listItem,
                text: block.text,
                metadata: ContentUnitMetadata(listMarker: block.displayPrefix ?? "• ")
            )
        case .numbered:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .listItem,
                text: block.text,
                metadata: ContentUnitMetadata(listMarker: block.displayPrefix ?? "1. ")
            )
        case .quote:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .blockquote,
                text: block.text
            )
        case .horizontalRule:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .horizontalRule,
                text: ""
            )
        case .visualPlaceholder:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .image,
                text: block.text,
                metadata: ContentUnitMetadata(imageID: block.imageID)
            )
        }
    }

    /// Map a plainText character offset (the coordinate space the
    /// existing smart-skip detectors operate in) to the first unit
    /// whose cumulative position is at or after the offset. Used by
    /// every importer to lift smart-skip detector output onto a unit
    /// reference.
    ///
    /// Cumulative position rule: `\n\n` separator between prose-bearing
    /// units. Matches `persistParsedDocument`'s join scheme exactly, so
    /// offsets used to look up units agree with the derived plainText
    /// the persister writes.
    static func firstUnit(
        in units: [ContentUnit],
        atOrAfterPlainTextOffset offset: Int
    ) -> ContentUnit? {
        guard offset > 0 else { return units.first }
        var cumulative = 0
        for (i, unit) in units.enumerated() {
            if cumulative >= offset { return unit }
            if unit.kind.carriesProseText {
                cumulative += unit.text.count + 2
            }
            if cumulative > offset {
                let nextIndex = i + 1
                if units.indices.contains(nextIndex) {
                    return units[nextIndex]
                }
                return unit
            }
        }
        return units.last
    }
}

// ========== BLOCK 01: CONTENT UNIT BUILDER - END ==========
