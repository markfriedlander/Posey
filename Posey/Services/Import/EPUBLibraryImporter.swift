import Foundation

// ========== BLOCK 01: EPUB LIBRARY IMPORTER - START ==========

struct EPUBLibraryImporter {
    let databaseManager: DatabaseManager
    let embeddingIndex: DocumentEmbeddingIndex?
    private let importer = EPUBDocumentImporter()

    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    func importDocument(from url: URL) throws -> Document {
        // 2026-05-16 (B8) — Reject anything that isn't ZIP-shaped.
        try FormatPrecheck.checkEPUB(url: url)
        let parsed = try importer.loadDocument(from: url)
        let computed = Self.computeContentStartAndSource(
            existingSkip: parsed.playbackSkipUntilOffset,
            plainText: parsed.plainText,
            tocEntries: parsed.tocEntries
        )
        let boundaries = GutenbergBoundaryDetector.detect(in: parsed.plainText)
        let doc = try persistParsedDocument(
            title: parsed.title ?? url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            playbackSkipUntilOffset: computed.skipOffset,
            contentEndOffset: boundaries.contentEndOffset ?? 0,
            skipSource: computed.skipSource
        )
        try saveImages(parsed.images, for: doc.id)
        try saveTOC(parsed.tocEntries, for: doc.id)
        return doc
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "epub") throws -> Document {
        let parsed = try importer.loadDocument(fromData: rawData)
        let computed = Self.computeContentStartAndSource(
            existingSkip: parsed.playbackSkipUntilOffset,
            plainText: parsed.plainText,
            tocEntries: parsed.tocEntries
        )
        let boundaries = GutenbergBoundaryDetector.detect(in: parsed.plainText)
        let doc = try persistParsedDocument(
            title: parsed.title ?? title,
            fileName: fileName,
            fileType: fileType,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            playbackSkipUntilOffset: computed.skipOffset,
            contentEndOffset: boundaries.contentEndOffset ?? 0,
            skipSource: computed.skipSource
        )
        try saveImages(parsed.images, for: doc.id)
        try saveTOC(parsed.tocEntries, for: doc.id)
        return doc
    }

    /// Compose the four sources of skip-offset signal into a single
    /// content-start value:
    ///   1. Whatever the document-level importer already detected
    ///      (e.g. EPUBFrontMatterDetector for IA-style EPUBs).
    ///   2. The Gutenberg `*** START` marker, if present.
    ///   3. The in-prose "Contents" listing's body anchor, if present.
    ///   4. (2026-05-21 second pass) TOC-walk: classify each stored
    ///      TOC entry's title and skip past TITLE_BLOCK / PUBLISHING_INFO
    ///      entries to land at the first BODY_SECTION (Preface, Letter,
    ///      Chapter, Etymology, etc.). With prose-paragraph fallback
    ///      when the gap to the next body section is large and no
    ///      PUBLISHING_INFO entries were walked past (catches Pride's
    ///      Saintsbury Preface, which isn't in Pride's nav.xhtml).
    /// Each layer can only ADVANCE the skip; we never go backward.
    /// Result of `computeContentStartAndSource` — pair of the final
    /// skip offset and the classification of how it was reached.
    /// `skipSource` follows the locked 2026-05-21 rule:
    ///   • Gutenberg marker present → "gutenberg" (silent skip, no
    ///     prompt) even if downstream detectors advanced further within
    ///     Gutenberg territory.
    ///   • No Gutenberg marker but any heuristic detector advanced
    ///     the skip → "heuristic" (one-time prompt).
    ///   • No skip at all → "" (empty).
    struct ContentStartResult {
        let skipOffset: Int
        let skipSource: String
    }

    fileprivate static func computeContentStartAndSource(
        existingSkip: Int,
        plainText: String,
        tocEntries: [EPUBTOCEntry]
    ) -> ContentStartResult {
        let gutenbergStart = GutenbergBoundaryDetector.detect(in: plainText).contentStartOffset ?? 0
        let postGutenberg = max(existingSkip, gutenbergStart)
        let postTOC = InProseTOCDetector.endOfTOCRegion(in: plainText, after: postGutenberg) ?? postGutenberg
        let afterInProse = max(postGutenberg, postTOC)

        // Build TOC-walker input from the stored TOC. Sort by offset so
        // the walker sees entries in document order. (Persistence
        // order is play_order which generally matches offset order,
        // but defensively sort here.)
        let walkerEntries = tocEntries
            .map { TOCWalkContentStartDetector.TOCEntry(title: $0.title, plainTextOffset: $0.plainTextOffset) }
            .sorted { $0.plainTextOffset < $1.plainTextOffset }
        let walkResult = TOCWalkContentStartDetector.detect(
            tocEntries: walkerEntries,
            plainText: plainText,
            currentSkip: afterInProse
        )
        let finalSkip = max(afterInProse, walkResult.newSkipOffset ?? afterInProse)

        // 2026-05-21 classification — Gutenberg marker presence wins
        // for the whole skip (silent). Otherwise any forward motion
        // from a heuristic detector counts as "heuristic" (prompt).
        let source: String
        if gutenbergStart > 0 {
            source = "gutenberg"
        } else if finalSkip > 0 {
            source = "heuristic"
        } else {
            source = ""
        }
        return ContentStartResult(skipOffset: finalSkip, skipSource: source)
    }
}

// ========== BLOCK 01: EPUB LIBRARY IMPORTER - END ==========

// ========== BLOCK 02: EPUB LIBRARY IMPORTER - PERSISTENCE - START ==========

extension EPUBLibraryImporter {

    private func persistParsedDocument(
        title: String,
        fileName: String,
        fileType: String,
        displayText: String,
        plainText: String,
        playbackSkipUntilOffset: Int = 0,
        contentEndOffset: Int = 0,
        skipSource: String = ""
    ) throws -> Document {
        let now = Date()
        let existing = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText,
            displayText: displayText
        )

        let document = Document(
            id: existing?.id ?? UUID(),
            title: title,
            fileName: fileName,
            fileType: fileType,
            importedAt: existing?.importedAt ?? now,
            modifiedAt: now,
            displayText: displayText,
            plainText: plainText,
            characterCount: plainText.count,
            playbackSkipUntilOffset: playbackSkipUntilOffset,
            contentEndOffset: contentEndOffset,
            skipSource: skipSource
        )

        try databaseManager.upsertDocument(document)

        if existing == nil {
            try databaseManager.upsertReadingPosition(.initial(for: document.id))
        }

        // Ask Posey embedding index — best-effort (logs on failure).
        embeddingIndex?.enqueueIndexing(document)

        return document
    }

    /// Delete stale image records then insert the new set. Called after every
    /// import so reimports don't leave orphaned blobs under old image IDs.
    private func saveImages(_ images: [PageImageRecord], for documentID: UUID) throws {
        try databaseManager.deleteImages(for: documentID)
        for image in images {
            try databaseManager.insertImage(id: image.imageID, documentID: documentID, data: image.data)
        }
    }

    /// Persist TOC entries from a freshly parsed EPUB. Replaces any existing
    /// entries so reimports stay current.
    private func saveTOC(_ entries: [EPUBTOCEntry], for documentID: UUID) throws {
        let stored = entries.map {
            StoredTOCEntry(
                title: $0.title,
                plainTextOffset: $0.plainTextOffset,
                playOrder: $0.playOrder,
                level: $0.level
            )
        }
        try databaseManager.insertTOCEntries(stored, for: documentID)
    }
}

// ========== BLOCK 02: EPUB LIBRARY IMPORTER - PERSISTENCE - END ==========
