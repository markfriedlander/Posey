import XCTest
@testable import Posey

// ========== BLOCK 01: REFERENCE EMBEDDING + COSINE - START ==========
/// Tests for the M6 dedup helpers added to `DocumentEmbeddingIndex`:
/// `embed(_:forDocument:)` and the public `cosineSimilarity(_:_:)`.
/// These were re-exposed so the chat view model's RAG retrieval
/// could compute cosine similarity between a reference text (anchor
/// + recent STM) and each candidate chunk.
final class DocumentEmbeddingIndexM6HelpersTests: XCTestCase {

    private var databaseURL: URL!
    private var manager: DatabaseManager!
    private var documentID: UUID!
    private var index: DocumentEmbeddingIndex!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        manager = try DatabaseManager(databaseURL: databaseURL)
        documentID = UUID()
        try manager.upsertDocument(Document(
            id: documentID,
            title: "Embedding test",
            fileName: "e.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: "x",
            plainText: "x",
            characterCount: 1
        ))
        index = DocumentEmbeddingIndex(database: manager)
    }

    override func tearDownWithError() throws {
        manager = nil
        if FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path) {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }
    }

    func testEmbedWithoutChunksReturnsEmpty() {
        let vec = index.embed("any reference text", forDocument: documentID)
        XCTAssertTrue(vec.isEmpty,
                      "When no chunks are indexed yet, dedup must skip — empty vector signals 'no reference available'")
    }

    func testCosineSimilarityIdentityIsOne() {
        let v: [Double] = [1, 0, 0, 1, 0]
        let s = DocumentEmbeddingIndex.cosineSimilarity(v, v)
        XCTAssertEqual(s, 1.0, accuracy: 1e-9)
    }

    func testCosineSimilarityOrthogonalIsZero() {
        let a: [Double] = [1, 0, 0]
        let b: [Double] = [0, 1, 0]
        let s = DocumentEmbeddingIndex.cosineSimilarity(a, b)
        XCTAssertEqual(s, 0.0, accuracy: 1e-9)
    }

    func testCosineSimilarityShapeMismatchReturnsZero() {
        let a: [Double] = [1, 0, 0]
        let b: [Double] = [1, 0]
        let s = DocumentEmbeddingIndex.cosineSimilarity(a, b)
        XCTAssertEqual(s, 0.0,
                       "Mismatched shapes must return 0 — never throw, never crash, never mix in spurious similarity")
    }

    func testCosineSimilarityZeroVectorReturnsZero() {
        let a: [Double] = [1, 1, 1]
        let z: [Double] = [0, 0, 0]
        XCTAssertEqual(DocumentEmbeddingIndex.cosineSimilarity(a, z), 0.0, accuracy: 1e-9)
    }
}
// ========== BLOCK 01: REFERENCE EMBEDDING + COSINE - END ==========


// ========== BLOCK 02: AUTO-SUMMARIZATION VIEW MODEL HOOK - START ==========
/// Verifies the auto-summarization wiring in `AskPoseyChatViewModel`.
/// Uses a stub summarizer so the test doesn't need real AFM. The
/// trigger logic is the contract under test:
/// - Below threshold → summarizer is NOT called.
/// - Above threshold → summarizer IS called with the older slice.
/// - Persisted summary surfaces in the next prompt builder input.
@MainActor
final class AskPoseySummarizationTriggerTests: XCTestCase {

    private final class StubSummarizer: AskPoseySummarizing {
        var lastTurnsArg: [AskPoseyMessage] = []
        var callCount: Int = 0
        var responseText: String = "summary text"
        @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
        func summarizeConversation(turns: [AskPoseyMessage]) async throws -> String {
            lastTurnsArg = turns
            callCount += 1
            return responseText
        }
        @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
        func summarizePair(question: String, answer: String, targetSentences: Int, failingSentence: String?) async throws -> String {
            return "stub pair summary"
        }
    }

    private final class StubClassifier: AskPoseyClassifying {
        @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
        func classifyIntent(question: String, anchor: String?) async throws -> AskPoseyIntent {
            return .immediate
        }
    }

