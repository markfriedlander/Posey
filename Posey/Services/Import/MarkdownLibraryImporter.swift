import Foundation

// ========== BLOCK 01: MD LIBRARY IMPORTER (UNITS) - START ==========

/// Imports Markdown files into the unit-based content model.
///
/// **What changed in the rebuild:** the importer now emits a list of
/// `ContentUnit`s derived from the existing `MarkdownParser`'s
/// `DisplayBlock` output. The parser already does the structural
/// work (detecting headings, bullets, numbered lists, blockquotes,
/// horizontal rules); the importer just re-shapes each block into
/// the corresponding `ContentUnitKind` + metadata.
///
/// `SentenceIndexer` pre-computes sentences per unit at import time,
/// so the reader's open path is sub-second on any MD doc regardless
/// of size.
///
/// 2026-05-23 — rewritten as part of the architecture rebuild.
struct MarkdownLibraryImporter {
    let databaseManager: DatabaseManager
    private let importer = MarkdownDocumentImporter()

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func importDocument(from url: URL) throws -> Document {
        try FormatPrecheck.checkTextLike(url: url, declaredType: "md")
        let parsed = try importer.loadDocument(from: url)
        // **Bundle 2a (2026-05-26)** — feed RAW markdown bytes to
        // the extractor so the `# Heading` syntax is still visible.
        // `parsed.plainText` has already stripped the `#` markers.
        let raw = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            ?? parsed.plainText
        let derived = TitleExtractor.fromMarkdown(plainText: raw)
        let title = TitleExtractor.resolve(
            contentTitle: derived,
            filename: url.lastPathComponent
        )
        let contentHash = try? ContentHasher.sha256(of: url)
        return try importParsedDocument(
            title: title,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            parsed: parsed,
            contentHash: contentHash
        )
    }

    func importDocument(title: String, fileName: String, rawText: String, fileType: String = "md") throws -> Document {
        let parsed = try importer.loadDocument(fromContents: rawText)
        let derived = TitleExtractor.fromMarkdown(plainText: rawText)
        let resolved = title.isEmpty
            ? TitleExtractor.resolve(contentTitle: derived, filename: fileName)
            : title
        let contentHash = ContentHasher.sha256(Data(rawText.utf8))
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
        parsed: ParsedMarkdownDocument,
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

        // ── Build units from MarkdownParser's display blocks.
        let units = ContentUnitBuilder.units(from: parsed.blocks, documentID: documentID)

        // ── Pre-compute sentences per unit.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── TOC: same heading-block extraction the legacy importer
        // ── used. Offsets stay in the parser's plainText coordinate
        // ── space, which matches the persister's join scheme as long
        // ── as we kept block text bit-identical (we did).
        let tocEntries: [StoredTOCEntry] = parsed.blocks.enumerated().compactMap { (idx, block) in
            guard case .heading(let level) = block.kind else { return nil }
            return StoredTOCEntry(
                title: block.text,
                plainTextOffset: block.startOffset,
                playOrder: idx + 1,
                level: level
            )
        }

        // ── MD has no built-in smart-skip detector today; the
        // ── importer doesn't introduce one in the rebuild. Open at
        // ── unit 0.
        let parsedDoc = ParsedDocument(
            id: documentID,
            title: title,
            fileName: fileName,
            fileType: fileType,
            units: units,
            sentences: sentences,
            toc: tocEntries,
            skipUnitID: nil,
            skipSource: "",
            playbackSkipUntilOffset: 0,
            contentEndOffset: 0,
            contentEndUnitID: nil,
            contentHash: contentHash,
            editionLabel: nil
        )
        try databaseManager.persistParsedDocument(parsedDoc)

        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: documentID))
        }

        // Legacy embedding index still consumes documents.plain_text
        // during the rollout.
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
            playbackSkipUntilOffset: 0,
            contentEndOffset: 0,
            skipSource: "",
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

    // Display block → ContentUnit mapping lives in
    // `ContentUnitBuilder.units(from:documentID:)`.
}

// ========== BLOCK 01: MD LIBRARY IMPORTER (UNITS) - END ==========
