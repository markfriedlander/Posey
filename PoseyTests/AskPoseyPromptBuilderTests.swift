import XCTest
@testable import Posey

// ========== BLOCK 01: TOKEN ESTIMATOR - START ==========
/// Tests for `AskPoseyTokenEstimator`. The estimator is a tiny utility
/// — these tests pin the contract so future tuning is deliberate.
final class AskPoseyTokenEstimatorTests: XCTestCase {

    func testEmptyStringIsZeroTokens() {
        XCTAssertEqual(AskPoseyTokenEstimator.tokens(in: ""), 0)
    }

    func testSingleCharFloorIsOneToken() {
        // 1 char / 3.5 ratio rounds to 0; we floor at 1 for non-empty.
        XCTAssertEqual(AskPoseyTokenEstimator.tokens(in: "a"), 1)
    }

    func testRoughRatio() {
        // 25 chars / 2.5 = 10 tokens (2026-05-03 ratio tightened
        // 3.0 → 2.5 in Task 4 #3 to add headroom for AFM tokenizer
        // disagreement that surfaced as `exceededContextWindowSize`).
        let s = String(repeating: "a", count: 25)
        XCTAssertEqual(AskPoseyTokenEstimator.tokens(in: s), 10)
    }

    func testCharsRoundtrip() {
        // 10 tokens * 2.5 = 25 chars (2026-05-03 ratio tightened).
        XCTAssertEqual(AskPoseyTokenEstimator.chars(in: 10), 25)
    }

    func testZeroTokensZeroChars() {
        XCTAssertEqual(AskPoseyTokenEstimator.chars(in: 0), 0)
    }
}
// ========== BLOCK 01: TOKEN ESTIMATOR - END ==========


// ========== BLOCK 02: TOKEN BUDGET - START ==========
/// Tests for `AskPoseyTokenBudget`. Pins the default values and the
/// derived calculations so a refactor can't silently shift the budget.
final class AskPoseyTokenBudgetTests: XCTestCase {

    func testAFMDefaultMatchesPlannedSplit() {
        let b = AskPoseyTokenBudget.afmDefault
        XCTAssertEqual(b.contextWindowTokens, 4096)
        XCTAssertEqual(b.responseReserveTokens, 1024)  // 2026-05-02: bumped
        XCTAssertEqual(b.systemBudgetTokens, 180)
        XCTAssertEqual(b.anchorBudgetTokens, 300)      // 2026-05-02: 360 → 300
        XCTAssertEqual(b.stmBudgetTokens, 600)         // 2026-05-02: 720 → 600
        XCTAssertEqual(b.summaryBudgetTokens, 300)     // 2026-05-02: 360 → 300
        XCTAssertEqual(b.ragBudgetTokens, 1400)        // 2026-05-02: 1800 → 1400
    }

    func testPromptCeilingExcludesResponseReserve() {
        let b = AskPoseyTokenBudget.afmDefault
        XCTAssertEqual(b.promptCeilingTokens, 4096 - 1024)
    }

    func testAllocatedSectionBudgetSumsCorrectly() {
        let b = AskPoseyTokenBudget.afmDefault
        XCTAssertEqual(b.allocatedSectionBudget, 180 + 300 + 600 + 300 + 1400)
    }

    func testUserQuestionBudgetIsRemainder() {
        let b = AskPoseyTokenBudget.afmDefault
        XCTAssertEqual(b.userQuestionBudgetTokens, b.promptCeilingTokens - b.allocatedSectionBudget)
    }

    func testUserQuestionBudgetClampsAtZero() {
        // Hand-tune to overflow so the clamp fires.
        var b = AskPoseyTokenBudget.afmDefault
        b.systemBudgetTokens = 99_999
        XCTAssertEqual(b.userQuestionBudgetTokens, 0)
    }
}
// ========== BLOCK 02: TOKEN BUDGET - END ==========