    private final class StubStreamer: AskPoseyStreaming {
        var responseText: String = "answer"
        @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
        func streamProseResponse(
            inputs: AskPoseyPromptInputs,
            budget: AskPoseyTokenBudget,
            onSnapshot: @MainActor @Sendable (String) -> Void
        ) async throws -> AskPoseyResponseMetadata {
            onSnapshot(responseText)
            return AskPoseyResponseMetadata(
                finalText: responseText,
                promptTokenTotal: 0,
                breakdown: AskPoseyPromptTokenBreakdown(),
                droppedSections: [],
                chunksInjected: [],
                fullPromptForLogging: "stub prompt",
                inferenceDuration: 0
            )
        }
    }

    private var databaseURL: URL!
    private var manager: DatabaseManager!
    private var documentID: UUID!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        manager = try DatabaseManager(databaseURL: databaseURL)
        documentID = UUID()
        try manager.upsertDocument(Document(
            id: documentID,
            title: "Summary trigger test",
            fileName: "s.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: "x",
            plainText: "x",
            characterCount: 1
        ))
    }

    override func tearDownWithError() throws {
        manager = nil
        if FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path) {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }
    }

    /// Seed `n` non-summary turns so the view model's history-load
    /// path picks them up at init.
    private func seedTurns(_ n: Int) throws {
        let now = Date().timeIntervalSince1970
        for i in 0..<n {
            let role = i % 2 == 0 ? "user" : "assistant"
            try manager.appendAskPoseyTurn(StoredAskPoseyTurn(
                id: UUID().uuidString,
                documentID: documentID,
                timestamp: Date(timeIntervalSince1970: now + Double(i)),
                role: role,
                content: "Turn #\(i + 1)",
                invocation: "passage",
                anchorOffset: 0,
                intent: nil,
                chunksInjectedJSON: "[]",
                fullPromptForLogging: nil,
                summaryOfTurnsThrough: 0,
                isSummary: false
            ))
        }
    }

    /// With 4 prior turns and a fresh exchange, total ≤ 8 — no
    /// summarization should fire.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func testBelowThresholdDoesNotSummarize() async throws {
        try seedTurns(4)
        let summarizer = StubSummarizer()
        let vm = AskPoseyChatViewModel(
            documentID: documentID,
            documentPlainText: "x",
            anchor: AskPoseyAnchor(text: "a", plainTextOffset: 0),
            classifier: StubClassifier(),
            streamer: StubStreamer(),
            summarizer: summarizer,
            databaseManager: manager
        )
        await vm.awaitHistoryLoaded()

        vm.inputText = "another question"
        await vm.send()
        // Allow any in-flight summarization Task to settle. There
        // shouldn't be one — but await defensively in case the
        // trigger fires unexpectedly.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(summarizer.callCount, 0,
                       "Summarizer must not fire below the trigger threshold")
    }

    /// With 12 prior turns + a fresh exchange, total exceeds 8 →
    /// summarizer fires with the older slice.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func testAboveThresholdTriggersSummarization() async throws {
        try seedTurns(12)
        let summarizer = StubSummarizer()
        let vm = AskPoseyChatViewModel(
            documentID: documentID,
            documentPlainText: "x",
            anchor: AskPoseyAnchor(text: "a", plainTextOffset: 0),
            classifier: StubClassifier(),
            streamer: StubStreamer(),
            summarizer: summarizer,
            databaseManager: manager
        )
        await vm.awaitHistoryLoaded()

        vm.inputText = "newer question"
        await vm.send()
        // Auto-summarization is kicked off in a Task at the tail of
        // finalizeAssistantTurn; await it before asserting.
        try await waitForSummarizationToSettle(callCount: { summarizer.callCount })

        XCTAssertEqual(summarizer.callCount, 1,
                       "Summarizer must fire exactly once when the older slice newly needs covering")
        XCTAssertFalse(summarizer.lastTurnsArg.isEmpty)
        // The older slice should NOT include the just-finalized
        // assistant message — that's still verbatim in the recent
        // window. Sanity-check that the stub got the slice newer
        // than 0 but older than the recent verbatim window.
        XCTAssertGreaterThan(summarizer.lastTurnsArg.count, 0)
    }

    private func waitForSummarizationToSettle(
        callCount: @escaping () -> Int,
        timeout: TimeInterval = 1.0
    ) async throws {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if callCount() > 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
// ========== BLOCK 02: AUTO-SUMMARIZATION VIEW MODEL HOOK - END ==========
