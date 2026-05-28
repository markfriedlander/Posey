import XCTest
import Combine
@testable import Posey

// ========== BLOCK 01: INDEXING TRACKER TESTS - START ==========
/// Confirms `IndexingTracker` correctly mirrors the indexing
/// notifications posted by `DocumentEmbeddingIndex.enqueueIndexing`.
/// Each test uses an isolated `NotificationCenter` so concurrent test
/// runs (and any real production posts on `NotificationCenter.default`)
/// can't cross-contaminate.
@MainActor
final class IndexingTrackerTests: XCTestCase {

    private var center: NotificationCenter!
    private var tracker: IndexingTracker!

    override func setUp() async throws {
        center = NotificationCenter()
        tracker = IndexingTracker(notificationCenter: center)
    }

    override func tearDown() async throws {
        tracker = nil
        center = nil
    }

    func testStartNotificationAddsDocumentToSet() async throws {
        let id = UUID()
        center.post(
            name: .documentIndexingDidStart,
            object: nil,
            userInfo: [
                DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                DocumentEmbeddingIndex.notificationDocumentTitleKey: "Test"
            ]
        )
        // Combine sinks fire on the next runloop tick when receive(on:
        // RunLoop.main) is in the path. Yield to let it propagate.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(tracker.isIndexing(id))
        XCTAssertEqual(tracker.indexingDocumentIDs, [id])
    }

