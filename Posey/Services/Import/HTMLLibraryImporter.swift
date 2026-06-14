import Foundation

// ========== BLOCK 01: HTML LIBRARY IMPORTER (UNITS) - START ==========

/// Imports HTML files into the unit-based content model.
///
/// **What changed in the rebuild:** the importer now runs
/// `HTMLDisplayParser` at import time and converts its `DisplayBlock`
/// output into `ContentUnit`s via the shared `ContentUnitBuilder`.
/// Images are persisted to the side-store unchanged. The existing
/// Gutenberg / in-prose-TOC / Gutenberg-catalog skip detection runs
/// against plainText and the resulting offset is mapped to a unit
/// via `ContentUnitBuilder.firstUnit(...)`.
///
/// `SentenceIndexer` pre-segments per unit at import time.
///
/// 2026-05-23 — rewritten as part of the architecture rebuild.
struct HTMLLibraryImporter {
    let databaseManager: DatabaseManager
    private let importer = HTMLDocumentImporter()
    private let displayParser = HTMLDisplayParser()

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    @MainActor
    func importDocument(from url: URL) async throws -> Document {
        try FormatPrecheck.checkTextLike(url: url, declaredType: "html")
        let parsed = try await importer.loadDocument(from: url)
        let rawHTML = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            ?? ""
        let contentHash = try? ContentHasher.sha256(of: url)
        let derived = TitleExtractor.fromHTML(rawHTML: rawHTML)
        let title = TitleExtractor.resolve(
            contentTitle: derived,
            filename: url.lastPathComponent
        )
        return try importNormalizedDocument(
            title: title,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            images: parsed.images,
            headings: parsed.headings,
            contentHash: contentHash
        )
    }

