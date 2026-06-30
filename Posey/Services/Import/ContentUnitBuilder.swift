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
            // population in TXTLibraryImporter. Other heading styles
            // (Epilogue, Prologue, Preface, Foreword) included since
            // they're common Gutenberg structure.
            // (Was kept aligned with FirstChapterAdvance's CHAPTER
            // patterns; that detector was removed 2026-06-11 when the
            // keep-all-prefaces [DECISION] made open-position stop at
            // first prose instead of advancing to Chapter I.)
            let nsLen = (trimmed as NSString).length
            let fullRange = NSRange(location: 0, length: nsLen)
            var isHeading = Self.txtHeadingRegex.firstMatch(
                in: trimmed, options: [], range: fullRange
            ) != nil
            // 2026-06-02 — Gap (B): keyword-LESS chapter headings of the
            // form "I. Introduction", "XII. In the Darkness" (a Roman
            // numeral + period + title, NO "CHAPTER" word). The Time
            // Machine (Gutenberg #35) numbers its chapters this way and
            // the CHAPTER-anchored regex missed every one of them (only
            // "Epilogue" matched → 1 TOC entry for a 16-chapter book).
            // Guarded HARD against prose false-positives: it must be a
            // SHORT standalone paragraph (≤ 80 chars — a real chapter
            // title line, not a sentence that happens to open "I. e. …"),
            // and the Roman numeral must be followed by a period. The
            // fused front-matter Contents block ("I Introduction II The
            // Machine …") has no period after the first numeral and is
            // long, so it is NOT matched here. Verified: Time Machine
            // 1→17 entries; Moby still 136, Tale still 45 (no regression).
            if !isHeading, trimmed.count <= 80,
               Self.romanHeadingRegex.firstMatch(
                in: trimmed, options: [], range: fullRange
               ) != nil,
               let last = trimmed.last, !".;!?".contains(last) {
                // A chapter title is a noun phrase, not a sentence: it
                // does NOT end in sentence punctuation. This rejects
                // Moby's enumerated PROSE ("I. A Fast-Fish belongs to the
                // party fast to it.", "I. THE FOLIO WHALE; II. the OCTAVO
                // WHALE; III. the DUODECIMO WHALE.") — which matched the
                // bare-Roman shape and were wrongly promoted (136→139) —
                // while keeping real titles "I. Introduction" / "XII. In
                // the Darkness" (The Time Machine).
                isHeading = true
            }
            // Fused-listing guard. A front-matter Contents listing whose
            // entries got de-wrapped into ONE paragraph (TXT loader joins
            // single newlines with spaces) matches the CHAPTER pattern but
            // is NOT a real heading — it carries MANY chapter markers.
            // Dracula's 27-line Contents fused into a single 990-char unit
            // and was wrongly promoted, surfacing as a junk TOC entry.
            // Demote any candidate carrying ≥2 "CHAPTER <numeral>" markers.
            // A genuine heading ("CHAPTER 1. The Chapter of Doom") has
            // exactly one CHAPTER-followed-by-a-numeral marker.
            if isHeading,
               Self.chapterMarkerRegex.numberOfMatches(
                in: trimmed, options: [], range: fullRange
               ) >= 2 {
                isHeading = false
            }
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
        // 2026-06-02 — Gap (A): the trailing separator+title is now
        // OPTIONAL (`(?:[.\s:—–-].*)?`). Previously the pattern REQUIRED
        // a separator after the numeral (`[.\s:—-].*`), so a bare chapter
        // marker with no title — "CHAPTER I", "CHAPTER 12" on its own
        // line — failed to match. Dracula (Gutenberg #345) titles its
        // body chapters exactly that way ("CHAPTER I", "CHAPTER II", …),
        // so NONE of its 27 chapters were promoted (the only heading was
        // the fused front-matter Contents block). Making the tail
        // optional promotes bare markers while the `^…$` whole-paragraph
        // anchor still rejects mid-sentence "CHAPTER I was…" prose (that
        // case already matched before and is unchanged). Roman class
        // widened I/V/X/L → +C/D/M and {1,5}→{1,7}; spelled-out extended
        // to TWELVE; lowercase "Chapter" spelled-out added.
        let roman = "[IVXLCDM]{1,7}"
        let spelled = "(?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN|ELEVEN|TWELVE)"
        let tail = #"(?:[.\s:—–-].*)?"#   // optional separator + rest
        let pattern = "^\\s*(?:"
            + "(?:CHAPTER|Chapter)\\s+\\d{1,3}\(tail)"
            + "|(?:CHAPTER|Chapter)\\s+\(roman)\(tail)"
            + "|(?:CHAPTER|Chapter)\\s+\(spelled)\(tail)"
            + #"|Epilogue\.?|Prologue\.?|Preface\.?|Foreword\.?|Introduction\.?"#
            + ")\\s*$"
        // Returning a force-tried regex; the pattern is a compile-time
        // constant so the try cannot fail at runtime.
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// 2026-06-02 — Gap (B): keyword-LESS Roman-numeral chapter headings,
    /// e.g. "I. Introduction", "XII. In the Darkness" (The Time Machine).
    /// REQUIRES a period after the numeral and a non-empty title; callers
    /// MUST additionally gate on a short paragraph length (see proseUnits)
    /// so prose that merely opens with a Roman numeral isn't promoted.
    fileprivate static let romanHeadingRegex: NSRegularExpression = {
        let pattern = #"^[IVXLCDM]{1,7}\.\s+\S.*$"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// 2026-06-02 — Counts "CHAPTER <numeral>" markers in a paragraph.
    /// ≥2 means a fused front-matter Contents listing, not a heading.
    /// Requires a numeral after CHAPTER so a title that merely contains
    /// the word "chapter" ("The Chapter of Doom") isn't miscounted.
    fileprivate static let chapterMarkerRegex: NSRegularExpression = {
        let pattern = #"(?i)CHAPTER\s+(?:\d|[IVXLCDM])"#
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

    /// PDF rebuild Piece A (2026-06-29) — build content units from the CLEAN
    /// line stream (`PDFLineExtractor`, PDFKit-native), not the form-feed string.
    /// Per page: a `pageBreak` unit (sheet index, for the page map — never an
    /// anchor), then `.heading` units for lines the caller's `isHeading` marks,
    /// and `.prose` units for paragraphs grouped from consecutive body lines
    /// (split on a notably-larger-than-leading vertical gap). The caller supplies
    /// `isHeading` / `headingLevel` from the derived `HeadingProfile` so this
    /// builder stays decoupled from per-book heading inference.
    ///
    /// NOTE (follow-up): cross-page paragraph STITCHING (a paragraph spanning a
    /// page break = one unit) is a read-along-smoothness refinement tracked
    /// separately; this first version flushes at page end. Chapter navigation
    /// (the heading units) does not depend on it.
    static func unitsFromPDFLines(
        _ linesByPage: [[PDFTextLine]],
        documentID: UUID,
        isHeading: (PDFTextLine) -> Bool,
        headingLevel: (PDFTextLine) -> Int = { _ in 1 }
    ) -> [ContentUnit] {
        var units: [ContentUnit] = []
        var sequence = 10
        func add(_ kind: ContentUnitKind, _ text: String, _ meta: ContentUnitMetadata = .empty) {
            units.append(ContentUnit(documentID: documentID, sequence: sequence, kind: kind,
                                     text: text, metadata: meta))
            sequence += 10
        }

        for page in linesByPage {
            guard let pageIndex = page.first?.pageIndex else { continue }
            add(.pageBreak, "", ContentUnitMetadata(pageNumber: pageIndex))

            // A paragraph break is a vertical gap notably larger than the page's
            // typical line leading. Use the median positive gap as the baseline.
            let gaps = page.map { $0.gapAbove }.filter { $0 > 0 }.sorted()
            let typicalGap = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
            let paraThreshold = typicalGap > 0 ? typicalGap * 1.6 : .greatestFiniteMagnitude

            var buffer: [String] = []
            func flushParagraph() {
                let text = buffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { add(.prose, text) }
                buffer.removeAll(keepingCapacity: true)
            }

            for line in page {
                if isHeading(line) {
                    flushParagraph()
                    add(.heading, line.text, ContentUnitMetadata(headingLevel: headingLevel(line)))
                } else {
                    if !buffer.isEmpty, line.gapAbove >= paraThreshold { flushParagraph() }
                    buffer.append(line.text)
                }
            }
            flushParagraph()
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
        case .code:
            // 2026-06-11 — fenced code block; text preserves newlines/indentation
            // verbatim (fence + lang label already stripped by the parser).
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .code,
                text: block.text
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

    /// - Parameter skipUnitID: units BEFORE this skip unit (by document sequence)
    ///   are never promoted to headings. Used by the PDF path to pass the
    ///   TOC-skip unit so a TOC-LISTING entry (which lives in the front-matter
    ///   contents region, before the body) is never turned into a chapter
    ///   heading. A TOC-entry marker's intended target is the BODY occurrence of
    ///   the title (that's where `buildEntries` resolved its offset); without
    ///   this guard, once the contents listing is split into one unit per entry
    ///   (so each "Chapter I: The MU-puzzle 33" listing line is its own unit),
    ///   the listing unit is an EXACT title match and gets promoted alongside —
    ///   or instead of — the real body heading, producing duplicate / wrong
    ///   headings in the skipped front matter (GEB). `nil` = no restriction, so
    ///   TXT/RTF/DOCX/HTML/EPUB callers (whose front-matter headings like Moby's
    ///   EXTRACTS / ETYMOLOGY are legitimate and come from other marker sources)
    ///   are unaffected.
    ///
    ///   Ruler migration #3b (2026-06-28): the boundary is the skip UNIT's
    ///   SEQUENCE (identity), not a cross-ruler character offset. Was
    ///   `minPromotableOffset: Int` — an R1 plainText offset compared against each
    ///   unit's R2 unit-joined start offset (the same two-ruler drift #2/#3
    ///   removed). The general front-matter-listing suppression across all formats
    ///   remains the dedicated Bug G task.
    static func applyHeadingMarkers(
        to units: [ContentUnit],
        headingMarkersByOffset: [Int: HeadingMarker],
        skipUnitID: UUID? = nil
    ) -> [ContentUnit] {
        guard !headingMarkersByOffset.isEmpty else { return units }
        // Resolve the promotion boundary to the skip unit's sequence ONCE; every
        // per-unit test below is then sequence-vs-sequence (one ruler). nil → no
        // restriction (non-PDF callers, unchanged).
        let skipSequence: Int? = skipUnitID.flatMap { id in
            units.first(where: { $0.id == id })?.sequence
        }

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
                for i in units.indices where units[i].kind == .prose
                    && startOffsets[i] >= 0
                    && (skipSequence.map { units[i].sequence >= $0 } ?? true) {
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
                        && (skipSequence.map { units[i].sequence >= $0 } ?? true)
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
        // 2026-06-11 heading standard — merge label-only heading + title line
        // into one heading (covers the block formats: EPUB/DOCX/HTML/PDF, which
        // finalize headings here). No-op when headings already carry a title.
        return mergeLabelTitleHeadings(out)
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

    /// Separator-tolerant title match. Returns nil if `title` does not head
    /// `unitText` (after leading whitespace). Any run of SEPARATOR characters in
    /// EITHER string matches any run in the other — where a separator is
    /// whitespace OR a `:` (colon). The whitespace tolerance lets a TOC title
    /// "I. A Scandal in Bohemia" match a unit "I.\nA Scandal in Bohemia" whose
    /// heading was split across lines in the EPUB source. The colon tolerance
    /// (added 2026-06-01) lets a PDF OUTLINE title "1: Google, Meet OKRs" match a
    /// body unit "1 Google, Meet OKRs If you…" that sets the chapter number with a
    /// space, not a colon — 27 of 38 Measure-What-Matters outline entries were
    /// dropped purely on this colon-vs-space difference, leaving their chapter
    /// titles as unstyled body. Treating `:` as separator-equivalent is strictly
    /// ADDITIVE (a separator run still matches a separator run; it only ALSO lets
    /// `:` match whitespace and vice-versa), and `applyHeadingMarkers` ranks exact
    /// title==unit matches ahead of prefix matches, so no existing heading
    /// regresses. On a match returns:
    ///   • `titleLength`: character count from `unitText`'s start through the end
    ///     of the matched title PLUS one trailing separator char — the renderer
    ///     styles `[0, titleLength)` as the heading and the remainder as body.
    ///     nil when the unit IS the title (no body after), i.e. style it whole.
    ///   • `isExact`: true when the unit holds nothing but the title.
    /// Case-sensitive on non-separator characters (importers preserve case).
    private static func titleMatch(in unitText: String, title: String) -> (titleLength: Int?, isExact: Bool)? {
        func isSep(_ c: Character) -> Bool { c.isWhitespace || c == ":" }
        let u = Array(unitText)
        let t = Array(title)
        var ui = 0, ti = 0
        while ui < u.count, u[ui].isWhitespace { ui += 1 }
        while ti < t.count {
            if isSep(t[ti]) {
                guard ui < u.count, isSep(u[ui]) else { return nil }
                while ui < u.count, isSep(u[ui]) { ui += 1 }
                while ti < t.count, isSep(t[ti]) { ti += 1 }
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

    /// Demote front-matter CONTENTS-listing heading units back to `.prose` —
    /// identified by DUPLICATION, not by region.
    ///
    /// 2026-05-31 (Bug G) — Gutenberg TXT/HTML surface "CHAPTER 1. Loomings."
    /// both in the front-matter CONTENTS listing AND at the real chapter start
    /// in the body. `proseUnits` / `applyHeadingMarkers` promote BOTH, so Moby
    /// TXT had 272 heading units (136 listing + 136 body) and Moby HTML 282 —
    /// the listing copies render as chapter headings inside the skipped front
    /// matter and duplicate the real ones.
    ///
    /// **Why duplication, not a region.** A first attempt scoped demotion to the
    /// detected Contents region `[postCatalog, postTOC]`. That boundary is
    /// fragile: on Moby HTML it swallowed the legitimate **ETYMOLOGY** heading
    /// (which sits inside the region) while sparing EXTRACTS (just past it) —
    /// the exact EXTRACTS/ETYMOLOGY regression Mark flagged. The robust signal
    /// is that a listing entry's title RECURS in a strictly LATER heading (the
    /// body copy always follows the listing copy). So: a heading before the skip
    /// offset is demoted iff the same (normalized) title appears again in a
    /// later heading. The body copy — whose title only appears EARLIER, in the
    /// listing — is never demoted by this asymmetry, which is why no fragile
    /// body-vs-skip boundary is needed (the skip lands just past the first
    /// chapter heading, so a boundary test missed exactly CHAPTER 1). Front-
    /// matter headings with no later twin — ETYMOLOGY, EXTRACTS — are preserved.
    /// Genuinely repeated front matter (e.g. Frankenstein's two identical "To
    /// Mrs. Saville, England." letters) is preserved by the front-matter guard
    /// (`sequence < skipSequence`): those letters are reading CONTENT and sit
    /// at/after the skip unit, so they are never demotion candidates.
    ///
    /// Position by IDENTITY (the Position Rule, ruler migration #3, 2026-06-28):
    /// the front-matter boundary is the skip UNIT's `sequence`, not a cross-ruler
    /// character offset. `skipUnitID` is resolved to a sequence once, then every
    /// test is sequence-vs-sequence — pure document order, one ruler. (Was
    /// `skipOffset`: an importer-plainText offset (R1) compared against a
    /// unit-joined running offset (R2) — the same two-ruler drift #2 removed.)
    static func demoteDuplicateListingHeadings(
        _ units: [ContentUnit],
        skipUnitID: UUID?
    ) -> [ContentUnit] {
        guard let skipUnitID,
              let skipSequence = units.first(where: { $0.id == skipUnitID })?.sequence
        else { return units }

        func normalizedTitle(_ unit: ContentUnit) -> String {
            let prefix = unit.metadata.titleLength.map { String(unit.text.prefix($0)) } ?? unit.text
            return prefix
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .lowercased()
        }

        // The signal is a LATER twin, not the skip boundary. The skip lands a
        // little PAST the first chapter heading (into its body), so the body
        // CHAPTER 1 heading is itself before the skip — a body-vs-skip partition
        // wrongly excluded it and left its listing copy un-demoted (observed:
        // Moby kept its CHAPTER 1 listing). Instead: a listing copy always
        // precedes its body copy, so demote a front-matter heading whose title
        // appears AGAIN in a strictly later heading. The body copy (whose title
        // only appears EARLIER, in the listing) is never demoted by this
        // asymmetry — no fragile boundary needed.

        // Pass 1 — the last (greatest) sequence at which each heading title
        // occurs. Units are in document order with monotonically increasing
        // sequence, so the final write per title is its latest occurrence.
        var lastHeadingSeqByTitle: [String: Int] = [:]
        for unit in units where unit.kind == .heading {
            let t = normalizedTitle(unit)
            if !t.isEmpty { lastHeadingSeqByTitle[t] = unit.sequence }
        }

        // Pass 2 — a front-matter heading (sequence < skipSequence) whose title
        // recurs in a strictly LATER heading is a listing copy → candidate. The
        // body copy (its title appears only EARLIER, in the listing) is never a
        // candidate by this asymmetry. Sequence-vs-sequence only (one ruler).
        var candidateUnitIDs = Set<UUID>()
        for unit in units where unit.kind == .heading && unit.sequence < skipSequence {
            let t = normalizedTitle(unit)
            if !t.isEmpty, (lastHeadingSeqByTitle[t] ?? unit.sequence) > unit.sequence {
                candidateUnitIDs.insert(unit.id)
            }
        }

        // Only act when there's clearly a LISTING — a cluster of duplicated
        // front-matter headings — not a one-off repeat. A real contents listing
        // has many entries; an isolated duplicate (a genuinely repeated section
        // title in the front matter) must not be touched. minListingSize = 3.
        guard candidateUnitIDs.count >= 3 else { return units }

        return units.map { unit in
            guard candidateUnitIDs.contains(unit.id) else { return unit }
            return ContentUnit(
                id: unit.id,
                documentID: unit.documentID,
                sequence: unit.sequence,
                kind: .prose,
                text: unit.text,
                metadata: .empty
            )
        }
    }

    /// Re-anchor every TOC entry's offset to the TRUE position of the heading
    /// unit it names, in the reader's coordinate.
    ///
    /// 2026-06-01 (phone audit, heading work) — TOC nav precision varied by
    /// format because each importer stores its TOC `plainTextOffset` in ITS OWN
    /// detector coordinate, which can drift from the units-joined coordinate the
    /// reader actually navigates in:
    ///   • DOCX computes heading offsets in the EXTRACTOR'S displayText (which can
    ///     differ paragraph-for-paragraph from the plainText the units are built
    ///     from) — observed: "What We Built" stored at 546 but its heading unit
    ///     sits at 956, so a tap landed a whole section early, on the prior body.
    ///   • PDF stores the OUTLINE destination offset (PDFKit coordinate), ~200
    ///     chars coarse vs the heading unit, leaving a sliver of the prior section
    ///     above the heading on a tap.
    /// TXT/HTML/EPUB/RTF already build TOC offsets by walking the units, so they
    /// land exactly — for them this pass is a NO-OP (it recomputes the same
    /// value). Anchoring at the shared persist choke point makes nav exact for
    /// EVERY format and removes the per-importer-coordinate fragility entirely;
    /// it is the back-of-the-fence correctness behind the visible "tap lands on
    /// the styled heading."
    ///
    /// Coordinate: identical to `ReaderView.makeLoadedContent`'s
    /// `cumulativeOffsetByUnitID` — a unit's start is recorded BEFORE its own
    /// text is added; the "\n\n" separator (`+2`) is charged between prose-bearing
    /// units. So the anchor equals the heading's first-sentence segment
    /// `startOffset` exactly, and `jumpToTOCEntry`'s `firstIndex(startOffset >=)`
    /// resolves to the heading itself.
    ///
    /// Matching: a TOC entry binds to the `.heading` unit whose text HEADS WITH
    /// the entry title (the same `titleMatch` used for promotion, so a fused PDF
    /// heading "1 Google, Meet OKRs If you…" still binds to its outline entry
    /// "1: Google, Meet OKRs"), choosing — among all title matches — an EXACT
    /// title==heading match first, then the one NEAREST the entry's original
    /// offset. Nearest-offset disambiguation (not a forward cursor) is required
    /// because TOC entries are not always in body order: a PDF "DEDICATION" entry
    /// can point to a dedication page near the END of the book, which a forward
    /// cursor would let consume the slot and then skip every chapter after it. It
    /// also resolves repeated titles (a section label reused per chapter) to the
    /// occurrence nearest its own listed position. An entry with no matching
    /// heading keeps its original offset (front matter like "PRAISE FOR…" that has
    /// no body heading), so this can only improve nav, never regress it.
    static func reanchorTOCToHeadingUnits(
        _ toc: [StoredTOCEntry],
        units: [ContentUnit]
    ) -> [StoredTOCEntry] {
        guard !toc.isEmpty else { return toc }

        struct Anchor { let offset: Int; let text: String; let unitID: UUID }
        var anchors: [Anchor] = []
        var cumulative = 0
        for unit in units {
            if unit.kind == .heading {
                anchors.append(Anchor(offset: cumulative, text: unit.text, unitID: unit.id))
            }
            if unit.kind.carriesProseText {
                cumulative += unit.text.count + 2 // "\n\n" — matches ReaderView + persister
            }
        }
        guard !anchors.isEmpty else { return toc }

        return toc.map { entry in
            guard !entry.title.isEmpty else { return entry }
            var best: Int? = nil
            var bestExact = false
            var bestDist = Int.max
            for (i, anchor) in anchors.enumerated() {
                guard let m = Self.titleMatch(in: anchor.text, title: entry.title) else { continue }
                let exact = m.isExact
                let dist = abs(anchor.offset - entry.plainTextOffset)
                if best == nil
                    || (exact && !bestExact)
                    || (exact == bestExact && dist < bestDist) {
                    best = i; bestExact = exact; bestDist = dist
                }
            }
            guard let b = best else { return entry } // no body heading — keep original
            // 2026-06-11 (auditor ruling) — the TOC entry MUST show the same text
            // as the body heading it points to. After the label+title merge a
            // body heading reads "CHAPTER I: JONATHAN HARKER'S JOURNAL" but a nav/
            // listing-sourced TOC entry may still read bare "CHAPTER I" — a reader
            // must not see one in the contents and the other in the body. Adopt
            // the matched heading unit's (merged) text as the TOC title. Applies
            // to every format that routes through persistParsedDocument.
            return StoredTOCEntry(
                title: anchors[b].text.trimmingCharacters(in: .whitespacesAndNewlines),
                plainTextOffset: anchors[b].offset,
                unitID: anchors[b].unitID,           // the body heading this entry points to
                playOrder: entry.playOrder,
                level: entry.level
            )
        }
    }

    // ── Heading standard (2026-06-11, auditor/Mark): a chapter heading is ONE
    // line. A label-only heading line ("CHAPTER I", "II.") MERGES with the
    // title line immediately below it → "CHAPTER I: Jonathan Harker's Journal",
    // "II. The Red-Headed League". A trailing parenthetical ("(Kept in
    // shorthand.)") stays body. Offset-safe: plainText/displayText derive from
    // the unit list (see persistParsedDocument), so a consistent merge keeps
    // offsets / search / anchors / sentences aligned — no length games needed.
    // NO-OP for headings that already carry a title (DOCX/RTF/MD
    // "CHAPTER XXVII. Mina Harker's Journal") and single-phrase section
    // headings (Wikipedia "Plot summary"): those fail isLabelOnlyHeading.
    // Both heading paths use it: TXT (proseUnits) and the block formats
    // (EPUB/DOCX/HTML after applyHeadingMarkers).
    static func mergeLabelTitleHeadings(_ units: [ContentUnit]) -> [ContentUnit] {
        guard units.count > 1 else { return units }
        var out: [ContentUnit] = []
        var i = 0
        while i < units.count {
            let u = units[i]
            if u.kind == .heading, i + 1 < units.count, isLabelOnlyHeading(u.text),
               isMergeableTitleLine(units[i + 1]) {
                out.append(ContentUnit(
                    documentID: u.documentID,
                    sequence: u.sequence,
                    kind: .heading,
                    text: joinLabelAndTitle(label: u.text, title: units[i + 1].text),
                    metadata: u.metadata   // keep the label heading's level
                ))
                i += 2
                continue
            }
            out.append(u)
            i += 1
        }
        return out
    }

    /// A pure chapter label with NO title: "CHAPTER I", "Chapter 1", "II.",
    /// "12", "I.". Rejects anything carrying title words.
    private static let labelOnlyHeadingRegex: NSRegularExpression = {
        let pattern = #"^(?:(?:CHAPTER|Chapter)\s+)?(?:\d{1,3}|[IVXLCDM]{1,7})\.?$"#
        return try! NSRegularExpression(pattern: pattern)
    }()
    static func isLabelOnlyHeading(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 20 else { return false }
        return labelOnlyHeadingRegex.firstMatch(
            in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }
    /// The line below a label that should become its title: a following heading
    /// unit (EPUB/Sherlock split), or a SHORT title-like prose line (TXT
    /// "JONATHAN HARKER'S JOURNAL"). Never a parenthetical, another bare label,
    /// or a multi-sentence body paragraph.
    static func isMergeableTitleLine(_ unit: ContentUnit) -> Bool {
        let t = unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 80, !t.hasPrefix("("),
              !isLabelOnlyHeading(t) else { return false }
        switch unit.kind {
        case .heading: return true
        case .prose:   return !t.contains(". ")   // one phrase, not a body sentence
        default:       return false
        }
    }
    static func joinLabelAndTitle(label: String, title: String) -> String {
        let l  = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let ti = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = l.last, ".:—–-".contains(last) { return "\(l) \(ti)" }
        return "\(l): \(ti)"
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
        // A skip / content-end target must be READABLE content, never a
        // structural unit (pageBreak / horizontalRule / empty image marker).
        // 2026-06-01 (foundation audit, AUDIT-3): the Crypto/IRS PDFs opened on
        // a blank page — `firstUnit` returned the `pageBreak` unit that sits at
        // the skip offset, so the reader showed white space instead of the
        // Introduction that is the very next unit. Always advance to the first
        // prose-bearing unit at/after the chosen position.
        func firstContent(from index: Int) -> ContentUnit? {
            var i = max(0, index)
            while i < units.count {
                if units[i].kind.carriesProseText { return units[i] }
                i += 1
            }
            return units.indices.contains(index) ? units[index]
                 : units.last(where: { $0.kind.carriesProseText }) ?? units.last
        }
        guard offset > 0 else { return firstContent(from: 0) }
        var cumulative = 0
        for (i, unit) in units.enumerated() {
            if cumulative >= offset { return firstContent(from: i) }
            guard unit.kind.carriesProseText else { continue }
            let textEnd = cumulative + unit.text.count
            // 2026-05-28 — Mark caught (Pride EPUB): when the offset falls INSIDE
            // a unit's TEXT, return THAT unit (start reading at the paragraph
            // that contains the offset), not the next one.
            if offset < textEnd { return unit }
            // 2026-06-01 (AUDIT/TXT-1): advance past the text AND its "\n\n"
            // separator. An offset that lands in the SEPARATOR [textEnd,
            // textEnd+2) — e.g. Moby TXT's smart-skip at 26038, one char short
            // of "CHAPTER 1"'s unit-start 26039 due to a single-vs-double
            // newline drift between the importer's plainText and the unit join —
            // belongs to the NEXT unit, not this one. The previous code returned
            // THIS unit for separator offsets, so Moby opened/played on the last
            // EXTRACT instead of "Call me Ishmael." Letting the loop continue
            // maps the separator to the next unit via the `cumulative >= offset`
            // check on the following iteration.
            cumulative = textEnd + 2
        }
        return units.last(where: { $0.kind.carriesProseText }) ?? units.last
    }
}

// ========== BLOCK 01: CONTENT UNIT BUILDER - END ==========