// ========== BLOCK 03: PROMPT BUILDER - HAPPY PATHS - START ==========
/// Happy-path tests for `AskPoseyPromptBuilder.build`. M5 always passes
/// empty document chunks and nil summary; these tests cover the
/// passage-scoped flow with anchor + STM + question.
final class AskPoseyPromptBuilderTests: XCTestCase {

    private func makeAnchor(_ text: String = "The road less traveled.") -> AskPoseyAnchor {
        AskPoseyAnchor(text: text, plainTextOffset: 0)
    }

    private func makeInputs(
        intent: AskPoseyIntent = .immediate,
        anchor: AskPoseyAnchor? = nil,
        surrounding: String? = nil,
        history: [AskPoseyMessage] = [],
        summary: String? = nil,
        chunks: [RetrievedChunk] = [],
        question: String = "What does this passage mean?"
    ) -> AskPoseyPromptInputs {
        AskPoseyPromptInputs(
            intent: intent,
            anchor: anchor,
            surroundingContext: surrounding,
            conversationHistory: history,
            conversationSummary: summary,
            documentChunks: chunks,
            currentQuestion: question
        )
    }

    func testEmptyHistoryAndChunks_RendersSystemAnchorUser() {
        let inputs = makeInputs(anchor: makeAnchor())
        let out = AskPoseyPromptBuilder.build(inputs)

        XCTAssertFalse(out.instructions.isEmpty)
        XCTAssertTrue(out.renderedBody.contains("ANCHOR PASSAGE"))
        XCTAssertTrue(out.renderedBody.contains("USER QUESTION"))
        XCTAssertFalse(out.renderedBody.contains("DOCUMENT EXCERPTS"))
        XCTAssertFalse(out.renderedBody.contains("EARLIER IN THIS CONVERSATION"))
        XCTAssertFalse(out.renderedBody.contains("SUMMARY OF EARLIER CONVERSATION"))
        XCTAssertEqual(out.chunksInjected.count, 0)
        XCTAssertEqual(out.droppedSections.count, 0)
    }

    func testNilAnchor_OmitsAnchorSection() {
        let inputs = makeInputs(anchor: nil)
        let out = AskPoseyPromptBuilder.build(inputs)
        XCTAssertFalse(out.renderedBody.contains("ANCHOR PASSAGE"))
    }

    func testHistoryTurnsRenderInChronologicalOrder() {
        let history: [AskPoseyMessage] = [
            AskPoseyMessage(role: .user, content: "First question"),
            AskPoseyMessage(role: .assistant, content: "First answer"),
            AskPoseyMessage(role: .user, content: "Second question"),
            AskPoseyMessage(role: .assistant, content: "Second answer")
        ]
        let inputs = makeInputs(anchor: makeAnchor(), history: history)
        let out = AskPoseyPromptBuilder.build(inputs)

        XCTAssertTrue(out.renderedBody.contains("EARLIER IN THIS CONVERSATION"))
        let firstIndex = out.renderedBody.range(of: "First question")?.lowerBound
        let secondIndex = out.renderedBody.range(of: "Second question")?.lowerBound
        XCTAssertNotNil(firstIndex)
        XCTAssertNotNil(secondIndex)
        if let f = firstIndex, let s = secondIndex {
            XCTAssertLessThan(f, s, "Older turns should render earlier than newer turns")
        }
    }

    func testSurroundingContextRenders_WhenPresent() {
        let inputs = makeInputs(
            anchor: makeAnchor(),
            surrounding: "Two roads diverged in a yellow wood."
        )
        let out = AskPoseyPromptBuilder.build(inputs)
        XCTAssertTrue(out.renderedBody.contains("SURROUNDING CONTEXT"))
        XCTAssertTrue(out.renderedBody.contains("Two roads diverged"))
    }

