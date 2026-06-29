import Foundation

// ========== BLOCK 01: RTF LIBRARY IMPORTER (UNITS) - START ==========

/// Imports RTF files into the unit-based content model.
///
/// **What changed in the rebuild:** the importer now emits an ordered
/// list of `ContentUnit`s. Paragraphs are split on blank lines; each
/// paragraph becomes a `.prose` unit, except when its starting offset
/// matches a heading entry from `RTFDocumentImporter.parsed.headings`
/// — those become `.heading` units with the heading's level.
///
/// The existing `TOCSkipDetector` heuristic still runs against
/// `(title, plainTextOffset)` pairs to identify a TOC region worth
/// skipping; the offset result is mapped to a unit id via the same
/// `firstUnit(atOrAfterPlainTextOffset:)` helper TXT uses.
///
/// 2026-05-23 — rewritten as part of the architecture rebuild.
struct RTFLibraryImporter {
    let databaseManager: DatabaseManager
    private let textLoader = RTFDocumentImporter()

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func importDocument(from url: URL) throws -> Document {
        try FormatPrecheck.checkRTF(url: url)
        let parsed = try textLoader.loadDocument(from: url)
        let contentHash = try? ContentHasher.sha256(of: url)
        // Bundle 2a — clean title fallback.
        let title = TitleExtractor.cleanedFilename(url.lastPathComponent)
        return try importNormalizedDocument(
            title: title,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            plainText: parsed.plainText,
            displayText: parsed.displayText,
            images: parsed.images,
            headings: parsed.headings,
            contentHash: contentHash
        )
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "rtf") throws -> Document {
        let parsed = try textLoader.loadDocument(fromData: rawData)
        let contentHash = ContentHasher.sha256(rawData)
        let resolved = title.isEmpty ? TitleExtractor.cleanedFilename(fileName) : title
        return try importNormalizedDocument(
            title: resolved,
            fileName: fileName,
            fileType: fileType,
            plainText: parsed.plainText,
            displayText: parsed.displayText,
            images: parsed.images,
            headings: parsed.headings,
            contentHash: contentHash
        )
    }

    private func importNormalizedDocument(
        title: String,
        fileName: String,
        fileType: String,
        plainText: String,
        displayText: String,
        images: [PageImageRecord],
        headings: [RTFDocumentImporter.RTFHeadingEntry],
        contentHash: String?
    ) throws -> Document {
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText,
            contentHash: contentHash
        )
        let documentID = existingDocument?.id ?? UUID()

