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

    func importDocument(from url: URL) throws -> Document {
        try FormatPrecheck.checkEPUB(url: url)
        let parsed = try importer.loadDocument(from: url)
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

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "epub") throws -> Document {
        let parsed = try importer.loadDocument(fromData: rawData)
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
        let boundaries = GutenbergBoundaryDetector.detect(in: parsed.plainText)
        let contentEndOffset = boundaries.contentEndOffset ?? 0

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
        let headingLevelByOffset: [Int: Int] = Dictionary(
            uniqueKeysWithValues: parsed.tocEntries.map { ($0.plainTextOffset, $0.level) }
        )
        let units = ContentUnitBuilder.applyHeadingMarkers(
            to: baseUnits,
            headingLevelByOffset: headingLevelByOffset
        )

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
        let finalSkip = max(afterInProse, walkResult.newSkipOffset ?? afterInProse)

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
