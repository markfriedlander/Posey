import Foundation

// ========== BLOCK 01: EPUB LIBRARY IMPORTER (UNITS) - START ==========

/// Imports EPUB files into the unit-based content model.
///
/// **What changed in the rebuild:** the importer now runs
/// `EPUBDisplayParser` at import time and converts the resulting
/// `DisplayBlock`s into `ContentUnit`s via the shared
/// `ContentUnitBuilder`. When the EPUB has no inline images the
/// display parser returns nothing — the prose fallback splits
/// plainText on blank lines to build prose units, same shape as
/// the TXT importer.
///
/// The four-layer smart-skip composition is unchanged: importer's
/// initial skip → Gutenberg marker → Gutenberg catalog → in-prose
/// TOC → TOC walker. The composed character offset is mapped onto a
/// unit reference via `ContentUnitBuilder.firstUnit(...)`.
///
/// `SentenceIndexer` pre-segments per unit. `persistParsedDocument`
/// writes everything in one transaction.
///
/// 2026-05-23 — rewritten as part of the architecture rebuild.
struct EPUBLibraryImporter {
    let databaseManager: DatabaseManager
    private let importer = EPUBDocumentImporter()
    private let displayParser = EPUBDisplayParser()

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    // 2026-06-15 (Path A — off-main import): `async` so the EPUB parse (which
    // hops to the main actor only for the per-chapter WebKit step) runs off the
    // main thread. Callers `await`; called from a @MainActor context the body
    // runs off-main automatically. Output byte-identical.
    func importDocument(from url: URL) async throws -> Document {
        try FormatPrecheck.checkEPUB(url: url)
        let parsed = try await importer.loadDocument(from: url)
        let contentHash = try? ContentHasher.sha256(of: url)
        let title = TitleExtractor.resolve(
            contentTitle: parsed.title,
            filename: url.lastPathComponent
        )
        return try importParsedDocument(
            title: title,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            parsed: parsed,
            contentHash: contentHash
        )
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "epub") async throws -> Document {
        let parsed = try await importer.loadDocument(fromData: rawData)
        let contentHash = ContentHasher.sha256(rawData)
        let resolved = TitleExtractor.resolve(
            contentTitle: parsed.title ?? (title.isEmpty ? nil : title),
            filename: fileName
        )
        return try importParsedDocument(
            title: resolved,
            fileName: fileName,
            fileType: fileType,
            parsed: parsed,
            contentHash: contentHash
        )
    }

    private func importParsedDocument(
        title: String,
        fileName: String,
        fileType: String,
        parsed: ParsedEPUBDocument,
        contentHash: String?
    ) throws -> Document {
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: parsed.plainText,
            displayText: parsed.displayText,
            contentHash: contentHash
        )
        let documentID = existingDocument?.id ?? UUID()

        // ── Smart-skip composition (unchanged logic, four layers).
        let computed = Self.computeContentStartAndSource(
            existingSkip: parsed.playbackSkipUntilOffset,
            plainText: parsed.plainText,
            tocEntries: parsed.tocEntries
        )
        // 2026-06-12 (finding #2) — pull contentEnd back past a trailing publisher
        // catalog ad (Grosset & Dunlap reprints). 2026-06-14 (#2b fix): this is now
        // computed AFTER units are built, against the UNIT-JOINED plainText, not
        // parsed.plainText — see below. (parsed.plainText and the unit-joined/DB
        // string diverge — dracula 855870 vs 855779 — so a parsed-space offset
        // resolved one unit too late and leaked "There's More to Follow!".)