    func testCompleteNotificationRemovesAndRecordsCount() async throws {
        let id = UUID()
        center.post(name: .documentIndexingDidStart, object: nil,
                    userInfo: [DocumentEmbeddingIndex.notificationDocumentIDKey: id])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(tracker.isIndexing(id))

        center.post(name: .documentIndexingDidComplete, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                        DocumentEmbeddingIndex.notificationChunkCountKey: 847
                    ])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(tracker.isIndexing(id),
                       "Document must be removed from indexing set on completion")
        XCTAssertEqual(tracker.lastCompletedChunkCounts[id], 847,
                       "Chunk count should be recorded for the brief 'Indexed N' confirmation UI")
    }

    func testFailNotificationRemovesWithoutRecordingCount() async throws {
        let id = UUID()
        center.post(name: .documentIndexingDidStart, object: nil,
                    userInfo: [DocumentEmbeddingIndex.notificationDocumentIDKey: id])
        try await Task.sleep(for: .milliseconds(50))

        struct Boom: Error {}
        center.post(name: .documentIndexingDidFail, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                        DocumentEmbeddingIndex.notificationErrorKey: Boom()
                    ])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(tracker.isIndexing(id))
        XCTAssertNil(tracker.lastCompletedChunkCounts[id],
                     "Failed indexing must NOT record a chunk count — UI must never show 'Indexed 0 sections'")
    }

    func testNotificationsForDifferentDocumentsTrackIndependently() async throws {
        let a = UUID()
        let b = UUID()
        center.post(name: .documentIndexingDidStart, object: nil,
                    userInfo: [DocumentEmbeddingIndex.notificationDocumentIDKey: a])
        center.post(name: .documentIndexingDidStart, object: nil,
                    userInfo: [DocumentEmbeddingIndex.notificationDocumentIDKey: b])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tracker.indexingDocumentIDs, [a, b])

        center.post(name: .documentIndexingDidComplete, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: a,
                        DocumentEmbeddingIndex.notificationChunkCountKey: 12
                    ])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tracker.indexingDocumentIDs, [b],
                       "Completion of one document must not affect others still in progress")
    }

    func testRestartOnReimportClearsPreviousCompletion() async throws {
        let id = UUID()
        // Initial successful indexing.
        center.post(name: .documentIndexingDidStart, object: nil,
                    userInfo: [DocumentEmbeddingIndex.notificationDocumentIDKey: id])
        center.post(name: .documentIndexingDidComplete, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                        DocumentEmbeddingIndex.notificationChunkCountKey: 100
                    ])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tracker.lastCompletedChunkCounts[id], 100)

        // User re-imports → new start fires while the old "Indexed 100"
        // pill is still eligible to render. The tracker must drop the
        // stale completion record so the UI doesn't briefly show
        // "Indexed 100" while the new indexing is mid-flight.
        center.post(name: .documentIndexingDidStart, object: nil,
                    userInfo: [DocumentEmbeddingIndex.notificationDocumentIDKey: id])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(tracker.isIndexing(id))
        XCTAssertNil(tracker.lastCompletedChunkCounts[id],
                     "A new start for the same document must clear the stale completion record")
    }

    func testNotificationsWithMissingDocumentIDAreIgnored() async throws {
        center.post(name: .documentIndexingDidStart, object: nil, userInfo: [:])
        center.post(name: .documentIndexingDidStart, object: nil, userInfo: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(tracker.indexingDocumentIDs.isEmpty,
                      "Malformed notifications must not corrupt tracker state")
    }

    func testProgressNotificationUpdatesPublishedProgress() async throws {
        let id = UUID()
        center.post(name: .documentIndexingDidStart, object: nil,
                    userInfo: [DocumentEmbeddingIndex.notificationDocumentIDKey: id])
        center.post(name: .documentIndexingDidProgress, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                        DocumentEmbeddingIndex.notificationProcessedChunksKey: 50,
                        DocumentEmbeddingIndex.notificationTotalChunksKey: 200
                    ])
        try await Task.sleep(for: .milliseconds(50))
        let firstSnapshot = try XCTUnwrap(tracker.indexingProgress[id])
        XCTAssertEqual(firstSnapshot.processed, 50)
        XCTAssertEqual(firstSnapshot.total, 200)
        XCTAssertEqual(firstSnapshot.fraction, 0.25, accuracy: 0.001)

        center.post(name: .documentIndexingDidProgress, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                        DocumentEmbeddingIndex.notificationProcessedChunksKey: 150,
                        DocumentEmbeddingIndex.notificationTotalChunksKey: 200
                    ])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tracker.indexingProgress[id]?.processed, 150,
                       "Subsequent progress notifications must overwrite the previous snapshot")
    }

    func testProgressIsClearedOnComplete() async throws {
        let id = UUID()
        center.post(name: .documentIndexingDidProgress, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                        DocumentEmbeddingIndex.notificationProcessedChunksKey: 100,
                        DocumentEmbeddingIndex.notificationTotalChunksKey: 200
                    ])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(tracker.indexingProgress[id])

        center.post(name: .documentIndexingDidComplete, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                        DocumentEmbeddingIndex.notificationChunkCountKey: 200
                    ])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(tracker.indexingProgress[id],
                     "Completed indexing must clear the in-flight progress entry")
    }

    func testProgressIsClearedOnFail() async throws {
        let id = UUID()
        center.post(name: .documentIndexingDidProgress, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                        DocumentEmbeddingIndex.notificationProcessedChunksKey: 100,
                        DocumentEmbeddingIndex.notificationTotalChunksKey: 200
                    ])
        try await Task.sleep(for: .milliseconds(50))

        struct Boom: Error {}
        center.post(name: .documentIndexingDidFail, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                        DocumentEmbeddingIndex.notificationErrorKey: Boom()
                    ])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(tracker.indexingProgress[id],
                     "Failed indexing must clear the in-flight progress entry")
    }

    func testProgressFractionClampedAtBounds() {
        // Direct test of the IndexingProgress struct without going
        // through notifications — easier to assert numerics.
        let zero = IndexingTracker.IndexingProgress(processed: 0, total: 0)
        XCTAssertEqual(zero.fraction, 0,
                       "Zero total should produce 0 fraction, not NaN")
        let mid = IndexingTracker.IndexingProgress(processed: 50, total: 200)
        XCTAssertEqual(mid.fraction, 0.25, accuracy: 0.001)
        let over = IndexingTracker.IndexingProgress(processed: 200, total: 100)
        XCTAssertEqual(over.fraction, 1.0,
                       "Fraction should clamp at 1.0 even when processed > total")
    }

    func testDismissCompletionRemovesEntry() async throws {
        let id = UUID()
        center.post(name: .documentIndexingDidComplete, object: nil,
                    userInfo: [
                        DocumentEmbeddingIndex.notificationDocumentIDKey: id,
                        DocumentEmbeddingIndex.notificationChunkCountKey: 42
                    ])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tracker.lastCompletedChunkCounts[id], 42)
        tracker.dismissCompletion(for: id)
        XCTAssertNil(tracker.lastCompletedChunkCounts[id])
    }
}
// ========== BLOCK 01: INDEXING TRACKER TESTS - END ==========
