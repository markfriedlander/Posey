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
    let embeddingIndex: DocumentEmbeddingIndex?
    private let importer = MarkdownDocumentImporter()

    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    func importDocument(from url: URL) throws -> Document {
        try FormatPrecheck.checkTextLike(url: url, declaredType: "md")
        let parsed = try importer.loadDocument(from: url)
        return try importParsedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            parsed: parsed
        )
    }

    func importDocument(title: String, fileName: String, rawText: String, fileType: String = "md") throws -> Document {
        let parsed = try importer.loadDocument(fromContents: rawText)
        return try importParsedDocument(
            title: title,
            fileName: fileName,
            fileType: fileType,
            parsed: parsed
        )
    }

    private func importParsedDocument(
        title: String,
        fileName: String,
        fileType: String,
        parsed: ParsedMarkdownDocument
    ) throws -> Document {
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: parsed.plainText,
            displayText: parsed.displayText
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
            contentEndUnitID: nil
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
            characterCount: parsed.plainText.count
        )
        embeddingIndex?.enqueueIndexing(document)
        return document
    }

    // MARK: - Display block → ContentUnit mapping

    /// Convert `MarkdownParser`'s `DisplayBlock`s into `ContentUnit`s.
    /// The block kind → unit kind mapping is one-to-one for the
    /// kinds Markdown produces.
    static func buildUnits(from blocks: [DisplayBlock], documentID: UUID) -> [ContentUnit] {
        var units: [ContentUnit] = []
        var sequence = 10
        for block in blocks {
            let unit = self.unit(from: block, documentID: documentID, sequence: sequence)
            units.append(unit)
            sequence += 10
        }
        return units
    }

    private static func unit(from block: DisplayBlock, documentID: UUID, sequence: Int) -> ContentUnit {
        switch block.kind {
        case .heading(let level):
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .heading,
                text: block.text,
                metadata: ContentUnitMetadata(headingLevel: level)
            )
        case .paragraph:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .prose,
                text: block.text
            )
        case .bullet:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .listItem,
                text: block.text,
                metadata: ContentUnitMetadata(listMarker: block.displayPrefix ?? "• ")
            )
        case .numbered:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .listItem,
                text: block.text,
                metadata: ContentUnitMetadata(listMarker: block.displayPrefix ?? "1. ")
            )
        case .quote:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .blockquote,
                text: block.text
            )
        case .horizontalRule:
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .horizontalRule,
                text: ""
            )
        case .visualPlaceholder:
            // MD doesn't natively produce these, but the type allows
            // it. Render as an image-kind unit; the image data will
            // be missing so it renders as the placeholder bar.
            return ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .image,
                text: block.text,
                metadata: ContentUnitMetadata(imageID: block.imageID)
            )
        }
    }
}

// ========== BLOCK 01: MD LIBRARY IMPORTER (UNITS) - END ==========
