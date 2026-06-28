import Foundation

// ========== BLOCK 01: TXT LIBRARY IMPORTER (UNITS) - START ==========

/// Imports plain-text files into the unit-based content model.
///
/// **What changed in the rebuild:** the importer now emits an ordered
/// list of `ContentUnit`s instead of producing a single plainText
/// string. Each paragraph (separated by one or more blank lines in
/// the source) becomes one `.prose` unit. `SentenceIndexer` runs
/// over every unit to pre-compute sentences. `DatabaseManager.
/// persistParsedDocument` writes everything in one transaction.
///
/// The legacy `Document.plainText` / `displayText` columns are still
/// populated (as a join of unit text) so consumers that haven't
/// switched to units yet still see a coherent document. Those
/// columns get dropped in the final cleanup pass.
///
/// 2026-05-23 — rewritten as part of the architecture rebuild.
struct TXTLibraryImporter {
    let databaseManager: DatabaseManager
    private let textLoader = TXTDocumentImporter()

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func importDocument(from url: URL) throws -> Document {
        let plainText = try textLoader.loadText(from: url)
        // Bundle 2a — content-derived title (Gutenberg `Title:` header
        // or first short line) with cleaned-filename fallback.
        let derived = TitleExtractor.fromTXT(plainText: plainText)
        let title = TitleExtractor.resolve(
            contentTitle: derived,
            filename: url.lastPathComponent
        )
        let contentHash = try? ContentHasher.sha256(of: url)
        return try importNormalizedDocument(
            title: title,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            plainText: plainText,
            contentHash: contentHash
        )
    }

    func importDocument(title: String, fileName: String, rawText: String, fileType: String = "txt") throws -> Document {
        let plainText = try textLoader.loadText(fromContents: rawText)
        let derived = TitleExtractor.fromTXT(plainText: plainText)
        let resolved = title.isEmpty
            ? TitleExtractor.resolve(contentTitle: derived, filename: fileName)
            : title
        let contentHash = ContentHasher.sha256(Data(rawText.utf8))
        return try importNormalizedDocument(
            title: resolved,
            fileName: fileName,
            fileType: fileType,
            plainText: plainText,
            contentHash: contentHash
        )
    }

    private func importNormalizedDocument(
        title: String,
        fileName: String,
        fileType: String,
        plainText: String,
        contentHash: String?
    ) throws -> Document {
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText,
            contentHash: contentHash
        )
        let documentID = existingDocument?.id ?? UUID()

        // ── Smart-skip detection (operates on plainText, then maps
        // ── the result offset to a unit id once units are built).
        let boundaries = GutenbergBoundaryDetector.detect(in: plainText)
        let gutenbergStart = boundaries.contentStartOffset ?? 0
        let postCatalog = GutenbergCatalogDetector.endOfCatalogRegion(
            in: plainText, after: gutenbergStart
        ) ?? gutenbergStart
        let postTOC = InProseTOCDetector.endOfTOCRegion(
            in: plainText, after: postCatalog
        ) ?? postCatalog
        let postFrontMatter = max(postCatalog, postTOC)
        // 2026-06-11 [DECISION] (Mark — format-parity with the EPUB ruling
        // a6d892e, SUPERSEDES the 2026-05-27 FirstChapterAdvance step): ALL
        // prefaces (author AND editorial) are BOOK CONTENT. A gutenberg book
        // opens at the FIRST REAL PROSE after (a) the PG license boilerplate and
        // (b) the in-book Contents/TOC listing — it NEVER skips a preface to
        // Chapter I. So Moby TXT now opens at "ETYMOLOGY." (kept), not "Call me
        // Ishmael."; Frankenstein keeps its Letters. The old FirstChapterAdvance
        // "skip in-work front-matter -> Chapter 1" step is REMOVED; in its place,
        // if the skip still sits on a Contents listing, advance past the listing
        // to the first prose (no-op when not on a listing). TXT has no structural
        // TOC titles, so the listing entries are matched structurally (tocTitles []).
        let afterContents = InProseTOCDetector.firstProseAfterContentsListing(
            in: plainText, at: postFrontMatter, tocTitles: []) ?? postFrontMatter
        // 2026-06-11 (auditor c6) — then advance past any leading title-page /
        // publisher / illustration-list apparatus to the first real content
        // (illustrated PG editions: P&P → Saintsbury "PREFACE."). No-op when the
        // landing isn't apparatus (Moby stays on ETYMOLOGY, Dracula on its preface).
        let skipOffset = InProseTOCDetector.contentStartAfterPublishingApparatus(
            in: plainText, at: afterContents) ?? afterContents
        // 2026-06-12 (finding #2) — pull contentEnd back past a trailing publisher
        // catalog ad. 2026-06-14 (#2b parity): computed AFTER units, against the
        // unit-joined plainText (the space firstUnit/reader use) — see below.
        let skipSource: String = {
            if gutenbergStart > 0 { return "gutenberg" }
            if skipOffset > 0   { return "heuristic" }
            return ""
        }()

