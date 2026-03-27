import XCTest
@testable import Posey

@MainActor
final class ReaderViewModelTests: XCTestCase {
    func testRestorePrefersCharacterOffsetOverSentenceIndex() throws {
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

    func testSaveDraftNoteCreatesNoteForCurrentSentence() throws {
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
        viewModel.handleAppear()
        viewModel.noteDraft = "Track this sentence"

        viewModel.saveDraftNoteForCurrentSentence()

        XCTAssertEqual(viewModel.notes.count, 1)
        XCTAssertEqual(viewModel.notes.first?.kind, .note)
        XCTAssertEqual(viewModel.notes.first?.body, "Track this sentence")
        XCTAssertEqual(viewModel.noteDraft, "")
    }

    func testAddBookmarkCreatesBookmarkForCurrentSentence() throws {
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
        viewModel.handleAppear()

        viewModel.addBookmarkForCurrentSentence()

        XCTAssertEqual(viewModel.notes.count, 1)
        XCTAssertEqual(viewModel.notes.first?.kind, .bookmark)
        XCTAssertNil(viewModel.notes.first?.body)
    }

    func testJumpToNoteMovesReaderBackToAnchoredSentence() throws {
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

    func testMarkdownDocumentUsesDisplayBlocksAndPreservesListMarkers() throws {
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
        viewModel.handleAppear()

        XCTAssertTrue(viewModel.usesDisplayBlocks)
        XCTAssertEqual(viewModel.displayBlocks.first?.kind, .heading(level: 1))
        let numberedBlock = try XCTUnwrap(viewModel.displayBlocks.first(where: { $0.kind == .numbered }))
        XCTAssertEqual(viewModel.displayText(for: numberedBlock), "1. First numbered step keeps the sequence visible.")
    }

    func testPrepareForNotesEntryPausesPlaybackAndCapturesLookbackContext() async throws {
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

        viewModel.handleAppear()
        viewModel.togglePlayback()
        XCTAssertEqual(viewModel.playbackStateText, "playing")

        viewModel.prepareForNotesEntry()

        XCTAssertEqual(viewModel.playbackStateText, "paused")
        XCTAssertTrue(viewModel.noteDraft.contains(segments[0].text))
        XCTAssertTrue(viewModel.noteDraft.contains(secondSegment.text))
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

        viewModel.handleAppear()
        viewModel.togglePlayback()
        try await AsyncTestHelpers.waitUntil {
            await MainActor.run { viewModel.currentSentenceIndex > 0 }
        }

        viewModel.restartFromBeginning()

        XCTAssertEqual(viewModel.currentSentenceIndex, 0)
        XCTAssertEqual(viewModel.playbackStateText, "idle")
    }

    func testPDFDocumentUsesDisplayBlocksAndPreservesPageHeaders() throws {
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
        viewModel.handleAppear()

        XCTAssertTrue(viewModel.usesDisplayBlocks)
        XCTAssertEqual(viewModel.displayBlocks.first?.kind, .heading(level: 2))
        XCTAssertEqual(viewModel.displayBlocks.first?.text, "Page 1")
        XCTAssertTrue(viewModel.displayBlocks.contains(where: { $0.text.contains("Second page reminder: preserve context across page breaks.") }))
    }

    func testPDFMarkerNavigationUsesPageBlocks() throws {
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
}