    func testSurroundingContextOmitted_ForSearchIntent() {
        // .search intent's surrounding window is 0 tokens — even with
        // text passed in, the section drops.
        let inputs = makeInputs(
            intent: .search,
            anchor: makeAnchor(),
            surrounding: "Two roads diverged in a yellow wood."
        )
        let out = AskPoseyPromptBuilder.build(inputs)
        XCTAssertFalse(out.renderedBody.contains("SURROUNDING CONTEXT"))
    }

    func testRAGChunksRender_WhenPresent() {
        let chunk = RetrievedChunk(
            chunkID: 42,
            startOffset: 1024,
            text: "A document chunk's worth of relevant prose.",
            relevance: 0.87
        )
        let inputs = makeInputs(anchor: makeAnchor(), chunks: [chunk])
        let out = AskPoseyPromptBuilder.build(inputs)
        XCTAssertTrue(out.renderedBody.contains("DOCUMENT EXCERPTS"))
        XCTAssertTrue(out.renderedBody.contains("A document chunk"))
        XCTAssertEqual(out.chunksInjected.count, 1)
        XCTAssertEqual(out.chunksInjected.first?.chunkID, 42)
    }

    func testTokenBreakdownReflectsActualCosts() {
        let inputs = makeInputs(
            anchor: makeAnchor(),
            history: [
                AskPoseyMessage(role: .user, content: "earlier"),
                AskPoseyMessage(role: .assistant, content: "earlier reply")
            ]
        )
        let out = AskPoseyPromptBuilder.build(inputs)
        XCTAssertGreaterThan(out.tokenBreakdown.system, 0)
        XCTAssertGreaterThan(out.tokenBreakdown.anchor, 0)
        XCTAssertGreaterThan(out.tokenBreakdown.stm, 0)
        XCTAssertGreaterThan(out.tokenBreakdown.userQuestion, 0)
        XCTAssertGreaterThan(out.tokenBreakdown.totalIncludingScaffolding, out.tokenBreakdown.sectionsTotal)
    }
}
// ========== BLOCK 03: PROMPT BUILDER - HAPPY PATHS - END ==========


// ========== BLOCK 04: PROMPT BUILDER - DROP PRIORITY - START ==========
/// Tests for budget overflow + drop priority. Forces overflow with a
/// budget tuned to be too small for the inputs and asserts the drops
/// happen in the order Mark specified:
/// 1. Drop oldest RAG chunks first
/// 2. Drop summary
/// 3. Drop oldest STM turns
/// 4. Drop surrounding
/// 5. Truncate user question (last resort)
/// 6. Anchor + system are non-droppable
final class AskPoseyPromptBuilderDropTests: XCTestCase {

    private func makeAnchor() -> AskPoseyAnchor {
        AskPoseyAnchor(text: "Anchor passage.", plainTextOffset: 0)
    }

    func testSTMOverflow_DropsOldestTurnsFirst() {
        // 2026-05-03 (Task 4 #2 third iteration): STM rendering only
        // includes USER turns ("the user has so far asked: …") to
        // prevent format imitation from prior assistant replies.
        // Even-numbered turns are assistants and are filtered before
        // rendering; budget claim still happens for both. Verify the
        // most recent USER turn (#19) survives and the oldest USER
        // turn (#1) drops when STM budget is tight.
        let history: [AskPoseyMessage] = (1...20).map { i in
            AskPoseyMessage(
                role: i % 2 == 1 ? .user : .assistant,
                content: "Turn \(i): " + String(repeating: "x", count: 200)
            )
        }
        var budget = AskPoseyTokenBudget.afmDefault
        budget.stmBudgetTokens = 200

        let inputs = AskPoseyPromptInputs(
            intent: .immediate,
            anchor: makeAnchor(),
            surroundingContext: nil,
            conversationHistory: history,
            conversationSummary: nil,
            documentChunks: [],
            currentQuestion: "Tell me more."
        )
        let out = AskPoseyPromptBuilder.build(inputs, budget: budget)

        let stmDrops = out.droppedSections.filter { $0.section == .stmTurn }
        XCTAssertFalse(stmDrops.isEmpty, "Expected STM overflow to drop turns")

        // Most recent USER turn (Turn 19) must survive.
        XCTAssertTrue(out.renderedBody.contains("Turn 19"),
                      "Most recent user turn must remain in the prompt")
        // Oldest USER turn (Turn 1) must be dropped.
        XCTAssertFalse(out.renderedBody.contains("Turn 1:"),
                       "Oldest user turn must drop first under budget pressure")
    }