        // ── Paragraph split → prose units.
        let rawUnits = ContentUnitBuilder.proseUnits(
            fromPlainText: plainText,
            documentID: documentID
        )
        // 2026-05-31 (Bug G) — Gutenberg books list every "CHAPTER N. Title."
        // in a front-matter CONTENTS section AND at each real chapter start, so
        // proseUnits promotes BOTH (Moby TXT: 272 heading units = 136 listing +
        // 136 body). Demote the LISTING copies back to prose — identified by
        // having a BODY twin (same title at/after the skip), so legitimate
        // front-matter headings with no body copy are preserved. The TOC builder
        // below already excludes the listing from document_toc via the skip
        // gate; this aligns the heading UNITS.
        // Ruler migration #3 (2026-06-28): translate the R1 skip offset to the
        // skip UNIT once (against THIS rawUnits list), then demote by identity —
        // no R1-offset-vs-R2-running-offset comparison inside the helper.
        let demotedUnits = ContentUnitBuilder.demoteDuplicateListingHeadings(
            rawUnits,
            skipUnitID: ContentUnitBuilder.firstUnit(in: rawUnits, atOrAfterPlainTextOffset: skipOffset)?.id
        )
        // 2026-06-11 heading standard — merge a label-only chapter heading with
        // the title line below it into ONE heading ("CHAPTER I" + "JONATHAN
        // HARKER'S JOURNAL" → "CHAPTER I: JONATHAN HARKER'S JOURNAL"). Runs
        // before skip/sentence mapping so they see the final unit list.
        let units = ContentUnitBuilder.mergeLabelTitleHeadings(demotedUnits)

        // 2026-06-14 (#2b parity) — compute the content-end boundary in UNIT-JOINED
        // space (the cumulative space firstUnit/persister/reader use), not the
        // loaded `plainText`, so the trailing-catalog cut aligns with the cutoff
        // unit. No-op when the two agree (TXT usually) or there's no catalog;
        // matches the EPUB/HTML #2b fix for cross-format consistency.
        let unitJoinedPlainText = units.filter { $0.kind.carriesProseText }
            .map { $0.text }.joined(separator: "\n\n")
        let rawContentEnd = GutenbergBoundaryDetector.detect(in: unitJoinedPlainText).contentEndOffset ?? 0
        let contentEndOffset = InProseTOCDetector.contentEndBeforePublisherCatalog(
            in: unitJoinedPlainText, at: rawContentEnd) ?? rawContentEnd

        // ── Map smart-skip plainText offsets to unit ids.
        let skipUnitID = ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: skipOffset)?.id
        // The content-start boundary as a unit SEQUENCE (the Position Rule): the
        // TOC skip-gate below compares heading sequence to this — same skip unit
        // the reader/chunker window by — instead of an R2 running offset vs the R1
        // skipOffset. nil (no skip unit) → include every heading. (#3, 2026-06-28)
        let skipSequence = units.first(where: { $0.id == skipUnitID })?.sequence
        let contentEndUnitID: UUID? = {
            guard contentEndOffset > 0 else { return nil }
            return ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: contentEndOffset)?.id
        }()

        // ── Pre-compute sentences per unit.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── Build TOC from heading units. Each .heading unit emitted
        // by ContentUnitBuilder.proseUnits (Gutenberg-style CHAPTER
        // pattern) becomes a navigable TOC entry. Offsets must match
        // the persister's plainText join scheme (prose units joined
        // with `\n\n`), so we walk the units array maintaining the
        // running plainText offset.
        var tocEntries: [StoredTOCEntry] = []
        var runningOffset = 0
        var firstProseSeen = false
        for unit in units {
            guard unit.kind.carriesProseText else { continue }
            if firstProseSeen { runningOffset += 2 /* "\n\n" */ }
            firstProseSeen = true
            if unit.kind == .heading && (skipSequence.map { unit.sequence >= $0 } ?? true) {
                // Skip catalog-list entries that live BEFORE the
                // smart-skip target (now by unit SEQUENCE, not an R2
                // running offset vs the R1 skipOffset). Gutenberg books
                // surface "CHAPTER N. Title." both in the CONTENTS catalog
                // at the top (133+ entries for Moby) AND at each actual
                // chapter start in the body. Without this filter the TOC
                // doubles up — the catalog version comes first and
                // jumps the reader to the catalog, not the chapter.
                tocEntries.append(StoredTOCEntry(
                    title: unit.text,
                    plainTextOffset: runningOffset,
                    playOrder: tocEntries.count + 1,
                    level: unit.metadata.headingLevel ?? 1
                ))
            }
            runningOffset += unit.text.count
        }

        // ── Persist atomically.
        let parsed = ParsedDocument(
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
        try databaseManager.persistParsedDocument(parsed)

        // Initial reading position when this is a new document.
        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: documentID))
        }

        // Best-effort: kick the legacy embedding index for Ask Posey
        // RAG. During the rollout, RAG still consumes the old chunks
        // table (built from the derived plain_text we wrote during
        // persistence). The new unit-aware chunker comes online once
        // every format has flipped.
        let now = Date()
        let document = Document(
            id: documentID,
            title: title,
            fileName: fileName,
            fileType: fileType,
            importedAt: existingDocument?.importedAt ?? now,
            modifiedAt: now,
            displayText: plainText,
            plainText: plainText,
            characterCount: plainText.count,
            playbackSkipUntilOffset: skipOffset,
            contentEndOffset: contentEndOffset,
            skipSource: skipSource,
            contentHash: contentHash,
            editionLabel: nil
        )
        // 2026-05-23 — Step 8b: new unit-anchored chunker runs in
        // parallel with the legacy one during the cutover.
        let docID = document.id
        let dbRef = databaseManager
        Task.detached {
            await UnitEmbeddingService.shared.enqueueIndexing(
                documentID: docID, databaseManager: dbRef
            )
        }
        return document
    }

    // Paragraph splitting and offset-to-unit mapping moved to the
    // shared `ContentUnitBuilder` so every format uses one source of
    // truth for those operations.
}

// ========== BLOCK 01: TXT LIBRARY IMPORTER (UNITS) - END ==========
