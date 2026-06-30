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
/// mutates the document's UNITS directly: Tier 2 rewrites a corrected
/// page's units via `DatabaseManager.replaceUnitsForPage`; Tier 3 swaps
/// fusion-repair tokens via `replaceTokenInUnits`. The legacy
/// `plain_text` / `display_text` columns were retired (Step 10) — both
/// text forms now derive from `document_units` on demand. The
/// unit-anchored embedding chunker re-runs at end-of-enhancement so the
/// chunk set reflects the corrected units.
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

        // ── Build content units.
        let units: [ContentUnit]
        let tocEntries: [StoredTOCEntry]

        if !parsed.linesByPage.isEmpty {
            // PDF rebuild (2026-06-29): line-based construction + identity heading
            // anchoring. Clean PDFKit-native lines → paragraph + heading units;
            // each known title resolved to its real heading LINE (the weightiest
            // standout appearance — Mark's "pool the appearances, keep the
            // weightiest") → that line becomes a `.heading` unit → the TOC entry
            // anchors to it by UUID. No page numbers, no cross-layer offsets.
            let allLines = parsed.linesByPage.flatMap { $0 }
            let resolved = PDFHeadingKeyDeriver.resolveHeadings(
                titles: parsed.tocEntries.map { $0.title }, allLines: allLines)
            let headingLineSet = Set(resolved.map { $0.line })
            let levelByTitle = Dictionary(parsed.tocEntries.map { ($0.title, $0.level) },
                                          uniquingKeysWith: { a, _ in a })
            var levelByLineText: [String: Int] = [:]
            for r in resolved { levelByLineText[r.line.text] = levelByTitle[r.title] ?? 1 }

            units = ContentUnitBuilder.unitsFromPDFLines(
                parsed.linesByPage, documentID: documentID,
                isHeading: { headingLineSet.contains($0) },
                headingLevel: { levelByLineText[$0.text] ?? 1 })

            // Anchor each TOC entry to its heading unit by identity (the heading
            // unit's text == the resolved line's text). Fallback (never fail
            // silently): first prose-bearing unit containing the title; else drop.
            var headingUnitIDByText: [String: UUID] = [:]
            for u in units where u.kind == .heading {
                if headingUnitIDByText[u.text] == nil { headingUnitIDByText[u.text] = u.id }
            }
            let lineTextByTitle = Dictionary(resolved.map { ($0.title, $0.line.text) },
                                             uniquingKeysWith: { a, _ in a })
            tocEntries = parsed.tocEntries.compactMap { e in
                let uid: UUID?
                if let lineText = lineTextByTitle[e.title], let id = headingUnitIDByText[lineText] {
                    uid = id
                } else {
                    // Fallback: a HEADING unit matching the title — never the
                    // contents-listing prose (where every title's words appear).
                    // If none matches, drop the entry rather than dump it on the
                    // contents page (which clustered §1/§4/§7/§8 there). Position
                    // Rule: an entry that can't anchor by identity is dropped.
                    uid = units.first {
                        $0.kind == .heading &&
                        PDFHeadingKeyDeriver.titleMatches(title: e.title, text: $0.text)
                    }?.id
                }
                guard let unitID = uid else { return nil }
                return StoredTOCEntry(title: e.title, plainTextOffset: e.plainTextOffset,
                                      unitID: unitID, playOrder: e.playOrder, level: e.level)
            }
        } else {
            // Legacy displayText path — pure-OCR / image-text docs that yield no
            // clean line stream. Heading promotion + TOC anchoring by offset.
            let baseUnits = ContentUnitBuilder.unitsFromPDFDisplayText(
                parsed.displayText, documentID: documentID)
            // Tolerate duplicate offsets (front-matter / repeated titles); never trap.
            let headingMarkersByOffset: [Int: ContentUnitBuilder.HeadingMarker] = Dictionary(
                parsed.tocEntries.map {
                    ($0.plainTextOffset, ContentUnitBuilder.HeadingMarker(level: $0.level, title: $0.title))
                },
                uniquingKeysWith: { first, _ in first })
            units = ContentUnitBuilder.applyHeadingMarkers(
                to: baseUnits,
                headingMarkersByOffset: headingMarkersByOffset,
                skipUnitID: ContentUnitBuilder.firstUnit(
                    in: baseUnits, atOrAfterPlainTextOffset: parsed.tocSkipUntilOffset)?.id)
            tocEntries = parsed.tocEntries.compactMap { e in
                guard let uid = ContentUnitBuilder.firstUnit(
                    in: units, atOrAfterPlainTextOffset: e.plainTextOffset)?.id else { return nil }
                return StoredTOCEntry(title: e.title, plainTextOffset: e.plainTextOffset,
                                      unitID: uid, playOrder: e.playOrder, level: e.level)
            }
        }

        // ── Sentences from prose-bearing units.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── Smart-skip: map the plainText skip offset to a unit (best-effort).
        let skipOffset = parsed.tocSkipUntilOffset
        let skipUnitID = ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: skipOffset)?.id
        let skipSource = skipOffset > 0 ? "heuristic" : ""

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
    /// `PDFEnhancementService`. Marks the doc enhancement-pending and
    /// hands it to the service queue; Tier 2/3 mutate the units directly
    /// (see the type-level doc above).
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