        // ── Run display parser at import time, build units.
        let blocks = displayParser.parse(displayText: parsed.displayText)
        let baseUnits = ContentUnitBuilder.unitsPreferringBlocks(
            blocks: blocks,
            plainText: parsed.plainText,
            documentID: documentID
        )
        // ── Step 9 prerequisite — promote heading paragraphs into
        // ── `.heading` units. EPUB's parsed.tocEntries already
        // ── carry (title, plainTextOffset, level) tuples.
        // 2026-05-31 (ingestion audit): keep-first on duplicate offsets —
        // `Dictionary(uniqueKeysWithValues:)` fatal-errors on a key collision
        // (two TOC entries resolving to the same offset). See PDFLibraryImporter.
        // 2026-06-10 (fix-pass) — heading markers come from BOTH the native
        // body `<hN>` headings (precise, exact-title — the new primary source)
        // AND the nav/NCX tocEntries (kept for EPUBs without `<hN>` and as a
        // belt-and-suspenders for the working ones). applyHeadingMarkers
        // promotes by title with offset only disambiguating, so overlapping
        // markers for the same chapter are idempotent. Body headings fix
        // dracula (multi-chapter-per-spine-file) and Illuminatus (page-list nav).
        var headingMarkerPairs: [(Int, ContentUnitBuilder.HeadingMarker)] =
            parsed.bodyHeadings.map {
                ($0.offset, ContentUnitBuilder.HeadingMarker(level: $0.level, title: $0.title))
            }
        headingMarkerPairs += parsed.tocEntries.map {
            ($0.plainTextOffset, ContentUnitBuilder.HeadingMarker(level: $0.level, title: $0.title))
        }
        let headingMarkersByOffset: [Int: ContentUnitBuilder.HeadingMarker] = Dictionary(
            headingMarkerPairs,
            uniquingKeysWith: { first, _ in first }
        )
        let units = ContentUnitBuilder.applyHeadingMarkers(
            to: baseUnits,
            headingMarkersByOffset: headingMarkersByOffset
        )

        // 2026-06-14 (#2b fix) — compute the content-end boundary in the SAME
        // coordinate space the reader / persister / firstUnit use: the UNIT-JOINED
        // plainText (prose units joined with "\n\n"). parsed.plainText diverges
        // from it (EPUB dracula: 855870 vs 855779 — a 91-char gap that accumulates
        // toward the end), so the OLD parsed-space offset resolved ONE UNIT too late
        // via firstUnit(atOrAfterPlainTextOffset:) and left the publisher-ad line
        // "There's More to Follow!" in the read-aloud flow (#2b). Recomputing in
        // unit space lands the cut on the catalog's unit, which the reader excludes
        // (contentEndUnitSequence is exclusive). The detector is a no-op on docs
        // with no trailing catalog, so this is safe across the corpus.
        let unitJoinedPlainText = units.filter { $0.kind.carriesProseText }
            .map { $0.text }.joined(separator: "\n\n")
        let rawContentEnd = GutenbergBoundaryDetector.detect(in: unitJoinedPlainText).contentEndOffset ?? 0
        let contentEndOffset = InProseTOCDetector.contentEndBeforePublisherCatalog(
            in: unitJoinedPlainText, at: rawContentEnd) ?? rawContentEnd

