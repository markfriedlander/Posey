import XCTest
@testable import Posey

// ========== BLOCK 01: ENTITY EXTRACTION + JACCARD - START ==========
/// Unit tests for the M8 entity-aware scoring helpers added to
/// `DocumentEmbeddingIndex`. Pure-function tests; no DB.
final class EntityScoringTests: XCTestCase {

    func testExtractEntitiesEmptyString() {
        XCTAssertTrue(DocumentEmbeddingIndex.extractEntities(from: "").isEmpty)
    }

    func testExtractEntitiesPersonName() {
        let text = "Mark Friedlander wrote the spec."
        let entities = DocumentEmbeddingIndex.extractEntities(from: text)
        XCTAssertTrue(entities.contains("mark friedlander"),
                      "Expected 'mark friedlander' in extracted entities; got \(entities)")
    }

    func testExtractEntitiesPlaceName() {
        let text = "The conference was held in San Francisco last week."
        let entities = DocumentEmbeddingIndex.extractEntities(from: text)
        XCTAssertTrue(entities.contains("san francisco"),
                      "Expected 'san francisco' in extracted entities; got \(entities)")
    }

    func testExtractEntitiesOrganizationName() {
        let text = "Apple announced new tools at WWDC."
        let entities = DocumentEmbeddingIndex.extractEntities(from: text)
        XCTAssertTrue(entities.contains("apple") || entities.contains("wwdc"),
                      "Expected an org name in extracted entities; got \(entities)")
    }

    func testJaccardOverlapEmpty() {
        XCTAssertEqual(
            DocumentEmbeddingIndex.jaccardOverlap([], []), 0.0
        )
        XCTAssertEqual(
            DocumentEmbeddingIndex.jaccardOverlap(["a"], []), 0.0
        )
        XCTAssertEqual(
            DocumentEmbeddingIndex.jaccardOverlap([], ["a"]), 0.0
        )
    }

    func testJaccardOverlapIdentical() {
        let s: Set<String> = ["alpha", "beta", "gamma"]
        XCTAssertEqual(
            DocumentEmbeddingIndex.jaccardOverlap(s, s), 1.0
        )
    }

    func testJaccardOverlapDisjoint() {
        XCTAssertEqual(
            DocumentEmbeddingIndex.jaccardOverlap(["a", "b"], ["c", "d"]),
            0.0
        )
    }

    func testJaccardOverlapPartial() {
        // Intersection = {a, b}, union = {a, b, c, d, e} → 2/5 = 0.4
        let result = DocumentEmbeddingIndex.jaccardOverlap(
            ["a", "b", "c"],
            ["a", "b", "d", "e"]
        )
        XCTAssertEqual(result, 0.4, accuracy: 1e-9)
    }
}
// ========== BLOCK 01: ENTITY EXTRACTION + JACCARD - END ==========
