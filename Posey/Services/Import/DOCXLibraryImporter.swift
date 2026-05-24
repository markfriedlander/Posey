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
        return try importNormalizedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            images: parsed.images,
            headings: parsed.headings
        )
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "docx") throws -> Document {
        let parsed = try textLoader.loadDocument(fromData: rawData)
        return try importNormalizedDocument(
            title: title,
            fileName: fileName,
            fileType: fileType,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            images: parsed.images,
            headings: parsed.headings
        )
    }

    private func importNormalizedDocument(
        title: String,
        fileName: String,
        fileType: String,
        displayText: String,
        plainText: String,
        images: [PageImageRecord],
        headings: [DOCXDocumentImporter.DOCXHeadingEntry]
    ) throws -> Document {
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText
        )
        let documentID = existingDocument?.id ?? UUID()

        // ── Run the display parser at import time (was reader-open).
        let blocks = displayParser.parse(displayText: displayText)

        // ── Convert blocks to units. DOCXDisplayParser only emits
        // ── blocks when the doc has inline images; plain-paragraph
        // ── DOCXs fall back to plainText paragraph splitting.
        let units = ContentUnitBuilder.unitsPreferringBlocks(
            blocks: blocks,
            plainText: plainText,
            documentID: documentID
        )

        // ── Smart-skip: heading-based TOCSkipDetector.
        let tocSkipOffset = TOCSkipDetector.skipOffset(
            for: headings.map { (title: $0.title, plainTextOffset: $0.plainTextOffset) },
            in: plainText
        )
        let skipUnitID = ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: tocSkipOffset)?.id
        let skipSource = tocSkipOffset > 0 ? "heuristic" : ""

        // ── Sentences.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── TOC entries (same shape as before).
        let tocEntries: [StoredTOCEntry] = headings.enumerated().map { (idx, h) in
            StoredTOCEntry(
                title: h.title,
                plainTextOffset: h.plainTextOffset,
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
            contentEndUnitID: nil
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
            skipSource: skipSource
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