        // ── Map smart-skip offset to a unit reference.
        let skipUnitID = ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: computed.skipOffset)?.id
        let contentEndUnitID: UUID? = {
            guard contentEndOffset > 0 else { return nil }
            return ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: contentEndOffset)?.id
        }()

        // ── Sentences.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── TOC entries (pass-through; offsets already in plainText space).
        let tocEntries: [StoredTOCEntry] = parsed.tocEntries.map {
            StoredTOCEntry(
                title: $0.title,
                plainTextOffset: $0.plainTextOffset,
                playOrder: $0.playOrder,
                level: $0.level
            )
        }

        // **Bundle 2 follow-up (2026-05-26)** — edition label from
        // EPUB metadata. Prefer "Illustrated by <name>" when the OPF
        // has a contributor with `opf:role="ill"`; else fall back to
        // the creator (only useful when the creator alone
        // disambiguates, which is rare for ambiguous-title cases
        // but cheap to include).
        let editionLabel: String? = {
            if let ill = parsed.illustrator, !ill.isEmpty {
                return "Illustrated by \(ill)"
            }
            if let creator = parsed.creator, !creator.isEmpty {
                return creator
            }
            return nil
        }()

        let parsedDoc = ParsedDocument(
            id: documentID,
            title: title,
            fileName: fileName,
            fileType: fileType,
            units: units,
            sentences: sentences,
            toc: tocEntries,
            skipUnitID: skipUnitID,
            skipSource: computed.skipSource,
            playbackSkipUntilOffset: computed.skipOffset,
            contentEndOffset: contentEndOffset,
            contentEndUnitID: contentEndUnitID,
            contentHash: contentHash,
            editionLabel: editionLabel
        )
        try databaseManager.persistParsedDocument(parsedDoc)

        // Persist inline images.
        try databaseManager.deleteImages(for: documentID)
        for image in parsed.images {
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
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            characterCount: parsed.plainText.count,
            playbackSkipUntilOffset: computed.skipOffset,
            contentEndOffset: contentEndOffset,
            skipSource: computed.skipSource,
            contentHash: contentHash,
            editionLabel: editionLabel
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

    // MARK: - Smart-skip composition (unchanged from legacy)

    struct ContentStartResult {
        let skipOffset: Int
        let skipSource: String
    }

    fileprivate static func computeContentStartAndSource(
        existingSkip: Int,
        plainText: String,
        tocEntries: [EPUBTOCEntry]
    ) -> ContentStartResult {
        let gutenbergStart = GutenbergBoundaryDetector.detect(in: plainText).contentStartOffset ?? 0
        let postGutenberg = max(existingSkip, gutenbergStart)
        let postCatalog = GutenbergCatalogDetector.endOfCatalogRegion(in: plainText, after: postGutenberg) ?? postGutenberg
        let postTOC = InProseTOCDetector.endOfTOCRegion(in: plainText, after: postCatalog) ?? postCatalog
        let afterInProse = max(postCatalog, postTOC)

        let walkerEntries = tocEntries
            .map { TOCWalkContentStartDetector.TOCEntry(title: $0.title, plainTextOffset: $0.plainTextOffset) }
            .sorted { $0.plainTextOffset < $1.plainTextOffset }
        let walkResult = TOCWalkContentStartDetector.detect(
            tocEntries: walkerEntries,
            plainText: plainText,
            currentSkip: afterInProse
        )
        let postWalker = max(afterInProse, walkResult.newSkipOffset ?? afterInProse)
        // 2026-06-11 [DECISION] (Mark — SUPERSEDES the 2026-05-27 FirstChapterAdvance
        // decision): ALL prefaces (author AND editorial) are BOOK CONTENT. A
        // gutenberg book opens at the FIRST REAL PROSE after (a) the PG license
        // boilerplate and (b) the in-book Contents/TOC listing — it NEVER skips a
        // preface to Chapter I.
        //   (B) The old `FirstChapterAdvance.detect(...)` "skip in-work front-matter
        //       (ETYMOLOGY / Saintsbury Preface / Letters) -> Chapter 1" step is
        //       REMOVED. Pride & Prejudice now opens at the Saintsbury Preface
        //       (the reversal — now intended); Moby opens at "ETYMOLOGY."
        //   (A) If the skip is still sitting ON a Contents listing (Dracula stayed
        //       at 1116 because the listing entry "CHAPTER I." never second-matched
        //       the merged body heading "CHAPTER I:"), advance past the listing to
        //       the first prose — Dracula → Stoker's preface (~2400), NOT Chapter I.
        //       No-op when not on a Contents listing (guarded by a nearby header).
        let afterContents = InProseTOCDetector.firstProseAfterContentsListing(
            in: plainText, at: postWalker, tocTitles: tocEntries.map { $0.title }) ?? postWalker
        // 2026-06-11 (auditor c6) — advance past leading title-page/publisher/
        // illustration-list apparatus to first real content (illustrated PG
        // EPUBs). No-op when the landing isn't apparatus (parity with TXT/HTML).
        let finalSkip = InProseTOCDetector.contentStartAfterPublishingApparatus(
            in: plainText, at: afterContents) ?? afterContents

        let source: String
        if gutenbergStart > 0 {
            source = "gutenberg"
        } else if finalSkip > 0 {
            source = "heuristic"
        } else {
            source = ""
        }
        return ContentStartResult(skipOffset: finalSkip, skipSource: source)
    }
}

// ========== BLOCK 01: EPUB LIBRARY IMPORTER (UNITS) - END ==========
