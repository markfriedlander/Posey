import Foundation

// ========== BLOCK 01: PDF LIBRARY IMPORTER (UNITS) - START ==========

/// Imports PDF files into the unit-based content model.
///
/// **What changed in the rebuild:** the importer emits an ordered
/// list of `ContentUnit`s with explicit `pageBreak` units between
/// pages (carrying the page index in `metadata.pageNumber`) and
/// prose / image units for each page's content. Page-aware
/// affordances (TOC page-jump, etc.) derive page positions from
/// these `pageBreak` units instead of the form-feed-separated
/// `displayText` string.
///
/// Phase 2.2 background enhancement (Tier 2 Vision + Tier 3 AFM)
/// is **still enqueued for unit-based PDFs in this commit**, and
/// **still operates on the legacy `plain_text` / `document_chunks`
/// stores**. The persister populates those stores by joining unit
/// text, so Tier 2/3 see coherent input. A follow-up commit in the
/// same rebuild slice rewrites Tier 2/3 to mutate units directly;
/// at that point the legacy stores get retired.
///
/// 2026-05-23 — rewritten as part of the architecture rebuild.
struct PDFLibraryImporter {
    let databaseManager: DatabaseManager
    private let importer = PDFDocumentImporter()

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func importDocument(from url: URL) throws -> Document {
        try FormatPrecheck.checkPDF(url: url)
        let parsed = try importer.loadDocument(from: url)
        let sourceData = (try? Data(contentsOf: url)) ?? nil
        let contentHash = sourceData.map { ContentHasher.sha256($0) }
        return try persistParsedPDF(parsed, from: url, sourceData: sourceData, contentHash: contentHash)
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "pdf") throws -> Document {
        let parsed = try importer.loadDocument(fromData: rawData)
        let contentHash = ContentHasher.sha256(rawData)
        let doc = try persistAsUnits(
            parsed: parsed,
            titleFallback: title,
            fileName: fileName,
            fileType: fileType,
            contentHash: contentHash
        )
        try saveImages(parsed.images, for: doc.id)
        PageFlagsStore.write(
            flags: parsed.pageFlags,
            for: doc.id,
            fileName: fileName,
            pageCount: parsed.pageFlags.count
        )
        // 2026-05-27 — setContentBoundaries removed; derived on-demand
        // by DatabaseManager.contentBoundaries(for:).
        _ = PDFSourceStore.save(rawData, for: doc.id)
        enqueueEnhancement(documentID: doc.id, pageFlags: parsed.pageFlags)
        return doc
    }

    /// Async-friendly entry. Same shape as the legacy
    /// `persistParsedDocument(_:from:)` — kept for compatibility
    /// with PoseyApp / LocalAPI callers.
    func persistParsedDocument(_ parsed: ParsedPDFDocument, from url: URL) throws -> Document {
        let sourceData = try? Data(contentsOf: url)
        return try persistParsedPDF(
            parsed, from: url, sourceData: sourceData,
            contentHash: sourceData.map { ContentHasher.sha256($0) }
        )
    }

    func persistParsedDocument(_ parsed: ParsedPDFDocument, from url: URL, sourceData: Data?) throws -> Document {
        try persistParsedPDF(
            parsed, from: url, sourceData: sourceData,
            contentHash: sourceData.map { ContentHasher.sha256($0) }
        )
    }

    private func persistParsedPDF(
        _ parsed: ParsedPDFDocument,
        from url: URL,
        sourceData: Data?,
        contentHash: String?
    ) throws -> Document {
        // Strip duplicate file extensions (e.g. "report.pdf.pdf" → "report.pdf").
        let rawFilename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let withoutExt = (rawFilename as NSString).deletingPathExtension
        let fileName = (withoutExt as NSString).pathExtension.lowercased() == ext ? withoutExt : rawFilename
        let titleFallback = (fileName as NSString).deletingPathExtension

        let doc = try persistAsUnits(
            parsed: parsed,
            titleFallback: titleFallback,
            fileName: fileName,
            fileType: ext,
            contentHash: contentHash
        )
        try saveImages(parsed.images, for: doc.id)

        PageFlagsStore.write(
            flags: parsed.pageFlags,
            for: doc.id,
            fileName: fileName,
            pageCount: parsed.pageFlags.count
        )
        // 2026-05-27 — setContentBoundaries removed; derived on-demand
        // by DatabaseManager.contentBoundaries(for:).
        if let sourceData {
            _ = PDFSourceStore.save(sourceData, for: doc.id)
        }
        enqueueEnhancement(documentID: doc.id, pageFlags: parsed.pageFlags)

        return doc
    }

    // MARK: - Unit persistence

