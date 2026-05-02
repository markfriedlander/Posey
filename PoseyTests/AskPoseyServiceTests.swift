import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Posey

// ========== BLOCK 01: PROMPT CONSTRUCTION TESTS - START ==========
/// Unit tests for `AskPoseyPrompts` — pure string assembly, no AFM.
/// These pin the Call-1 prompt shape so future tweaks are deliberate
/// changes (a failing test) rather than silent drift.
final class AskPoseyPromptTests: XCTestCase {

    func testClassifierPromptIncludesQuestion() {
        let prompt = AskPoseyPrompts.classifierPrompt(
            question: "What is the author's main argument?",
            anchor: nil
        )
        XCTAssertTrue(prompt.contains("What is the author's main argument?"))
    }

    func testClassifierPromptListsAllThreeBuckets() {
        let prompt = AskPoseyPrompts.classifierPrompt(
            question: "Anything",
            anchor: nil
        )
        XCTAssertTrue(prompt.contains("- immediate"))
        XCTAssertTrue(prompt.contains("- search"))
        XCTAssertTrue(prompt.contains("- general"))
    }

    func testClassifierPromptIncludesAnchorWhenPresent() {
        let anchor = "It was the year when they finally immanentized the Eschaton."
        let prompt = AskPoseyPrompts.classifierPrompt(
            question: "What does this mean?",
            anchor: anchor
        )
        XCTAssertTrue(prompt.contains(anchor),
                      "Anchor passage should appear verbatim in the prompt")
        XCTAssertTrue(prompt.contains("Anchor passage"),
                      "Anchor passage should be labeled so the model knows what role it plays")
    }

    func testClassifierPromptOmitsAnchorSectionWhenAbsent() {
        let prompt = AskPoseyPrompts.classifierPrompt(
            question: "Anything",
            anchor: nil
        )
        XCTAssertFalse(prompt.contains("Anchor passage"),
                       "When no anchor is provided, the section should not appear at all")
    }

    func testClassifierPromptOmitsAnchorSectionForWhitespaceOnlyAnchor() {
        // A whitespace-only anchor should be treated as "no anchor."
        let prompt = AskPoseyPrompts.classifierPrompt(
            question: "Anything",
            anchor: "   \n\t  "
        )
        XCTAssertFalse(prompt.contains("Anchor passage"))
    }

    func testClassifierPromptTrimsQuestionWhitespace() {
        let prompt = AskPoseyPrompts.classifierPrompt(
            question: "   What is the answer?   \n",
            anchor: nil
        )
        XCTAssertTrue(prompt.contains("What is the answer?"))
        // The leading/trailing whitespace should not survive into the prompt.
        XCTAssertFalse(prompt.contains("\"   What"))
    }

    func testInstructionsAreShortAndSpecific() {
        // System instructions ride every call's prompt cost. Keep
        // them under ~600 chars; failing this test means you've
        // bloated the instructions and should reconsider.
        XCTAssertLessThan(AskPoseyPrompts.classifierInstructions.count, 600,
                          "Classifier instructions should be short — every char is per-call cost")
        XCTAssertTrue(AskPoseyPrompts.classifierInstructions.contains("classify"),
                      "Instructions should explicitly mention classification")
    }
}
// ========== BLOCK 01: PROMPT CONSTRUCTION TESTS - END ==========


// ========== BLOCK 02: INTENT VALUE TESTS - START ==========
/// Sanity tests for `AskPoseyIntent`. The `@Generable` macro provides
/// the schema conformance; we just verify the basics:
/// every case has a stable raw value, the enum is round-trippable,
/// and `CaseIterable` includes all three.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
final class AskPoseyIntentTests: XCTestCase {

    func testAllCasesPresent() {
        XCTAssertEqual(AskPoseyIntent.allCases.count, 3)
        XCTAssertTrue(AskPoseyIntent.allCases.contains(.immediate))
        XCTAssertTrue(AskPoseyIntent.allCases.contains(.search))
        XCTAssertTrue(AskPoseyIntent.allCases.contains(.general))
    }

    func testRawValuesAreStable() {
        // The raw values are part of the on-the-wire schema AFM sees.
        // Renaming a case would change the schema and could surface as
        // a regression in classification quality. Pin them.
        XCTAssertEqual(AskPoseyIntent.immediate.rawValue, "immediate")
        XCTAssertEqual(AskPoseyIntent.search.rawValue, "search")
        XCTAssertEqual(AskPoseyIntent.general.rawValue, "general")
    }

    func testCodableRoundTrip() throws {
        for intent in AskPoseyIntent.allCases {
            let data = try JSONEncoder().encode(intent)
            let decoded = try JSONDecoder().decode(AskPoseyIntent.self, from: data)
            XCTAssertEqual(decoded, intent)
        }
    }
}
// ========== BLOCK 02: INTENT VALUE TESTS - END ==========


// ========== BLOCK 03: ON-DEVICE CLASSIFIER PROBE - START ==========
/// End-to-end probe that runs a real classification through AFM.
/// **Device-only** — simulator iOS 26.3 still lacks the model assets
/// (see FoundationModelsAvailabilityProbe), so this suite uses the
/// same `XCTSkip` discipline. On Mark's iPhone 16 Plus this test
/// surfaces real classification accuracy; intermittent variance from
/// the model is acceptable as long as the result is one of the three
/// valid cases.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
final class AskPoseyServiceOnDeviceProbe: XCTestCase {

    /// Probe with a question that's clearly about the anchor passage.
    /// We don't assert a specific intent — the model is free to pick
    /// any of the three cases — but we DO assert the call returns a
    /// valid case and doesn't throw.
    func testClassifierReturnsValidIntentForAnchoredQuestion() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("AFM model assets aren't installed in the simulator image; device-only probe.")
        #else
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else {
            throw XCTSkip("AFM availability != .available on this device.")
        }
        let service = await AskPoseyService()
        let intent = try await service.classifyIntent(
            question: "What does this paragraph mean?",
            anchor: "It was the year when they finally immanentized the Eschaton."
        )
        XCTAssertTrue(AskPoseyIntent.allCases.contains(intent),
                      "Classifier returned \(intent), which is not one of the three valid cases")
        #endif
        #endif
    }

    func testClassifierHandlesNoAnchor() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("AFM model assets aren't installed in the simulator image; device-only probe.")
        #else
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else {
            throw XCTSkip("AFM availability != .available on this device.")
        }
        let service = await AskPoseyService()
        let intent = try await service.classifyIntent(
            question: "Summarise the main themes of this book.",
            anchor: nil
        )
        XCTAssertTrue(AskPoseyIntent.allCases.contains(intent))
        #endif
        #endif
    }
}
// ========== BLOCK 03: ON-DEVICE CLASSIFIER PROBE - END ==========
