import XCTest
@testable import Posey

final class SentenceSegmenterTests: XCTestCase {
    func testSegmentsShortFixtureIntoMultipleSentences() throws {
        let text = try TestFixtureLoader.string(named: "ShortSample")

        let segments = SentenceSegmenter().segments(for: text)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.first?.startOffset, 0)
        XCTAssertTrue(segments.last?.endOffset == text.count)
    }

    func testMalformedFixtureStillProducesUsableSegments() throws {
        let text = try TestFixtureLoader.string(named: "MalformedPunctuationSample")

        let segments = SentenceSegmenter().segments(for: text)

        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.contains { $0.text.contains("tokenizers") || $0.text.contains("fallback chunk") })
    }
}
