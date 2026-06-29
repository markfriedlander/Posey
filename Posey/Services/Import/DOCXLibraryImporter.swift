import Foundation

// ========== BLOCK 01: DOCX LIBRARY IMPORTER (UNITS) - START ==========

/// Imports DOCX files into the unit-based content model.
///
/// **What changed in the rebuild:** the importer now runs
/// `DOCXDisplayParser` at import time (instead of at reader-open
/// time) and converts the resulting `DisplayBlock`s into
/// `ContentUnit`s. Images stored in the side-store table are
/// surfaced as `.image` units interleaved at their displayText
/// positions. `SentenceIndexer` pre-segments per unit.
///
/// 2026-05-23 — rewritten as part of the architecture rebuild.
struct DOCXLibraryImporter {
    let databaseManager: DatabaseManager
    private let textLoader = DOCXDocumentImporter()
    private let displayParser = DOCXDisplayParser()

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func importDocument(from url: URL) throws -> Document {
        try FormatPrecheck.checkDOCX(url: url)
        let parsed = try textLoader.loadDocument(from: url)
        let contentHash = try? ContentHasher.sha256(of: url)
        let title = TitleExtractor.resolve(
            contentTitle: Self.contentTitle(coreTitle: parsed.coreTitle, headings: parsed.headings),
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
            tables: parsed.tables,
            contentHash: contentHash
        )
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "docx") throws -> Document {
        let parsed = try textLoader.loadDocument(fromData: rawData)
        let contentHash = ContentHasher.sha256(rawData)
        let resolved = title.isEmpty
            ? TitleExtractor.resolve(
                contentTitle: Self.contentTitle(coreTitle: parsed.coreTitle, headings: parsed.headings),
                filename: fileName)
            : title
        return try importNormalizedDocument(
            title: resolved,
            fileName: fileName,
            fileType: fileType,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            images: parsed.images,
            headings: parsed.headings,
            tables: parsed.tables,
            contentHash: contentHash
        )
    }

    /// **2026-06-15 — title fallback.** DOCX `<dc:title>` is frequently
    /// absent (Word only writes it when the author fills in Properties →
    /// Title). When it is, fall back to the document's first heading —
    /// the on-page H1 — which is the real title a reader sees, e.g.
    /// "Tables and Images DOCX". Without this we dropped to the cleaned
    /// FILENAME, and `TitleExtractor.cleanedFilename`'s Gutenberg
    /// variant-suffix strip (`-images`/`-cleaned`/`-raw`) over-eagerly
    /// ate the legitimate trailing word — "docx_tables-and-images" →
    /// "Docx Tables And". Prefer a level-1 heading; else the first
    /// heading of any level. Mirrors the MD (`# H1`) / HTML (`<h1>`)
    /// content-title strategy. Returns nil → caller uses the filename.
    private static func contentTitle(
        coreTitle: String?,
        headings: [DOCXDocumentImporter.DOCXHeadingEntry]
    ) -> String? {
        if let core = coreTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !core.isEmpty {
            return core
        }
        if let h1 = headings.first(where: { $0.level == 1 }) {
            return h1.title
        }
        return headings.first?.title
    }

    /// **2026-06-15 — table-as-image.** For each captured table, find the
    /// single built unit whose text equals the table's rendered text and
    /// flip it from `.prose` to `.table`, attaching the rasterized PNG via
    /// `metadata.imageID`. The renderer then draws the image (tap-to-zoom)
    /// while the text stays for search / RAG / TTS (`ContentUnitKind.table`).
    ///
    /// Matched by exact text equality: the table text is one whole unit
    /// (the importer emits it as one `\n\n`-delimited paragraph with `" | "`
    /// cells and `\n` rows) and is highly distinctive, so a false match is
    /// effectively impossible. Each table is consumed once (a later
    /// identical table matches the next unmatched unit). If no unit matches
    /// (e.g. the table text got split or normalized differently), the table
    /// silently stays a text unit — graceful degradation, never a crash.
    private static func applyTableImages(
        to units: [ContentUnit],
        tables: [(text: String, imageID: String)]
    ) -> [ContentUnit] {
        guard !tables.isEmpty else { return units }
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var remaining = tables.map { (text: key($0.text), imageID: $0.imageID) }
        return units.map { unit in
            let unitKey = key(unit.text)
            guard unit.kind == .prose, !remaining.isEmpty,
                  let idx = remaining.firstIndex(where: { $0.text == unitKey }) else {
                return unit
            }
            let imageID = remaining.remove(at: idx).imageID
            var metadata = unit.metadata
            metadata.imageID = imageID
            return ContentUnit(
                id: unit.id,
                documentID: unit.documentID,
                sequence: unit.sequence,
                kind: .table,
                text: unit.text,
                metadata: metadata,
                revision: unit.revision,
                sourceTier: unit.sourceTier
            )
        }
    }

