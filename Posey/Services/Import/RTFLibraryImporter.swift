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
    let embeddingIndex: DocumentEmbeddingIndex?
    private let textLoader = RTFDocumentImporter()

    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    func importDocument(from url: URL) throws -> Document {
        try FormatPrecheck.checkRTF(url: url)
        let parsed = try textLoader.loadDocument(from: url)
        return try importNormalizedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            plainText: parsed.plainText,
            headings: parsed.headings
        )
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "rtf") throws -> Document {
        let parsed = try textLoader.loadDocument(fromData: rawData)
        return try importNormalizedDocument(
            title: title,
            fileName: fileName,
            fileType: fileType,
            plainText: parsed.plainText,
            headings: parsed.headings
        )
    }

    private func importNormalizedDocument(
        title: String,
        fileName: String,
        fileType: String,
        plainText: String,
        headings: [RTFDocumentImporter.RTFHeadingEntry]
    ) throws -> Document {
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText
        )
        let documentID = existingDocument?.id ?? UUID()

        // ── Heading offset → level lookup for the unit builder.
        var levelByOffset: [Int: Int] = [:]
        for h in headings {
            levelByOffset[h.plainTextOffset] = max(levelByOffset[h.plainTextOffset] ?? 0, h.level)
        }

        // ── Build units (heading or prose) from plainText paragraphs.
        let units = Self.buildUnits(
            from: plainText,
            documentID: documentID,
            headingLevelByOffset: levelByOffset
        )

        // ── Smart-skip: same TOCSkipDetector pass, then map to unit.
        let tocSkipOffset = TOCSkipDetector.skipOffset(
            for: headings.map { (title: $0.title, plainTextOffset: $0.plainTextOffset) },
            in: plainText
        )
        let skipUnitID = Self.firstUnit(in: units, atOrAfterPlainTextOffset: tocSkipOffset)?.id
        let skipSource = tocSkipOffset > 0 ? "heuristic" : ""

        // ── Pre-compute sentences per unit.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── TOC entries from the headings (offsets stay in plainText
        // ── space; consistent with persistParsedDocument's join).
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
            skipSource: skipSource
        )
        embeddingIndex?.enqueueIndexing(document)
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

    /// Same offset-to-unit mapping helper TXT uses. Walks units in
    /// sequence order; picks the first whose cumulative position is
    /// at or after `offset`.
    static func firstUnit(in units: [ContentUnit], atOrAfterPlainTextOffset offset: Int) -> ContentUnit? {
        guard offset > 0 else { return units.first }
        var cumulative = 0
        for (i, unit) in units.enumerated() {
            if cumulative >= offset { return unit }
            cumulative += unit.text.count + 2
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

// ========== BLOCK 01: RTF LIBRARY IMPORTER (UNITS) - END ==========