    func testRAGOverflow_DropsExcessChunks() {
        let chunks: [RetrievedChunk] = (1...10).map { i in
            RetrievedChunk(
                chunkID: i,
                startOffset: i * 100,
                text: String(repeating: "y", count: 800),  // ~228 tokens each
                relevance: Double(11 - i) / 10.0
            )
        }
        var budget = AskPoseyTokenBudget.afmDefault
        budget.ragBudgetTokens = 500  // Only ~2 chunks fit

        let inputs = AskPoseyPromptInputs(
            intent: .immediate,
            anchor: makeAnchor(),
            surroundingContext: nil,
            conversationHistory: [],
            conversationSummary: nil,
            documentChunks: chunks,
            currentQuestion: "?"
        )
        let out = AskPoseyPromptBuilder.build(inputs, budget: budget)

        XCTAssertLessThan(out.chunksInjected.count, chunks.count)
        let ragDrops = out.droppedSections.filter { $0.section == .ragChunk }
        XCTAssertFalse(ragDrops.isEmpty, "Expected RAG drops when budget is tight")
    }

    func testUserQuestionNeverTruncated() {
        // 2026-05-03 (Task 4 #2): user question is reserved up-front
        // and is never truncated, even when the prompt ceiling is
        // tight. Replaces the prior "last-resort truncation" contract
        // that produced "Who is responsible for i" mid-word cuts in
        // Task 3 testing.
        var budget = AskPoseyTokenBudget()
        budget.contextWindowTokens = 600
        budget.responseReserveTokens = 100
        budget.systemBudgetTokens = 200
        budget.anchorBudgetTokens = 100
        budget.stmBudgetTokens = 100
        budget.summaryBudgetTokens = 50
        budget.ragBudgetTokens = 50

        let longQuestion = String(repeating: "z", count: 5000)
        let inputs = AskPoseyPromptInputs(
            intent: .immediate,
            anchor: makeAnchor(),
            surroundingContext: nil,
            conversationHistory: [],
            conversationSummary: nil,
            documentChunks: [],
            currentQuestion: longQuestion
        )
        let out = AskPoseyPromptBuilder.build(inputs, budget: budget)
        let truncations = out.droppedSections.filter { $0.section == .userQuestionTruncated }
        XCTAssertTrue(truncations.isEmpty,
                      "User question must never be truncated, even with a tight ceiling")
        XCTAssertTrue(out.renderedBody.contains(longQuestion),
                      "Full user question text must appear in the prompt verbatim")
    }
}
// ========== BLOCK 04: PROMPT BUILDER - DROP PRIORITY - END ==========


// ========== BLOCK 05: SURROUNDING WINDOW - START ==========
final class AskPoseySurroundingWindowTests: XCTestCase {

    func testImmediateIntentHasMidsizeWindow() {
        XCTAssertEqual(AskPoseyPromptBuilder.surroundingWindowTokens(for: .immediate), 150)
    }

    func testSearchIntentHasZeroWindow() {
        XCTAssertEqual(AskPoseyPromptBuilder.surroundingWindowTokens(for: .search), 0)
    }

    func testGeneralIntentHasGenerousWindow() {
        XCTAssertEqual(AskPoseyPromptBuilder.surroundingWindowTokens(for: .general), 300)
    }
}
// ========== BLOCK 05: SURROUNDING WINDOW - END ==========
