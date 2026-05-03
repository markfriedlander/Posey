import XCTest
@testable import Posey

// ========== BLOCK 01: CRUD ROUND-TRIP - START ==========
/// Round-trip tests for the M5 Ask Posey conversation CRUD helpers
/// added to DatabaseManager (BLOCK 05D). Each test inserts a known
/// state, reads it back, and asserts the read matches.
final class AskPoseyConversationsCRUDTests: XCTestCase {

    private var databaseURL: URL!
    private var manager: DatabaseManager!
    private var documentID: UUID!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        manager = try DatabaseManager(databaseURL: databaseURL)
        documentID = UUID()
        // Real document row so the FK constraint is satisfied.
        try manager.upsertDocument(Document(
            id: documentID,
            title: "Test",
            fileName: "t.txt",
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

    func testEmptyTableReturnsZeroCount() throws {
        XCTAssertEqual(try manager.askPoseyTurnCount(for: documentID), 0)
        XCTAssertTrue(try manager.askPoseyTurns(for: documentID).isEmpty)
    }

    func testRoundtripSingleUserTurn() throws {
        let turn = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            role: "user",
            content: "What does this passage mean?",
            invocation: "passage",
            anchorOffset: 1234,
            intent: "immediate",
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        try manager.appendAskPoseyTurn(turn)

        XCTAssertEqual(try manager.askPoseyTurnCount(for: documentID), 1)
        let turns = try manager.askPoseyTurns(for: documentID)
        XCTAssertEqual(turns.count, 1)
        let read = try XCTUnwrap(turns.first)
        XCTAssertEqual(read.role, "user")
        XCTAssertEqual(read.content, "What does this passage mean?")
        XCTAssertEqual(read.intent, "immediate")
        XCTAssertEqual(read.anchorOffset, 1234)
        XCTAssertEqual(read.invocation, "passage")
        XCTAssertEqual(read.chunksInjectedJSON, "[]")
        XCTAssertNil(read.fullPromptForLogging)
        XCTAssertFalse(read.isSummary)
    }

    func testRoundtripAssistantTurnWithFullMetadata() throws {
        let turn = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            role: "assistant",
            content: "The passage suggests…",
            invocation: "passage",
            anchorOffset: 1234,
            intent: nil,
            chunksInjectedJSON: #"[{"chunkID":7,"startOffset":4096,"text":"snip","relevance":0.91}]"#,
            fullPromptForLogging: "PROMPT BODY OBSERVED BY THE MODEL",
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        try manager.appendAskPoseyTurn(turn)

        let read = try XCTUnwrap(try manager.askPoseyTurns(for: documentID).first)
        XCTAssertEqual(read.role, "assistant")
        XCTAssertNil(read.intent)
        XCTAssertEqual(read.fullPromptForLogging, "PROMPT BODY OBSERVED BY THE MODEL")
        XCTAssertTrue(read.chunksInjectedJSON.contains("\"chunkID\":7"))
    }

    func testTurnsReturnedOldestFirst() throws {
        // Insert in reverse-chronological order; helpers should still
        // return chronological.
        let now = Date().timeIntervalSince1970
        for offset in stride(from: 5, through: 0, by: -1) {
            let turn = StoredAskPoseyTurn(
                id: UUID().uuidString,
                documentID: documentID,
                timestamp: Date(timeIntervalSince1970: now - Double(offset)),
                role: "user",
                content: "Turn at offset \(offset)",
                invocation: "passage",
                anchorOffset: 0,
                intent: nil,
                chunksInjectedJSON: "[]",
                fullPromptForLogging: nil,
                summaryOfTurnsThrough: 0,
                isSummary: false
            )
            try manager.appendAskPoseyTurn(turn)
        }
        let turns = try manager.askPoseyTurns(for: documentID)
        XCTAssertEqual(turns.count, 6)
        // Oldest first: offset 5 came first chronologically because we
        // subtracted 5 from `now`. The helper should return that as turn[0].
        XCTAssertEqual(turns.first?.content, "Turn at offset 5")
        XCTAssertEqual(turns.last?.content, "Turn at offset 0")
    }

    func testLimitCapsToMostRecentRowsButReturnsChronological() throws {
        let baseTime = Date().timeIntervalSince1970
        for i in 1...10 {
            let turn = StoredAskPoseyTurn(
                id: UUID().uuidString,
                documentID: documentID,
                timestamp: Date(timeIntervalSince1970: baseTime + Double(i)),
                role: i % 2 == 1 ? "user" : "assistant",
                content: "Turn #\(i)",
                invocation: "passage",
                anchorOffset: 0,
                intent: nil,
                chunksInjectedJSON: "[]",
                fullPromptForLogging: nil,
                summaryOfTurnsThrough: 0,
                isSummary: false
            )
            try manager.appendAskPoseyTurn(turn)
        }
        // Limit 4 should give us turns 7..10 (the most recent), still
        // ordered ASC.
        let recent = try manager.askPoseyTurns(for: documentID, limit: 4)
        XCTAssertEqual(recent.count, 4)
        XCTAssertEqual(recent.map(\.content), ["Turn #7", "Turn #8", "Turn #9", "Turn #10"])
    }

    func testSummaryRowsExcludedFromTurnsAndIncludedInLatestSummary() throws {
        // One real user turn.
        let real = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            role: "user",
            content: "Real question",
            invocation: "passage",
            anchorOffset: 0,
            intent: nil,
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        try manager.appendAskPoseyTurn(real)
        // One summary row.
        let summary = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_500),
            role: "assistant",
            content: "Earlier summary text",
            invocation: "passage",
            anchorOffset: nil,
            intent: nil,
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 8,
            isSummary: true
        )
        try manager.appendAskPoseyTurn(summary)

        let nonSummary = try manager.askPoseyTurns(for: documentID)
        XCTAssertEqual(nonSummary.count, 1, "Summary rows should be excluded from askPoseyTurns")
        XCTAssertEqual(nonSummary.first?.content, "Real question")

        let latestSummary = try manager.askPoseyLatestSummary(for: documentID)
        XCTAssertNotNil(latestSummary)
        XCTAssertEqual(latestSummary?.summaryOfTurnsThrough, 8)
        XCTAssertEqual(latestSummary?.isSummary, true)
        XCTAssertEqual(latestSummary?.content, "Earlier summary text")
    }
}
// ========== BLOCK 01: CRUD ROUND-TRIP - END ==========


