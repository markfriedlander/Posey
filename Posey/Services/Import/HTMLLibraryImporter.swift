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
        let headingLevelByOffset: [Int: Int] = Dictionary(
            uniqueKeysWithValues: resolvedHeadings.map { ($0.plainTextOffset, $0.level) }
        )
        let units = ContentUnitBuilder.applyHeadingMarkers(
            to: baseUnits,
            headingLevelByOffset: headingLevelByOffset
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
        let skipOffset = max(postCatalog, postTOC)
        let contentEndOffset = boundaryResult.contentEndOffset ?? 0
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
        let tocEntries = resolvedHeadings

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
            guard !needle.isEmpty,
                  cursor <= plainText.endIndex,
                  let range = plainText.range(of: needle, range: cursor..<plainText.endIndex) else {
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
