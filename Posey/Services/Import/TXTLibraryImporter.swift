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
    let embeddingIndex: DocumentEmbeddingIndex?
    private let textLoader = TXTDocumentImporter()

    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    func importDocument(from url: URL) throws -> Document {
        let plainText = try textLoader.loadText(from: url)
        return try importNormalizedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            plainText: plainText
        )
    }

    func importDocument(title: String, fileName: String, rawText: String, fileType: String = "txt") throws -> Document {
        let plainText = try textLoader.loadText(fromContents: rawText)
        return try importNormalizedDocument(
            title: title,
            fileName: fileName,
            fileType: fileType,
            plainText: plainText
        )
    }

    private func importNormalizedDocument(
        title: String,
        fileName: String,
        fileType: String,
        plainText: String
    ) throws -> Document {
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText
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
        let skipOffset = max(postCatalog, postTOC)
        let contentEndOffset = boundaries.contentEndOffset ?? 0
        let skipSource: String = {
            if gutenbergStart > 0 { return "gutenberg" }
            if skipOffset > 0   { return "heuristic" }
            return ""
        }()

        // ── Paragraph split → prose units.
        let units = Self.buildProseUnits(
            from: plainText,
            documentID: documentID
        )

        // ── Map smart-skip plainText offsets to unit ids.
        let skipUnitID = Self.firstUnit(in: units, atOrAfterPlainTextOffset: skipOffset)?.id
        let contentEndUnitID: UUID? = {
            guard contentEndOffset > 0 else { return nil }
            return Self.firstUnit(in: units, atOrAfterPlainTextOffset: contentEndOffset)?.id
        }()

        // ── Pre-compute sentences per unit.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── Persist atomically.
        let parsed = ParsedDocument(
            id: documentID,
            title: title,
            fileName: fileName,
            fileType: fileType,
            units: units,
            sentences: sentences,
            toc: [],
            skipUnitID: skipUnitID,
            skipSource: skipSource,
            contentEndUnitID: contentEndUnitID
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
            skipSource: skipSource
        )
        embeddingIndex?.enqueueIndexing(document)
        return document
    }

    // MARK: - Paragraph splitter

    /// Split normalized plainText into prose units along blank-line
    /// boundaries. Each non-empty paragraph becomes one `.prose`
    /// unit. Sequence numbers count by 10 (10, 20, 30, …) so future
    /// in-place edits can insert between units without renumbering.
    static func buildProseUnits(from plainText: String, documentID: UUID) -> [ContentUnit] {
        var units: [ContentUnit] = []
        var sequence = 10
        // Split on runs of two or more newlines. Single newlines
        // within a paragraph are common in source TXT (manual
        // line-wrap from old-school text files); the normalizer
        // already collapses excessive whitespace, but we leave
        // within-paragraph newlines intact for fidelity.
        let paragraphs = plainText.components(separatedBy: "\n\n")
        for rawParagraph in paragraphs {
            let trimmed = rawParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            units.append(ContentUnit(
                documentID: documentID,
                sequence: sequence,
                kind: .prose,
                text: trimmed
            ))
            sequence += 10
        }
        return units
    }

    /// Find the first unit whose original position in plainText is
    /// at or after `offset`. Used to map smart-skip detector output
    /// (a plainText character offset) onto a unit reference.
    ///
    /// Implementation: walks units in order, accumulating their
    /// original positions from the join the persister derives.
    /// (For TXT, the join character is `\n\n`, so cumulative
    /// position is `previousEnd + 2`.) This is approximate enough
    /// for smart-skip purposes (off by a few chars at most, always
    /// erring on the "after" side, which is what we want).
    static func firstUnit(in units: [ContentUnit], atOrAfterPlainTextOffset offset: Int) -> ContentUnit? {
        guard offset > 0 else { return units.first }
        var cumulative = 0
        for (i, unit) in units.enumerated() {
            if cumulative >= offset { return unit }
            cumulative += unit.text.count + 2  // +2 for the "\n\n" separator
            // If the skip lands inside this unit (between its start
            // and end), still prefer the *next* unit so we don't
            // read partial content.
            if cumulative > offset {
                let nextIndex = i + 1
                if units.indices.contains(nextIndex) {
                    return units[nextIndex]
                }
                return unit
            }
        }
        return units.last
    }
}

// ========== BLOCK 01: TXT LIBRARY IMPORTER (UNITS) - END ==========
