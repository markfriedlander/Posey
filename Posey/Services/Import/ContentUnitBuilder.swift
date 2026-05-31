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

        // 2026-05-31 (ingestion audit, Bug B) — promote by TITLE, with the
        // offset only DISAMBIGUATING. The previous code turned whatever unit a
        // marker's offset landed in into a heading, WITHOUT checking the title
        // actually heads that unit. Importer offsets are imprecise in BOTH
        // directions: EPUB TOC offsets land one unit LATE (the offset for
        // "CHAPTER 1. Loomings." resolves into the next paragraph "Call me
        // Ishmael…" → every chapter's first body paragraph became a level-1
        // heading: 136 of 142 "headings" in Moby EPUB were full prose
        // paragraphs), and DOCX offsets can land EARLY. So neither "the unit at
        // the offset" nor a one-directional look-back is correct.
        //
        // The title is the identity. For each marker we promote the `.prose`
        // unit whose text HEADS WITH the title that sits NEAREST the marker's
        // offset (nearest disambiguates a title that appears more than once —
        // e.g. a chapter name in both the front-matter Contents listing and the
        // body). If no unit heads with the title, the marker is dropped — a
        // non-matching (often long) paragraph is NEVER turned into a heading.
        //
        // STEP 3 — the CATEGORY this generalizes to, and its edge cases (so a
        // future session doesn't have to rediscover them). Category: ANY format
        // whose headings arrive as (offset, title) markers from a separate
        // detection pass, where the offset can be imprecise. That's PDF, EPUB,
        // HTML, RTF — every caller of this function.
        //   • Offset slightly late (EPUB) or early (DOCX): nearest title-match
        //     across all units corrects BOTH directions — this is why it isn't
        //     a one-directional look-back.
        //   • Offset WILDLY wrong (not just off-by-one): still resolves, because
        //     the title is matched anywhere and `nearest` only breaks ties.
        //     Title-anchoring is STRICTLY more robust than offset-anchoring here.
        //   • Title repeats (Contents listing + body; or genuinely repeated
        //     sections like Frankenstein's two "To Mrs. Saville, England."
        //     letters, which carry one marker each): nearest-offset assigns each
        //     marker to its own occurrence.
        //   • Title heads a unit FUSED with body (PDF dialogues: "Three-Part
        //     Invention Achilles (a Greek warrior…)"): promoted, and
        //     computeTitleLength styles only the title prefix — not the
        //     paragraph. Verified on GEB.
        //   • Title found in NO unit (e.g. a normalized title that no longer
        //     prefix-matches the raw unit text): marker dropped. We accept a
        //     MISSING heading over a WRONG one. This is the one residual
        //     limitation — a whitespace/normalization drift between a detector's
        //     title and the unit text silently loses that heading. Tolerable
        //     today because the TOC detectors emit titles that match the source
        //     exactly for these formats; if a format ever normalizes titles,
        //     make the prefix compare whitespace-insensitive HERE and in
        //     computeTitleLength together (they must agree).
        //   • Generic/short title ("I.", "II.") that also prefixes a LONGER
        //     title's unit (Sherlock: "I." vs "I. A Scandal in Bohemia"):
        //     HANDLED by ranking EXACT title==unit matches ahead of prefix-only
        //     matches (see the loop), so each marker takes the unit that equals
        //     its own title. Residual risk only if a generic title has no exact
        //     unit anywhere AND the offset is wildly wrong — a narrow edge.
        //   • DOCX with no heading styles: the importer's inference fallback
        //     still supplies (offset, title) markers; they flow through here
        //     unchanged.
        //   • Page-number edge cases (appendices that reset numbering, roman vs
        //     arabic) do NOT reach here — those are the TOC *parser's* concern
        //     (PDFGeneralizedTOCDetector); this function only sees title+offset.
        // Verified across the category, not one document: EPUB (Moby chapters
        // headed, body prose), DOCX (7 legit headings, 0 false), PDF (GEB 21
        // dialogues), TXT, HTML — multiple real corpus docs per format.

        // Phase 1 — start offset of each prose-bearing unit, in the persister's
        // "\n\n"-joined coordinate space (the space the marker offsets use).
        var startOffsets = [Int](repeating: -1, count: units.count)
        var cursor = 0
        var firstProseSeen = false
        for i in units.indices where units[i].kind.carriesProseText {
            if firstProseSeen { cursor += 2 }
            firstProseSeen = true
            startOffsets[i] = cursor
            cursor += units[i].text.count
        }

        // Phase 2 — resolve each marker to the nearest title-matching prose unit.
        var promotions: [Int: HeadingMarker] = [:]
        func consider(_ idx: Int, _ marker: HeadingMarker) {
            // If two markers target the same unit, keep the shallower (lower) level.
            if let existing = promotions[idx], existing.level <= marker.level { return }
            promotions[idx] = marker
        }
        for (offset, marker) in headingMarkersByOffset {
            if let title = marker.title, !title.isEmpty {
                // Rank candidates EXACT-match-first (the unit IS the title), then
                // nearest offset.
                //   • STEP-3 (Sherlock): a bare-numeral title "I." prefix-matches
                //     BOTH the "I." sub-section unit AND the "I. A Scandal in
                //     Bohemia" story unit — exact-first sends each marker to the
                //     unit that equals its own title.
                //   • STEP-3 (Sherlock, deeper): matching is WHITESPACE-TOLERANT.
                //     The TOC title "I. A Scandal in Bohemia" (flattened to one
                //     line) must match the unit "I.\nA Scandal in Bohemia" whose
                //     heading is split across lines in the EPUB source. Any
                //     whitespace run matches any whitespace run; without this,
                //     every line-split EPUB chapter/story title silently loses
                //     its heading (Sherlock's 12 stories did).
                let titleFirst = title.first(where: { !$0.isWhitespace })
                var best: Int? = nil
                var bestExact = 1          // 0 = exact, 1 = prefix-only (lower wins)
                var bestDist = Int.max
                for i in units.indices where units[i].kind == .prose && startOffsets[i] >= 0 {
                    // Cheap pre-filter before the char-walk: first non-whitespace
                    // char must match.
                    guard units[i].text.first(where: { !$0.isWhitespace }) == titleFirst else { continue }
                    guard let m = Self.titleMatch(in: units[i].text, title: title) else { continue }
                    let exactRank = m.isExact ? 0 : 1
                    let dist = abs(startOffsets[i] - offset)
                    if best == nil || exactRank < bestExact
                        || (exactRank == bestExact && dist < bestDist) {
                        best = i; bestExact = exactRank; bestDist = dist
                    }
                }
                if let b = best { consider(b, marker) }
                // else: title not found in any unit — drop the marker.
            } else {
                // No title to validate against — promote the prose unit whose
                // range contains the offset (legacy behavior for title-less markers).
                if let idx = units.indices.first(where: { i in
                    units[i].kind == .prose && startOffsets[i] >= 0
                        && offset >= startOffsets[i]
                        && offset <= startOffsets[i] + units[i].text.count
                }) {
                    consider(idx, marker)
                }
            }
        }

        // Phase 3 — emit, promoting resolved units.
        var out: [ContentUnit] = []
        out.reserveCapacity(units.count)
        for (i, unit) in units.enumerated() {
            if unit.kind == .prose, let marker = promotions[i] {
                out.append(Self.makeHeadingUnit(from: unit, marker: marker))
            } else {
                out.append(unit)
            }
        }
        return out
    }

    /// Build a `.heading` unit from a prose `unit`, carrying the marker's level
    /// and the computed title-prefix length (so the renderer styles only the
    /// title, not any trailing body in the same unit).
    private static func makeHeadingUnit(from unit: ContentUnit, marker: HeadingMarker) -> ContentUnit {
        ContentUnit(
            id: unit.id,
            documentID: unit.documentID,
            sequence: unit.sequence,
            kind: .heading,
            text: unit.text,
            metadata: ContentUnitMetadata(
                headingLevel: marker.level,
                titleLength: computeTitleLength(in: unit.text, title: marker.title)
            ),
            revision: unit.revision,
            sourceTier: unit.sourceTier
        )
    }

    /// Whitespace-tolerant title match. Returns nil if `title` does not head
    /// `unitText` (after leading whitespace). Any run of whitespace in EITHER
    /// string matches any run in the other — so a TOC title "I. A Scandal in
    /// Bohemia" matches a unit "I.\nA Scandal in Bohemia" whose heading was
    /// split across lines in the EPUB source. On a match returns:
    ///   • `titleLength`: character count from `unitText`'s start through the end
    ///     of the matched title PLUS one trailing separator char — the renderer
    ///     styles `[0, titleLength)` as the heading and the remainder as body.
    ///     nil when the unit IS the title (no body after), i.e. style it whole.
    ///   • `isExact`: true when the unit holds nothing but the title.
    /// Case-sensitive on non-whitespace (importers preserve case).
    private static func titleMatch(in unitText: String, title: String) -> (titleLength: Int?, isExact: Bool)? {
        let u = Array(unitText)
        let t = Array(title)
        var ui = 0, ti = 0
        while ui < u.count, u[ui].isWhitespace { ui += 1 }
        while ti < t.count {
            if t[ti].isWhitespace {
                guard ui < u.count, u[ui].isWhitespace else { return nil }
                while ui < u.count, u[ui].isWhitespace { ui += 1 }
                while ti < t.count, t[ti].isWhitespace { ti += 1 }
            } else {
                guard ui < u.count, u[ui] == t[ti] else { return nil }
                ui += 1; ti += 1
            }
        }
        let titleEnd = ui   // char index in unitText just past the matched title
        var hasBody = false
        var j = ui
        while j < u.count { if !u[j].isWhitespace { hasBody = true; break }; j += 1 }
        guard hasBody else { return (titleLength: nil, isExact: true) }
        let consumeSeparator = (titleEnd < u.count && u[titleEnd].isWhitespace) ? 1 : 0
        return (titleLength: titleEnd + consumeSeparator, isExact: false)
    }

    /// Title-prefix length for the heading renderer (styles only the title, not
    /// trailing body). Delegates to the whitespace-tolerant `titleMatch` so it
    /// stays consistent with the promotion decision in `applyHeadingMarkers`.
    private static func computeTitleLength(in unitText: String, title: String?) -> Int? {
        guard let title, !title.isEmpty else { return nil }
        return titleMatch(in: unitText, title: title)?.titleLength
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
        for unit in units {
            if cumulative >= offset { return unit }
            if unit.kind.carriesProseText {
                cumulative += unit.text.count + 2
            }
            // 2026-05-28 — Mark caught: Pride EPUB opens past the
            // famous "IT is a truth universally acknowledged…" first
            // line into "However little known…" (second sentence).
            // Root cause was here: when the skip offset falls INSIDE
            // a unit's range (cumulative_before ≤ offset <
            // cumulative_after), the prior code returned the NEXT
            // unit — skipping past the unit that ACTUALLY contains
            // the offset. The user-visible expectation for smart-skip
            // is "start reading here, at the beginning of the
            // paragraph that includes this offset." Return the
            // current unit when the offset falls inside its range
            // rather than jumping past it.
            if cumulative > offset {
                return unit
            }
        }
        return units.last
    }
}

// ========== BLOCK 01: CONTENT UNIT BUILDER - END ==========
