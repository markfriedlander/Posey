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
        let skipUnitID = ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: tocSkipOffset)?.id
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
