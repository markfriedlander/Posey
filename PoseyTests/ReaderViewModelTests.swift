import XCTest
@testable import Posey

@MainActor
final class ReaderViewModelTests: XCTestCase {
    func testRestorePrefersCharacterOffsetOverSentenceIndex() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let text = try TestFixtureLoader.string(named: "ShortSample")
        let document = Document(
            id: UUID(),
            title: "ShortSample",
            fileName: "ShortSample.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: text,
            plainText: text,
            characterCount: text.count
        )
        try manager.upsertDocument(document)

        let segments = SentenceSegmenter().segments(for: text)
        let secondSegment = try XCTUnwrap(segments.dropFirst().first)
        try manager.upsertReadingPosition(
            ReadingPosition(
                documentID: document.id,
                updatedAt: .now,
                characterOffset: secondSegment.startOffset,
                sentenceIndex: 0
            )
        )

        let viewModel = ReaderViewModel(
            document: document,
            databaseManager: manager,
            playbackService: SpeechPlaybackService(mode: .simulated(stepInterval: 0.01))
        )

        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()

        XCTAssertEqual(viewModel.currentSentenceIndex, 1)
    }

    func testSimulatedPlaybackAdvancesAndCanPauseResume() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let text = try TestFixtureLoader.string(named: "LongDenseSample")
        let document = Document(
            id: UUID(),
            title: "LongDenseSample",
            fileName: "LongDenseSample.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: text,
            plainText: text,
            characterCount: text.count
        )
        try manager.upsertDocument(document)
        try manager.upsertReadingPosition(.initial(for: document.id))

        let viewModel = ReaderViewModel(
            document: document,
            databaseManager: manager,
            playbackService: SpeechPlaybackService(mode: .simulated(stepInterval: 0.2))
        )

        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()
        viewModel.togglePlayback()
        try await AsyncTestHelpers.waitUntil {
            await MainActor.run { viewModel.currentSentenceIndex > 0 }
        }
        XCTAssertEqual(viewModel.playbackStateText, "playing")

        let advancedIndex = viewModel.currentSentenceIndex
        viewModel.togglePlayback()
        XCTAssertEqual(viewModel.playbackStateText, "paused")

        viewModel.togglePlayback()
        try await AsyncTestHelpers.waitUntil {
            await MainActor.run { viewModel.currentSentenceIndex > advancedIndex }
        }
        XCTAssertEqual(viewModel.playbackStateText, "playing")
    }

    func testSaveDraftNoteCreatesNoteForCurrentSentence() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let text = try TestFixtureLoader.string(named: "ShortSample")
        let document = Document(
            id: UUID(),
            title: "ShortSample",
            fileName: "ShortSample.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: text,
            plainText: text,
            characterCount: text.count
        )
        try manager.upsertDocument(document)
        try manager.upsertReadingPosition(.initial(for: document.id))

        let viewModel = ReaderViewModel(document: document, databaseManager: manager)
        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()
        viewModel.noteDraft = "Track this sentence"

        viewModel.saveDraftNoteForCurrentSentence()

        XCTAssertEqual(viewModel.notes.count, 1)
        XCTAssertEqual(viewModel.notes.first?.kind, .note)
        XCTAssertEqual(viewModel.notes.first?.body, "Track this sentence")
        XCTAssertEqual(viewModel.noteDraft, "")
    }

    func testAddBookmarkCreatesBookmarkForCurrentSentence() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let text = try TestFixtureLoader.string(named: "ShortSample")
        let document = Document(
            id: UUID(),
            title: "ShortSample",
            fileName: "ShortSample.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: text,
            plainText: text,
            characterCount: text.count
        )
        try manager.upsertDocument(document)
        try manager.upsertReadingPosition(.initial(for: document.id))

        let viewModel = ReaderViewModel(document: document, databaseManager: manager)
        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()

        viewModel.addBookmarkForCurrentSentence()

        XCTAssertEqual(viewModel.notes.count, 1)
        XCTAssertEqual(viewModel.notes.first?.kind, .bookmark)
        XCTAssertNil(viewModel.notes.first?.body)
    }

    func testJumpToNoteMovesReaderBackToAnchoredSentence() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let text = try TestFixtureLoader.string(named: "ShortSample")
        let document = Document(
            id: UUID(),
            title: "ShortSample",
            fileName: "ShortSample.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: text,
            plainText: text,
            characterCount: text.count
        )
        try manager.upsertDocument(document)
        try manager.upsertReadingPosition(.initial(for: document.id))

        let viewModel = ReaderViewModel(document: document, databaseManager: manager)
        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()

        viewModel.noteDraft = "Return here"
        viewModel.saveDraftNoteForCurrentSentence()

        try manager.upsertReadingPosition(
            ReadingPosition(
                documentID: document.id,
                updatedAt: .now,
                characterOffset: 999,
                sentenceIndex: 999
            )
        )

        let note = try XCTUnwrap(viewModel.notes.first)
        viewModel.jump(to: note)

        XCTAssertEqual(viewModel.currentSentenceIndex, 0)
    }

    func testMarkdownDocumentUsesDisplayBlocksAndPreservesListMarkers() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let parsed = try MarkdownDocumentImporter().loadDocument(
            from: TestFixtureLoader.url(named: "StructuredSample", fileExtension: "md")
        )
        let document = Document(
            id: UUID(),
            title: "StructuredSample",
            fileName: "StructuredSample.md",
            fileType: "md",
            importedAt: .now,
            modifiedAt: .now,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            characterCount: parsed.plainText.count
        )
        try manager.upsertDocument(document)

        let viewModel = ReaderViewModel(document: document, databaseManager: manager)
        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()

        XCTAssertTrue(viewModel.usesDisplayBlocks)
        XCTAssertEqual(viewModel.displayBlocks.first?.kind, .heading(level: 1))
        let numberedBlock = try XCTUnwrap(viewModel.displayBlocks.first(where: { $0.kind == .numbered }))
        XCTAssertEqual(viewModel.displayText(for: numberedBlock), "1. First numbered step keeps the sequence visible.")
    }

    func testPrepareForNotesEntryPausesPlaybackAndLeavesDraftEmpty() async throws {
        // Behavior change 2026-05-01 (Mark's M4 device pass): the
        // notes draft used to be auto-populated with surrounding-
        // sentence text, but on documents whose first "sentence"
        // jammed title/date/heading together (typical for OCR'd
        // PDFs and some EPUBs) the draft looked like garbage. The
        // active sentence is already shown above the TextField as
        // readonly context — so we clear the draft on entry and
        // let the user start typing in a clean field. The
        // surrounding-sentence capture still goes to the
        // clipboard so the share-with-other-app path keeps
        // working.
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let text = try TestFixtureLoader.string(named: "ShortSample")
        let document = Document(
            id: UUID(),
            title: "ShortSample",
            fileName: "ShortSample.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: text,
            plainText: text,
            characterCount: text.count
        )
        try manager.upsertDocument(document)

        let segments = SentenceSegmenter().segments(for: text)
        let secondSegment = try XCTUnwrap(segments.dropFirst().first)
        try manager.upsertReadingPosition(
            ReadingPosition(
                documentID: document.id,
                updatedAt: .now,
                characterOffset: secondSegment.startOffset,
                sentenceIndex: secondSegment.id
            )
        )

        let viewModel = ReaderViewModel(
            document: document,
            databaseManager: manager,
            playbackService: SpeechPlaybackService(mode: .simulated(stepInterval: 0.2))
        )

        // Pre-seed a stale draft to confirm the entry path clears it.
        viewModel.noteDraft = "stale text from a previous entry"

        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()
        viewModel.togglePlayback()
        XCTAssertEqual(viewModel.playbackStateText, "playing")

        viewModel.prepareForNotesEntry()

        XCTAssertEqual(viewModel.playbackStateText, "paused")
        XCTAssertEqual(viewModel.noteDraft, "",
                       "Notes draft should be empty so the user starts with a clean field")
    }

    func testRestartFromBeginningStopsPlaybackAndRewindsWithoutAutoplay() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let text = try TestFixtureLoader.string(named: "LongDenseSample")
        let document = Document(
            id: UUID(),
            title: "LongDenseSample",
            fileName: "LongDenseSample.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: text,
            plainText: text,
            characterCount: text.count
        )
        try manager.upsertDocument(document)
        try manager.upsertReadingPosition(.initial(for: document.id))

        let viewModel = ReaderViewModel(
            document: document,
            databaseManager: manager,
            playbackService: SpeechPlaybackService(mode: .simulated(stepInterval: 0.2))
        )

        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()
        viewModel.togglePlayback()
        try await AsyncTestHelpers.waitUntil {
            await MainActor.run { viewModel.currentSentenceIndex > 0 }
        }

        viewModel.restartFromBeginning()

        XCTAssertEqual(viewModel.currentSentenceIndex, 0)
        XCTAssertEqual(viewModel.playbackStateText, "idle")
    }

    func testPDFDocumentUsesDisplayBlocksWithoutPageHeadings() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let parsed = try PDFDocumentImporter().loadDocument(
            from: TestFixtureLoader.url(named: "StructuredSample", fileExtension: "pdf")
        )
        let document = Document(
            id: UUID(),
            title: parsed.title ?? "StructuredSample",
            fileName: "StructuredSample.pdf",
            fileType: "pdf",
            importedAt: .now,
            modifiedAt: .now,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            characterCount: parsed.plainText.count
        )
        try manager.upsertDocument(document)

        let viewModel = ReaderViewModel(document: document, databaseManager: manager)
        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()

        XCTAssertTrue(viewModel.usesDisplayBlocks)
        // No "Page N" chrome should appear in the display flow.
        XCTAssertFalse(viewModel.displayBlocks.contains(where: { block in
            if case .heading = block.kind, block.text.hasPrefix("Page ") { return true }
            return false
        }))
        XCTAssertFalse(viewModel.displayBlocks.contains(where: { $0.text == "Page 1" }))
        // Body text from later pages is still preserved.
        XCTAssertTrue(viewModel.displayBlocks.contains(where: { $0.text.contains("Second page reminder: preserve context across page breaks.") }))
    }

    func testPDFMarkerNavigationUsesPageBlocks() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let parsed = try PDFDocumentImporter().loadDocument(
            from: TestFixtureLoader.url(named: "StructuredSample", fileExtension: "pdf")
        )
        let document = Document(
            id: UUID(),
            title: parsed.title ?? "StructuredSample",
            fileName: "StructuredSample.pdf",
            fileType: "pdf",
            importedAt: .now,
            modifiedAt: .now,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            characterCount: parsed.plainText.count
        )
        try manager.upsertDocument(document)

        let viewModel = ReaderViewModel(document: document, databaseManager: manager)
        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()
        viewModel.goToNextMarker()

        XCTAssertGreaterThan(viewModel.currentSentenceIndex, 0)

        viewModel.goToPreviousMarker()
        XCTAssertEqual(viewModel.currentSentenceIndex, 0)
    }

    func testPDFVisualPlaceholderPausesPlaybackAtVisualBoundary() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)
        let plainText = "Page one stays readable. Page three resumes after the visual pause."
        let displayText = [
            "Page one stays readable.",
            PDFDocumentImporter.visualPageMarker(for: 2, imageID: "test-image-id"),
            "Page three resumes after the visual pause."
        ].joined(separator: "\u{000C}")
        let document = Document(
            id: UUID(),
            title: "VisualPDF",
            fileName: "VisualPDF.pdf",
            fileType: "pdf",
            importedAt: .now,
            modifiedAt: .now,
            displayText: displayText,
            plainText: plainText,
            characterCount: plainText.count
        )
        try manager.upsertDocument(document)

        let viewModel = ReaderViewModel(
            document: document,
            databaseManager: manager,
            playbackService: SpeechPlaybackService(mode: .simulated(stepInterval: 0.2))
        )

        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()
        viewModel.togglePlayback()

        try await AsyncTestHelpers.waitUntil {
            await MainActor.run {
                viewModel.playbackStateText == "paused" && viewModel.focusedDisplayBlockID != nil
            }
        }

        XCTAssertEqual(viewModel.currentSentenceIndex, 1)
        XCTAssertEqual(viewModel.displayBlocks.first(where: { $0.id == viewModel.focusedDisplayBlockID })?.kind, .visualPlaceholder)
    }

    /// `playbackSkipUntilOffset` is set by the PDF importer (and any future
    /// importer that detects a TOC). It must completely hide the skipped
    /// region from the reader: not in segments, not in displayBlocks, not
    /// reachable by playback or scroll, not searchable, and rewind/restart
    /// must land on the first body sentence — never inside the skipped
    /// region.
    func testPlaybackSkipRegionIsHiddenFromReader() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let manager = try DatabaseManager(databaseURL: databaseURL)

        // Synthetic doc: a TOC-shaped block followed by body prose.
        let toc = "Table of Contents I. Intro 1 II. Body 5 III. End 9"
        let body = "The first body sentence. The second body sentence. The third body sentence."
        let plain = toc + "\n\n" + body
        let skipUntil = (toc + "\n\n").count

        let document = Document(
            id: UUID(),
            title: "TOCDoc",
            fileName: "TOCDoc.pdf",
            fileType: "pdf",
            importedAt: .now,
            modifiedAt: .now,
            displayText: plain,
            plainText: plain,
            characterCount: plain.count,
            playbackSkipUntilOffset: skipUntil
        )
        try manager.upsertDocument(document)

        let viewModel = ReaderViewModel(document: document, databaseManager: manager)
        await viewModel.awaitContentLoaded()

        // No segment may begin inside the TOC region.
        for segment in viewModel.segments {
            XCTAssertGreaterThanOrEqual(segment.startOffset, skipUntil,
                                        "segment \(segment.id) at offset \(segment.startOffset) is inside the skip region")
        }

        // First segment is the first BODY sentence.
        let firstSegmentText = viewModel.segments.first?.text ?? ""
        XCTAssertTrue(firstSegmentText.contains("first body sentence"),
                      "first segment should be the first body sentence; got \(firstSegmentText)")

        // Restart-from-beginning lands on the first body sentence (index 0
        // after the filter), not inside the TOC.
        await viewModel.awaitContentLoaded()
        viewModel.handleAppear()
        viewModel.restartFromBeginning()
        XCTAssertEqual(viewModel.currentSentenceIndex, 0)
        XCTAssertTrue(viewModel.segments[viewModel.currentSentenceIndex].text.contains("first body sentence"))

        // A saved position INSIDE the skip region is migrated to the first
        // body sentence rather than restored verbatim.
        try manager.upsertReadingPosition(
            ReadingPosition(documentID: document.id, updatedAt: .now,
                            characterOffset: 5, sentenceIndex: 0)
        )
        let migrated = ReaderViewModel(document: document, databaseManager: manager)
        await migrated.awaitContentLoaded()
        migrated.handleAppear()
        XCTAssertEqual(migrated.currentSentenceIndex, 0)
        XCTAssertTrue(migrated.segments[migrated.currentSentenceIndex].text.contains("first body sentence"))

        // Search cannot match TOC text.
        viewModel.updateSearchQuery("Intro")
        XCTAssertTrue(viewModel.searchMatchIndices.isEmpty,
                      "search should not find 'Intro' inside the hidden TOC region")
    }
}
