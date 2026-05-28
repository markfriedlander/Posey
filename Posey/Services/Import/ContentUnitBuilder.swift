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
            // 2026-05-27 — TXT chapter detection. A paragraph that
            // consists of a single line matching the CHAPTER pattern
            // becomes a `.heading` unit with level 1. This drives
            // both heading-styled rendering in the reader and TOC
            // population in TXTLibraryImporter. Patterns mirror
            // FirstChapterAdvance — keep them aligned. Other heading
            // styles (Epilogue, Prologue, Preface, Foreword) included
            // since they're common Gutenberg structure.
            let isHeading = Self.txtHeadingRegex.firstMatch(
                in: trimmed,
                options: [],
                range: NSRange(location: 0, length: (trimmed as NSString).length)
            ) != nil
            units.append(ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: isHeading ? .heading : .prose,
                text: trimmed,
                metadata: isHeading ? ContentUnitMetadata(headingLevel: 1) : ContentUnitMetadata()
            ))
            sequence += 10
        }
        return units
    }

    /// Matches a single-line paragraph that's structurally a chapter
    /// or top-level book heading. Anchors on the whole paragraph
    /// (^…$ without anchorsMatchLines because we've already trimmed
    /// and the paragraph is supposed to be one line).
    fileprivate static let txtHeadingRegex: NSRegularExpression = {
        let pattern = #"^\s*(CHAPTER\s+\d{1,3}[.\s:—-].*|Chapter\s+\d{1,3}[.\s:—-].*|CHAPTER\s+[IVXL]{1,5}[.\s:—-].*|Chapter\s+[IVXL]{1,5}[.\s:—-].*|CHAPTER\s+(?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN)[.\s:—-].*|Epilogue\.?|Prologue\.?|Preface\.?|Foreword\.?|Introduction\.?)\s*$"#
        // Returning a force-tried regex; the pattern is a compile-time
        // constant so the try cannot fail at runtime.
        return try! NSRegularExpression(pattern: pattern)
    }()

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

    /// **Step 9 prerequisite — heading promotion.**
    ///
    /// Walk a unit list and re-kind any `.prose` unit whose paragraph
    /// covers a heading offset (per `headingLevelByOffset`) into a
    /// `.heading` unit with the matching level. Used by DOCX / HTML /
    /// EPUB / PDF importers whose display parsers don't emit heading
    /// blocks of their own; the `(title, plainTextOffset, level)`
    /// records from each format's `parsed.headings` / `parsed.tocEntries`
    /// surface get lifted into proper unit kinds so the unified
    /// `UnitRowView` renderer can style them by `unit.kind`.
    ///
    /// Offset coordinate space matches the persister's `plain_text`:
    /// prose-bearing units joined with `"\n\n"`. A heading offset
    /// counts as "in" a unit when it falls inside `[unitStart,
    /// unitEnd]` (inclusive of either edge — heading detectors
    /// sometimes report the start of leading whitespace).
    ///
    /// Idempotent on `.heading` / `.listItem` / `.blockquote` units —
    /// only `.prose` gets rewritten. Non-prose kinds (`.image`,
    /// `.pageBreak`, `.horizontalRule`) advance the unit list but
    /// don't contribute to the plain_text offset cursor.
    ///
    /// RTF doesn't use this helper because `RTFLibraryImporter.buildUnits`
    /// already assigns heading kind inline as it splits paragraphs.
    /// Markdown's `ContentUnitBuilder.units(from: blocks)` already
    /// emits `.heading` units directly from `DisplayBlockKind.heading`.
    /// TXT has no heading concept.
    /// Heading marker as supplied by an importer. `title` is the
    /// short title string the TOC/heading detector identified (e.g.
    /// "Introduction", "Chapter 1. Loomings"). When provided and the
    /// matched prose unit's text begins with the title but extends
    /// past it (the "title + opening body in the same paragraph"
    /// pattern that PDF / EPUB / DOCX / HTML imports often produce),
    /// the resulting heading unit carries `metadata.titleLength` so
    /// the renderer styles only the title portion as heading and the
    /// remainder as body prose. Pass `title: nil` to fall back to
    /// promoting the whole unit as a heading (legacy behavior).
    struct HeadingMarker {
        let level: Int
        let title: String?
    }

    static func applyHeadingMarkers(
        to units: [ContentUnit],
        headingMarkersByOffset: [Int: HeadingMarker]
    ) -> [ContentUnit] {
        guard !headingMarkersByOffset.isEmpty else { return units }
        var out: [ContentUnit] = []
        out.reserveCapacity(units.count)
        var cursor = 0
        var firstProseSeen = false
        for unit in units {
            if !unit.kind.carriesProseText {
                out.append(unit)
                continue
            }
            // "\n\n" separator before this prose-bearing unit, except
            // the very first one — matches the persister's
            // `joined(separator: "\n\n")` over prose-bearing units.
            if firstProseSeen { cursor += 2 }
            firstProseSeen = true
            let start = cursor
            let end = cursor + unit.text.count
            cursor = end

            // Only plain `.prose` gets rewritten. Pre-existing heading /
            // list / quote kinds are preserved.
            guard unit.kind == .prose else {
                out.append(unit)
                continue
            }
            // Heading detector may report the offset at the start of
            // the paragraph proper or anywhere inside leading
            // whitespace. Inclusive range check.
            guard let matched = (start...end).first(where: { headingMarkersByOffset[$0] != nil }),
                  let marker = headingMarkersByOffset[matched] else {
                out.append(unit)
                continue
            }
            let titleLength = computeTitleLength(in: unit.text, title: marker.title)
            out.append(ContentUnit(
                id: unit.id,
                documentID: unit.documentID,
                sequence: unit.sequence,
                kind: .heading,
                text: unit.text,
                metadata: ContentUnitMetadata(
                    headingLevel: marker.level,
                    titleLength: titleLength
                ),
                revision: unit.revision,
                sourceTier: unit.sourceTier
            ))
        }
        return out
    }

    /// If `title` is a prefix of `unitText` (after trimming leading
    /// whitespace on the unit) AND the unit contains body text past
    /// the title, return the character count in `unitText` that
    /// covers the title plus any separator (newline / space). Return
    /// nil otherwise — meaning the whole unit IS the title and should
    /// render as a pure heading.
    private static func computeTitleLength(in unitText: String, title: String?) -> Int? {
        guard let title, !title.isEmpty else { return nil }
        let leadingWhitespace = unitText.prefix(while: { $0.isWhitespace }).count
        let afterLeading = unitText.dropFirst(leadingWhitespace)
        // Compare case-sensitively; importers preserve case. We don't
        // try to be clever about whitespace inside the title — the
        // TOC detector's title strings match the source text exactly
        // for the formats that hit this path.
        guard afterLeading.hasPrefix(title) else { return nil }
        let titleEnd = leadingWhitespace + title.count
        // No body after the title (modulo trailing whitespace) — let
        // the whole unit be the heading.
        let tail = unitText.dropFirst(titleEnd)
        let nonWhitespaceTail = tail.contains(where: { !$0.isWhitespace })
        guard nonWhitespaceTail else { return nil }
        // Consume one separator character (the typical "\n" or " ")
        // so the body remainder starts cleanly. The renderer will
        // still see the rest of the whitespace and lay it out.
        var consumeSeparator = 0
        if let first = tail.first, first.isWhitespace {
            consumeSeparator = 1
        }
        return titleEnd + consumeSeparator
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