    private func persistAsUnits(
        parsed: ParsedPDFDocument,
        titleFallback: String,
        fileName: String,
        fileType: String,
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
        // Bundle 2a — prefer PDF metadata title, else cleaned filename.
        let title = TitleExtractor.resolve(
            contentTitle: parsed.title,
            filename: titleFallback
        )

        // ── Build units from displayText (preserves form-feed
        // ── page boundaries as pageBreak units, image markers as
        // ── image units, paragraph runs as prose units).
        let baseUnits = ContentUnitBuilder.unitsFromPDFDisplayText(
            parsed.displayText,
            documentID: documentID
        )
        // ── Step 9 prerequisite — promote heading paragraphs into
        // ── `.heading` units using PDFTOCDetector output. Helper
        // ── skips non-prose units (pageBreak / image) and only
        // ── advances the offset cursor on prose-bearing kinds —
        // ── matches the persister's plain_text join scheme.
        // 2026-05-31 (ingestion audit): tolerate duplicate offsets. Two TOC
        // entries CAN resolve to the same plainTextOffset (front-matter titles
        // with no unique body location, repeated titles, or unresolved entries
        // defaulting to the same anchor). `Dictionary(uniqueKeysWithValues:)`
        // FATAL-ERRORS on a duplicate key — this crashed GEB import
        // (EXC_BREAKPOINT) the moment the run-on TOC detector emitted entries.
        // Keep the first marker at each offset; never trap on a collision.
        let headingMarkersByOffset: [Int: ContentUnitBuilder.HeadingMarker] = Dictionary(
            parsed.tocEntries.map {
                ($0.plainTextOffset, ContentUnitBuilder.HeadingMarker(level: $0.level, title: $0.title))
            },
            uniquingKeysWith: { first, _ in first }
        )
        // 2026-05-31 — pass the TOC-skip offset so a TOC-LISTING entry in the
        // front matter (now split into one unit per entry by the TOC line-
        // preservation pass) is never promoted to a chapter heading. The
        // chapter headings live in the body, after the skip.
        // Ruler migration #3b (2026-06-28): translate the R1 TOC-skip offset to
        // the skip UNIT once (against baseUnits), then gate heading promotion by
        // identity — no R1-offset-vs-R2-unit-offset comparison inside the helper.
        let units = ContentUnitBuilder.applyHeadingMarkers(
            to: baseUnits,
            headingMarkersByOffset: headingMarkersByOffset,
            skipUnitID: ContentUnitBuilder.firstUnit(
                in: baseUnits, atOrAfterPlainTextOffset: parsed.tocSkipUntilOffset)?.id
        )

        // ── Sentences from prose-bearing units.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── Smart-skip: PDF's tocSkipUntilOffset is a plainText
        // ── offset (PDFTOCDetector heuristic). Map to a unit.
        let skipOffset = parsed.tocSkipUntilOffset
        let skipUnitID = ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: skipOffset)?.id
        let skipSource = skipOffset > 0 ? "heuristic" : ""

        // ── TOC pass-through. Resolve each heading's offset → its durable paragraph
        // identity (same ruler, at import); drop an entry that can't anchor (Position Rule).
        let tocEntries: [StoredTOCEntry] = parsed.tocEntries.compactMap { e in
            guard let uid = ContentUnitBuilder.firstUnit(
                in: units, atOrAfterPlainTextOffset: e.plainTextOffset)?.id else { return nil }
            return StoredTOCEntry(
                title: e.title,
                plainTextOffset: e.plainTextOffset,
                unitID: uid,
                playOrder: e.playOrder,
                level: e.level
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
            playbackSkipUntilOffset: skipOffset,
            contentEndOffset: 0,
            contentEndUnitID: nil,
            contentHash: contentHash,
            editionLabel: nil
        )
        try databaseManager.persistParsedDocument(parsedDoc)

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
            playbackSkipUntilOffset: skipOffset,
            skipSource: skipSource,
            contentHash: contentHash
        )

        // PDF embedding indexing is still deferred to end-of-Tier-3
        // by PDFEnhancementService so embeddings are built against
        // the corrected text rather than Tier 1's first pass.
        // Nothing to enqueue here.

        return document
    }

    /// 2026-05-22 Phase 2.2 Step 4 — bridge to the background
    /// `PDFEnhancementService`. Unchanged in shape during the
    /// rebuild; Tier 2/3 still operate on plain_text / chunks
    /// until the follow-up commit retargets them onto units.
    private func enqueueEnhancement(documentID: UUID, pageFlags: [PDFPageFlags]) {
        do {
            try databaseManager.updateEnhancementState(
                documentID: documentID,
                status: "pending",
                error: nil
            )
        } catch {
            dbgLog("PDFLibraryImporter: failed to mark enhancement pending for %@: %@",
                   documentID.uuidString, String(describing: error))
        }
        Task {
            await PDFEnhancementService.shared.enqueue(documentID)
        }
    }

    private func saveImages(_ images: [PageImageRecord], for documentID: UUID) throws {
        try databaseManager.deleteImages(for: documentID)
        for image in images {
            try databaseManager.insertImage(id: image.imageID, documentID: documentID, data: image.data)
        }
    }
}

// ========== BLOCK 01: PDF LIBRARY IMPORTER (UNITS) - END ==========