    private func importNormalizedDocument(
        title: String,
        fileName: String,
        fileType: String,
        displayText: String,
        plainText: String,
        images: [PageImageRecord],
        headings: [DOCXDocumentImporter.DOCXHeadingEntry],
        tables: [(text: String, imageID: String)],
        contentHash: String?
    ) throws -> Document {
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText,
            contentHash: contentHash
        )
        let documentID = existingDocument?.id ?? UUID()

        // ── Run the display parser at import time (was reader-open).
        let blocks = displayParser.parse(displayText: displayText)

        // ── Convert blocks to units. DOCXDisplayParser only emits
        // ── blocks when the doc has inline images; plain-paragraph
        // ── DOCXs fall back to plainText paragraph splitting.
        let baseUnits = ContentUnitBuilder.unitsPreferringBlocks(
            blocks: blocks,
            plainText: plainText,
            documentID: documentID
        )
        // ── Step 9 prerequisite — promote prose paragraphs whose
        // ── offsets match heading entries into `.heading` units, so
        // ── the unified UnitRowView renderer styles them by kind.
        // 2026-05-31 (ingestion audit): keep-first on duplicate offsets —
        // `Dictionary(uniqueKeysWithValues:)` fatal-errors on a key collision
        // (two headings resolving to the same offset). See PDFLibraryImporter.
        let headingMarkersByOffset: [Int: ContentUnitBuilder.HeadingMarker] = Dictionary(
            headings.map {
                ($0.plainTextOffset, ContentUnitBuilder.HeadingMarker(level: $0.level, title: $0.title))
            },
            uniquingKeysWith: { first, _ in first }
        )
        var units = ContentUnitBuilder.applyHeadingMarkers(
            to: baseUnits,
            headingMarkersByOffset: headingMarkersByOffset
        )
        // ── Table-as-image (2026-06-15): flip the prose unit carrying each
        // captured table's text to `.table`, attaching the rasterized PNG's
        // imageID. Done BEFORE sentence indexing — but `.table` is
        // carriesProseText, so it still gets sentences (searchable + TTS).
        // Text is unchanged, so offsets / skip / TOC are unaffected.
        units = Self.applyTableImages(to: units, tables: tables)

        // ── Smart-skip: heading-based TOCSkipDetector.
        let tocSkipOffset = TOCSkipDetector.skipOffset(
            for: headings.map { (title: $0.title, plainTextOffset: $0.plainTextOffset) },
            in: plainText
        )
        let skipUnitID = ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: tocSkipOffset)?.id
        let skipSource = tocSkipOffset > 0 ? "heuristic" : ""

        // ── Sentences.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── TOC entries. Resolve each heading's offset → its durable paragraph
        // identity (same ruler, at import); drop an entry that can't anchor (Position Rule).
        let tocEntries: [StoredTOCEntry] = headings.enumerated().compactMap { (idx, h) in
            guard let uid = ContentUnitBuilder.firstUnit(
                in: units, atOrAfterPlainTextOffset: h.plainTextOffset)?.id else { return nil }
            return StoredTOCEntry(
                title: h.title,
                plainTextOffset: h.plainTextOffset,
                unitID: uid,
                playOrder: idx + 1,
                level: h.level
            )
        }

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
            playbackSkipUntilOffset: tocSkipOffset,
            contentEndOffset: 0,
            contentEndUnitID: nil,
            contentHash: contentHash,
            editionLabel: nil
        )
        try databaseManager.persistParsedDocument(parsedDoc)

        // Persist inline images (still in the side-store table; the
        // .image unit's metadata.imageID references them).
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
            playbackSkipUntilOffset: tocSkipOffset,
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
}

// ========== BLOCK 01: DOCX LIBRARY IMPORTER (UNITS) - END ==========

// MarkdownLibraryImporter.buildUnits / firstUnit reused as the
// shared display-block → unit converter and offset-to-unit mapper.
// Keeping them in MarkdownLibraryImporter for now to avoid moving
// them mid-rollout; they'll find a permanent home (probably
// `Posey/Services/Import/ContentUnitBuilder.swift`) during the
// cleanup pass.