        // ── Build PROSE units from plainText paragraphs, then promote headings
        //    via the hardened shared ContentUnitBuilder.applyHeadingMarkers.
        //    2026-05-31 (ingestion audit, Bug C): RTF's own offset-only marking
        //    (buildUnits with a level-by-offset map, no TITLE validation)
        //    promoted whatever unit a font-size heading-offset landed in — which
        //    (a) FUSED the heading with the following body paragraph into one
        //    "heading" unit, and (b) turned font-size-false-positive body
        //    paragraphs into headings. The shared path validates the marker's
        //    TITLE against the unit text (whitespace-tolerant, exact-match-first):
        //    a marker whose title doesn't head a unit is DROPPED, and a fused
        //    "title + body" unit is styled by titleLength (title prefix only) —
        //    the same correctness Bug B gave EPUB/PDF/DOCX/HTML.
        //
        //    STEP 3 — category: ANY RTF whose headings come from the font-size
        //    detector. Verified on AI-Collab.rtf: 76→50 headings; the TOC-listing
        //    mash and the body-paragraph false-positives ("In writing this
        //    book…") drop to prose; fused "title↵body" units style only the
        //    title; legitimately long titles (this doc uses whole questions as
        //    section headings) survive. CAVEAT: the corpus has ONE RTF, so the
        //    fix is verified on it + reasoned for the category (it reuses the
        //    proven shared path). RESIDUAL: a heading still shares a unit with
        //    its following body (rendered correctly via titleLength, same as
        //    GEB's PDF dialogues) — physically SPLITTING the fusion needs RTF
        //    \par-normalization (separate, deeper, filed). Reader-facing
        //    rendering is correct; the data model is not yet one-unit-per-block.
        // 2026-06-09 (#2 RTF images) — when the RTF has embedded images,
        // `displayText` carries `[[POSEY_VISUAL_PAGE:…]]` markers; route it
        // through the SHARED VisualPlaceholderSplitter → block→unit path
        // (same as DOCX/EPUB/HTML) so images interleave as `.image` units.
        // When there are NO images the splitter returns no blocks and we keep
        // the EXACT existing RTF paragraph-split path — zero behavior change
        // for image-free RTFs (rtf_styled-headings / rtf_business-letter).
        let blocks = VisualPlaceholderSplitter.parse(displayText: displayText)
        let proseUnits: [ContentUnit] = blocks.isEmpty
            ? Self.buildUnits(from: plainText, documentID: documentID, headingLevelByOffset: [:])
            : ContentUnitBuilder.units(from: blocks, documentID: documentID)
        let headingMarkersByOffset = Dictionary(
            headings.map {
                ($0.plainTextOffset, ContentUnitBuilder.HeadingMarker(level: $0.level, title: $0.title))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let units = ContentUnitBuilder.applyHeadingMarkers(
            to: proseUnits,
            headingMarkersByOffset: headingMarkersByOffset
        )

        // ── Smart-skip: same TOCSkipDetector pass, then map to unit.
        let tocSkipOffset = TOCSkipDetector.skipOffset(
            for: headings.map { (title: $0.title, plainTextOffset: $0.plainTextOffset) },
            in: plainText
        )
        let skipUnitID = ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: tocSkipOffset)?.id
        let skipSource = tocSkipOffset > 0 ? "heuristic" : ""

        // ── Pre-compute sentences per unit.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── TOC entries from the headings. Resolve each heading's offset → its durable
        // paragraph identity (same ruler, at import); drop one that can't anchor (Position Rule).
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

        // 2026-06-09 (#2 RTF images) — persist extracted images to the
        // side-store the `.image` units' `metadata.imageID` references
        // (mirrors DOCXLibraryImporter). Replace-on-reimport: clear first.
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
            displayText: plainText,
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

    // MARK: - Paragraph splitter

    /// Split normalized plainText into prose / heading units. Each
    /// paragraph (blank-line separated) becomes one unit; the kind
    /// is `.heading` when the paragraph's starting offset matches a
    /// heading entry, otherwise `.prose`.
    static func buildUnits(
        from plainText: String,
        documentID: UUID,
        headingLevelByOffset: [Int: Int]
    ) -> [ContentUnit] {
        var units: [ContentUnit] = []
        var sequence = 10
        var cursor = 0
        let paragraphs = plainText.components(separatedBy: "\n\n")
        for rawParagraph in paragraphs {
            let paragraphStart = cursor
            let paragraphLength = rawParagraph.count
            cursor += paragraphLength + 2  // +2 for the "\n\n" separator
            let trimmed = rawParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Heading offset may sit at the trimmed paragraph start or
            // anywhere inside the leading whitespace; do a small range
            // check.
            let kind: ContentUnitKind
            let level: Int?
            if let matched = (paragraphStart...(paragraphStart + paragraphLength))
                .first(where: { headingLevelByOffset[$0] != nil }),
               let l = headingLevelByOffset[matched] {
                kind = .heading
                level = l
            } else {
                kind = .prose
                level = nil
            }
            units.append(ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: kind,
                text: trimmed,
                metadata: kind == .heading
                    ? ContentUnitMetadata(headingLevel: level)
                    : .empty
            ))
            sequence += 10
        }
        return units
    }

    // Offset-to-unit mapping is in `ContentUnitBuilder.firstUnit(...)`.
}

// ========== BLOCK 01: RTF LIBRARY IMPORTER (UNITS) - END ==========