// ========== BLOCK 02: CHAT VIEW MODEL - START ==========
/// Tests for `AskPoseyChatViewModel` history loading. The view model
/// is the bridge between SQLite and the UI; these tests verify it
/// reaches into `ask_posey_conversations` correctly on init and
/// translates rows to the in-memory message type.
@MainActor
final class AskPoseyChatViewModelHistoryTests: XCTestCase {

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
            title: "Test",
            fileName: "t.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: "Two roads diverged in a yellow wood.",
            plainText: "Two roads diverged in a yellow wood.",
            characterCount: 36
        ))
    }

    override func tearDownWithError() throws {
        manager = nil
        if FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path) {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }
    }

    func testFreshDocumentStartsWithAnchorMarker() async throws {
        let vm = AskPoseyChatViewModel(
            documentID: documentID,
            documentPlainText: "Two roads diverged in a yellow wood.",
            anchor: AskPoseyAnchor(text: "Two roads diverged in a yellow wood.", plainTextOffset: 0),
            databaseManager: manager
        )
        await vm.awaitHistoryLoaded()
        // Fresh document: only the just-appended anchor marker for
        // this invocation should be in messages.
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.role, .anchor)
        XCTAssertEqual(vm.messages.first?.anchorScope, "passage")
        XCTAssertEqual(vm.messages.first?.anchorOffset, 0)
        XCTAssertFalse(vm.isLoadingHistory)

        // And the marker is persisted so it'll surface in Saved
        // Annotations and on the next sheet open.
        let stored = try manager.askPoseyAnchorRows(for: documentID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.role, "anchor")
    }

    func testReturningDocumentLoadsPriorTurns() async throws {
        // Seed two prior turns directly via DatabaseManager.
        let now = Date().timeIntervalSince1970
        let userTurn = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(timeIntervalSince1970: now),
            role: "user",
            content: "What does this poem mean?",
            invocation: "passage",
            anchorOffset: 0,
            intent: "immediate",
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        try manager.appendAskPoseyTurn(userTurn)
        let asstTurn = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(timeIntervalSince1970: now + 1),
            role: "assistant",
            content: "The traveler is reflecting on choice.",
            invocation: "passage",
            anchorOffset: 0,
            intent: nil,
            chunksInjectedJSON: "[]",
            fullPromptForLogging: "FULL PROMPT",
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        try manager.appendAskPoseyTurn(asstTurn)

        let vm = AskPoseyChatViewModel(
            documentID: documentID,
            documentPlainText: "Two roads diverged in a yellow wood.",
            anchor: AskPoseyAnchor(text: "Two roads diverged in a yellow wood.", plainTextOffset: 0),
            databaseManager: manager
        )
        await vm.awaitHistoryLoaded()

        // Two prior turns + one fresh anchor marker for this invocation.
        XCTAssertEqual(vm.messages.count, 3)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].content, "What does this poem mean?")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[1].content, "The traveler is reflecting on choice.")
        // The freshly-appended anchor marker for the current invocation
        // lands at the end so the user sees their new question's
        // context below the prior conversation when they scroll.
        XCTAssertEqual(vm.messages[2].role, .anchor)
        XCTAssertEqual(vm.messages[2].anchorScope, "passage")
        XCTAssertEqual(vm.messages[2].anchorOffset, 0)
    }

    func testHistoryIsScopedToCorrectDocument() async throws {
        // Insert a turn for THIS document.
        let mine = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(),
            role: "user",
            content: "Mine",
            invocation: "passage",
            anchorOffset: 0,
            intent: nil,
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        try manager.appendAskPoseyTurn(mine)

        // Insert a turn for a DIFFERENT document. Must not appear.
        let other = UUID()
        try manager.upsertDocument(Document(
            id: other,
            title: "Other",
            fileName: "o.txt",
            fileType: "txt",
            importedAt: .now,
            modifiedAt: .now,
            displayText: "x",
            plainText: "x",
            characterCount: 1
        ))
        let foreign = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: other,
            timestamp: Date(),
            role: "user",
            content: "Not mine",
            invocation: "passage",
            anchorOffset: 0,
            intent: nil,
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        try manager.appendAskPoseyTurn(foreign)

        let vm = AskPoseyChatViewModel(
            documentID: documentID,
            documentPlainText: "x",
            anchor: nil,
            databaseManager: manager
        )
        await vm.awaitHistoryLoaded()
        // 1 prior user turn for this document + 1 fresh anchor marker
        // for this invocation. The foreign doc's turn must NOT leak
        // into messages.
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].content, "Mine")
        XCTAssertEqual(vm.messages[1].role, .anchor)
    }

    // MARK: — Anchor marker tests (unified annotation refactor)

    func testDocumentScopeInvocationCapturesReadingOffset() async throws {
        // Doc-scope invocation: anchor is nil but the caller passes
        // `invocationReadingOffset` so the persisted marker is still
        // tappable to jump back to where the question was asked.
        let vm = AskPoseyChatViewModel(
            documentID: documentID,
            documentPlainText: "long document",
            documentTitle: "The Test Document",
            anchor: nil,
            invocationReadingOffset: 4321,
            databaseManager: manager
        )
        await vm.awaitHistoryLoaded()
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.role, .anchor)
        XCTAssertEqual(vm.messages.first?.anchorScope, "document")
        XCTAssertEqual(vm.messages.first?.anchorOffset, 4321,
                       "Document-scope anchor must capture the invocation reading offset")
        XCTAssertEqual(vm.messages.first?.content, "The Test Document")
    }

    func testMultipleInvocationsAccumulateAnchors() async throws {
        let anchor1 = AskPoseyAnchor(text: "first sentence", plainTextOffset: 100)
        let vm1 = AskPoseyChatViewModel(
            documentID: documentID,
            documentPlainText: "doc",
            anchor: anchor1,
            databaseManager: manager
        )
        await vm1.awaitHistoryLoaded()

        let anchor2 = AskPoseyAnchor(text: "second sentence", plainTextOffset: 200)
        let vm2 = AskPoseyChatViewModel(
            documentID: documentID,
            documentPlainText: "doc",
            anchor: anchor2,
            databaseManager: manager
        )
        await vm2.awaitHistoryLoaded()

        // Second invocation should see both anchors in chronological
        // order plus its own freshly appended marker == 2 total.
        let anchorMessages = vm2.messages.filter { $0.role == .anchor }
        XCTAssertEqual(anchorMessages.count, 2,
                       "Each invocation appends a new anchor marker; prior anchors persist")
        XCTAssertEqual(anchorMessages[0].anchorOffset, 100)
        XCTAssertEqual(anchorMessages[1].anchorOffset, 200)

        // DB query also returns both rows.
        let stored = try manager.askPoseyAnchorRows(for: documentID)
        XCTAssertEqual(stored.count, 2)
    }

    func testNavigationCaseSkipsAnchorAppend() async throws {
        // Seed one prior anchor row.
        let priorAnchorID = UUID().uuidString
        let priorAnchor = StoredAskPoseyTurn(
            id: priorAnchorID,
            documentID: documentID,
            timestamp: Date(timeIntervalSince1970: 1_000),
            role: "anchor",
            content: "earlier passage",
            invocation: "passage",
            anchorOffset: 50,
            intent: nil,
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        try manager.appendAskPoseyTurn(priorAnchor)

        // Open the sheet via the Notes-tap-conversation path:
        // initialScrollAnchorStorageID set, no fresh anchor should
        // be appended.
        let vm = AskPoseyChatViewModel(
            documentID: documentID,
            documentPlainText: "doc",
            anchor: AskPoseyAnchor(text: "current sentence", plainTextOffset: 200),
            initialScrollAnchorStorageID: priorAnchorID,
            databaseManager: manager
        )
        await vm.awaitHistoryLoaded()

        // Only the prior anchor — no new marker appended.
        let anchorMessages = vm.messages.filter { $0.role == .anchor }
        XCTAssertEqual(anchorMessages.count, 1)
        XCTAssertEqual(anchorMessages.first?.storageID, priorAnchorID)
        XCTAssertEqual(vm.initialScrollAnchorStorageID, priorAnchorID)

        // DB still has only the seeded anchor.
        let stored = try manager.askPoseyAnchorRows(for: documentID)
        XCTAssertEqual(stored.count, 1)
    }

    func testPromptBuilderFilterExcludesAnchorRows() async throws {
        // Insert anchor + user + assistant rows directly.
        let now = Date().timeIntervalSince1970
        let mark = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(timeIntervalSince1970: now),
            role: "anchor",
            content: "anchored passage",
            invocation: "passage",
            anchorOffset: 0,
            intent: nil,
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        let user = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(timeIntervalSince1970: now + 1),
            role: "user",
            content: "Q",
            invocation: "passage",
            anchorOffset: 0,
            intent: "immediate",
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        let assistant = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(timeIntervalSince1970: now + 2),
            role: "assistant",
            content: "A",
            invocation: "passage",
            anchorOffset: 0,
            intent: nil,
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
        try manager.appendAskPoseyTurn(mark)
        try manager.appendAskPoseyTurn(user)
        try manager.appendAskPoseyTurn(assistant)

        // Prompt-builder fetch filters anchor rows out so STM budget
        // isn't double-charged.
        let conversation = try manager.askPoseyConversationTurns(for: documentID)
        XCTAssertEqual(conversation.count, 2)
        XCTAssertEqual(Set(conversation.map(\.role)), Set(["user", "assistant"]))

        // Anchor-rows fetch returns just the marker.
        let anchorsOnly = try manager.askPoseyAnchorRows(for: documentID)
        XCTAssertEqual(anchorsOnly.count, 1)
        XCTAssertEqual(anchorsOnly.first?.role, "anchor")
    }
}
// ========== BLOCK 02: CHAT VIEW MODEL - END ==========