    @MainActor
    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "html") async throws -> Document {
        let parsed = try await importer.loadTextAsync(fromData: rawData)
        let rawHTML = String(data: rawData, encoding: .utf8)
            ?? String(data: rawData, encoding: .isoLatin1)
            ?? ""
        let contentHash = ContentHasher.sha256(rawData)
        let derived = TitleExtractor.fromHTML(rawHTML: rawHTML)
        let resolved = title.isEmpty
            ? TitleExtractor.resolve(contentTitle: derived, filename: fileName)
            : title
        return try importNormalizedDocument(
            title: resolved,
            fileName: fileName,
            fileType: fileType,
            displayText: parsed.text,
            plainText: parsed.text,
            images: [],
            headings: parsed.headings,
            contentHash: contentHash
        )
    }

    private func importNormalizedDocument(
        title: String,
        fileName: String,
        fileType: String,
        displayText: String,
        plainText: String,
        images: [PageImageRecord],
        headings: [HTMLDocumentImporter.HTMLHeadingEntry],
        contentHash: String?
    ) throws -> Document {
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText,
            contentHash: contentHash
        )
        let documentID = existingDocument?.id ?? UUID()

        // ── Run the display parser at import time.
        let blocks = displayParser.parse(displayText: displayText)

        // ── Convert blocks to units. HTMLDisplayParser only emits
        // ── blocks when the doc has inline images; plain HTML
        // ── (Readability-stripped articles, etc.) falls back to
        // ── plainText paragraph splitting.
        let baseUnits = ContentUnitBuilder.unitsPreferringBlocks(
            blocks: blocks,
            plainText: plainText,
            documentID: documentID
        )
        // ── Step 9 prerequisite — promote heading paragraphs into
        // ── `.heading` units. Reuse the TOC resolution that already
        // ── searches plainText for each heading's title.
        let resolvedHeadings = resolveHeadingOffsets(headings, in: plainText)
        // 2026-05-31 (ingestion audit): keep-first on duplicate offsets —
        // `Dictionary(uniqueKeysWithValues:)` fatal-errors on a key collision
        // (two headings resolving to the same offset). See PDFLibraryImporter.
        let headingMarkersByOffset: [Int: ContentUnitBuilder.HeadingMarker] = Dictionary(
            resolvedHeadings.map {
                ($0.plainTextOffset, ContentUnitBuilder.HeadingMarker(level: $0.level, title: $0.title))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let promotedUnits = ContentUnitBuilder.applyHeadingMarkers(
            to: baseUnits,
            headingMarkersByOffset: headingMarkersByOffset
        )

        // ── Smart-skip: same layered detection.
        let boundaryResult = GutenbergBoundaryDetector.detect(in: plainText)
        let gutenbergStart = boundaryResult.contentStartOffset ?? 0
        let postCatalog = GutenbergCatalogDetector.endOfCatalogRegion(
            in: plainText, after: gutenbergStart
        ) ?? gutenbergStart
        let postTOC = InProseTOCDetector.endOfTOCRegion(
            in: plainText, after: postCatalog
        ) ?? postCatalog
        let postFrontMatter = max(postCatalog, postTOC)
        // 2026-06-11 [DECISION] (Mark — format-parity with the EPUB ruling
        // a6d892e, SUPERSEDES the 2026-05-27 FirstChapterAdvance step): ALL
        // prefaces (author AND editorial) are BOOK CONTENT — a gutenberg book
        // opens at the FIRST REAL PROSE after the PG boilerplate + the in-book
        // Contents listing, NEVER skipping a preface to Chapter I. Moby HTML now
        // opens at "ETYMOLOGY." (kept), not "Call me Ishmael." The old
        // FirstChapterAdvance "skip in-work front-matter -> Chapter 1" step is
        // REMOVED; in its place, if the skip still sits on a Contents listing,
        // advance past the listing to the first prose. NO-OP for non-gutenberg
        // article HTML (Wikipedia): no "Contents" header ahead → stays at the top
        // (same outcome FirstChapterAdvance gave for non-CHAPTER-structured HTML).
        let afterContents = InProseTOCDetector.firstProseAfterContentsListing(
            in: plainText, at: postFrontMatter,
            tocTitles: resolvedHeadings.map { $0.title }) ?? postFrontMatter
        // 2026-06-11 (auditor c6) — advance past leading title-page/publisher/
        // illustration-list apparatus to first real content (no-op for article
        // HTML + non-apparatus landings).
        let skipOffset = InProseTOCDetector.contentStartAfterPublishingApparatus(
            in: plainText, at: afterContents) ?? afterContents
        // 2026-05-31 (Bug G) — demote the front-matter CONTENTS-listing chapter
        // headings (Moby HTML promoted both the listing entries AND the body
        // chapters → 282 heading units for 147 real chapters). Identified by a
        // BODY twin (same title at/after skip), so the legitimate front-matter
        // headings ETYMOLOGY and EXTRACTS — which have no body copy — are
        // preserved (the earlier region-based attempt wrongly demoted ETYMOLOGY).
        let units = ContentUnitBuilder.demoteDuplicateListingHeadings(
            promotedUnits, skipOffset: skipOffset
        )
        // 2026-06-12 (finding #2) — pull contentEnd back past a trailing publisher
        // catalog ad (Grosset & Dunlap reprints). No-op for article HTML / books
        // with no trailing ad. END-mirror of the c6 publishing-apparatus skip.
        // 2026-06-14 (#2b parity) — compute the END boundary in the UNIT-JOINED
        // plainText (the cumulative/DB space firstUnit/persister/reader use), not
        // the parsed `plainText`. The two diverge for NSAttributedString-derived
        // HTML (same root cause as EPUB dracula's 91-char gap), so a parsed-space
        // cut resolved one unit too late and could leave the publisher-ad line in
        // the read-aloud flow. No-op when the strings agree or there's no catalog.
        let unitJoinedPlainText = units.filter { $0.kind.carriesProseText }
            .map { $0.text }.joined(separator: "\n\n")
        let rawContentEnd = GutenbergBoundaryDetector.detect(in: unitJoinedPlainText).contentEndOffset ?? 0
        let contentEndOffset = InProseTOCDetector.contentEndBeforePublisherCatalog(
            in: unitJoinedPlainText, at: rawContentEnd) ?? rawContentEnd
        let skipSource: String = {
            if gutenbergStart > 0 { return "gutenberg" }
            if skipOffset > 0   { return "heuristic" }
            return ""
        }()
        let skipUnitID = ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: skipOffset)?.id
        let contentEndUnitID: UUID? = {
            guard contentEndOffset > 0 else { return nil }
            return ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: contentEndOffset)?.id
        }()

        // ── Sentences.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── TOC entries (already resolved above for heading promotion).
        // 2026-06-13 — Drop nav apparatus harvested as HTML headings (family #3,
        // HTML half): the Project Gutenberg boilerplate header ("The Project
        // Gutenberg eBook of …"), the PG license heading, and a bare "Contents"
        // self-reference all surface as <hN> and leaked into the Contents sheet
        // (moby-dick.html, tale-of-two-cities, Wikipedia-P&P c5). Filtered ONLY
        // from the nav TOC — the upstream resolvedHeadings still drive skip /
        // promotion / demote logic unchanged, so this is a c5-only cleanup.
        let tocEntries = resolvedHeadings.filter { !Self.isHTMLNavApparatus($0.title) }

        let parsedDoc = ParsedDocument(
            id: documentID,
            title: title,
            fileName: fileName,
            fileType: fileType,
            units: units,
            sentences: sentences,
            toc: tocEntries,
            skipUnitID: skipUnitID,
            skipSource: skipSource,
            playbackSkipUntilOffset: skipOffset,
            contentEndOffset: contentEndOffset,
            contentEndUnitID: contentEndUnitID,
            contentHash: contentHash,
            editionLabel: nil
        )
        try databaseManager.persistParsedDocument(parsedDoc)

        // Persist inline images.
        try databaseManager.deleteImages(for: documentID)
        for image in images {
            try databaseManager.insertImage(id: image.imageID, documentID: documentID, data: image.data)
        }

        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: documentID))
        }

        let now = Date()
        let document = Document(
            id: documentID,
            title: title,
            fileName: fileName,
            fileType: fileType,
            importedAt: existingDocument?.importedAt ?? now,
            modifiedAt: now,
            displayText: displayText,
            plainText: plainText,
            characterCount: plainText.count,
            playbackSkipUntilOffset: skipOffset,
            contentEndOffset: contentEndOffset,
            skipSource: skipSource,
            contentHash: contentHash,
            editionLabel: nil
        )
        let docID = document.id
        let dbRef = databaseManager
        Task.detached {
            await UnitEmbeddingService.shared.enqueueIndexing(
                documentID: docID, databaseManager: dbRef
            )
        }
        return document
    }

    /// Find each heading's title in plainText sequentially. Unchanged
    /// from the legacy importer — heading titles are content strings
    /// True when an HTML heading title is nav apparatus no reader navigates to —
    /// Project Gutenberg boilerplate (the "eBook of …" header + the license
    /// heading) or a bare "Contents"/"Table of Contents" self-reference.
    /// Conservative + line-exact on the self-reference so real sections
    /// ("Table of Contents Generators", a chapter merely containing the word)
    /// are untouched. Verified zero-false-drop across the HTML corpus.
    static func isHTMLNavApparatus(_ title: String) -> Bool {
        let s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        if s.range(of: #"(?i)project\s+gutenberg.{0,25}licen[sc]e"#, options: .regularExpression) != nil {
            return true
        }
        if s.range(of: #"(?i)^the\s+project\s+gutenberg\s+e-?book\b"#, options: .regularExpression) != nil {
            return true
        }
        if s.range(of: #"(?i)^(table\s+of\s+)?contents$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// rather than offsets so we have to search.
    private func resolveHeadingOffsets(
        _ headings: [HTMLDocumentImporter.HTMLHeadingEntry],
        in plainText: String
    ) -> [StoredTOCEntry] {
        var out: [StoredTOCEntry] = []
        var cursor = plainText.startIndex
        var order = 0
        for h in headings {
            let needle = h.title
            // 2026-06-13 — Whitespace-FLEXIBLE search. The heading needle is
            // extracted from HTML where <br>/inline tags collapse to a single
            // space ("CHAPTER I. The Period"), but the body plainText renders the
            // same <br> as a NEWLINE ("CHAPTER I.\nThe Period"), so an exact
            // substring search missed it and the heading was dropped — this is
            // why tale-of-two-cities surfaced only its 3 (br-less) book-division
            // headings out of 45 chapters. Match each whitespace run in the
            // needle against `\s+` so the boundary is newline/space agnostic. A
            // single-token needle ("Contents") degrades to a plain literal match.
            let pattern = needle
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: #"\s+"#)
            guard !pattern.isEmpty,
                  cursor <= plainText.endIndex,
                  let range = plainText.range(of: pattern,
                                              options: .regularExpression,
                                              range: cursor..<plainText.endIndex) else {
                continue
            }
            let offset = plainText.distance(from: plainText.startIndex, to: range.lowerBound)
            order += 1
            out.append(StoredTOCEntry(
                title: needle,
                plainTextOffset: offset,
                playOrder: order,
                level: h.level
            ))
            cursor = range.upperBound
        }
        return out
    }
}

// ========== BLOCK 01: HTML LIBRARY IMPORTER (UNITS) - END ==========
