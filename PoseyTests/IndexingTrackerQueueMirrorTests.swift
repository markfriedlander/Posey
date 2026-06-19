import XCTest
import Combine
@testable import Posey

// ========== BLOCK 01: INDEXING TRACKER QUEUE-MIRROR TESTS - START ==========

/// Pillar 4b proof: `IndexingTracker` faithfully mirrors
/// `DocumentIndexingQueue`'s published lane state into the view-friendly
/// "Queued #k" position + current-doc identity that a library card reads.
///
/// Off-device and deterministic: an isolated `NotificationCenter` carries a
/// synthetic `queueDidChangeNotification` (the exact userInfo the queue posts),
/// so the mirror's mapping is verified with no actor, database, or model. The
/// 50ms yield lets the `receive(on: RunLoop.main)` Combine sink propagate, the
/// same pattern the legacy tracker tests used.
@MainActor
final class IndexingTrackerQueueMirrorTests: XCTestCase {

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

    private func postQueueChange(current: UUID?, embedQueue: [UUID], raptorQueue: [UUID] = []) async throws {
        var info: [AnyHashable: Any] = [
            DocumentIndexingQueue.embedQueueKey: embedQueue,
            DocumentIndexingQueue.raptorQueueKey: raptorQueue,
        ]
        if let current { info[DocumentIndexingQueue.currentDocumentIDKey] = current }
        center.post(name: DocumentIndexingQueue.queueDidChangeNotification, object: nil, userInfo: info)
        try await Task.sleep(for: .milliseconds(50))   // let the RunLoop.main sink fire
    }

    /// The waiting embed lane maps to 1-based positions; the in-flight document
    /// is "current", not queued; untouched documents have no position.
    func testEmbedLaneMapsToOneBasedQueuePositions() async throws {
        let current = UUID()
        let first = UUID()
        let second = UUID()
        let stranger = UUID()

        try await postQueueChange(current: current, embedQueue: [first, second])

        XCTAssertEqual(tracker.currentIndexingDocumentID, current)
        XCTAssertNil(tracker.queuePosition(current), "the in-flight doc is not 'queued'")
        XCTAssertEqual(tracker.queuePosition(first), 1, "head of the embed lane → Queued #1")
        XCTAssertEqual(tracker.queuePosition(second), 2, "next → Queued #2")
        XCTAssertNil(tracker.queuePosition(stranger), "a doc not in the lane has no position")
    }

    /// Draining to idle (empty lanes, no current) clears every position so cards
    /// stop showing "Queued".
    func testDrainToIdleClearsPositionsAndCurrent() async throws {
        let current = UUID()
        let waiting = UUID()
        try await postQueueChange(current: current, embedQueue: [waiting])
        XCTAssertEqual(tracker.queuePosition(waiting), 1)

        try await postQueueChange(current: nil, embedQueue: [])
        XCTAssertNil(tracker.currentIndexingDocumentID)
        XCTAssertNil(tracker.queuePosition(waiting))
    }

    /// RAPTOR build progress mirrors into a 0…1 fraction: 0 on start, advancing
    /// per cluster, cleared on build-complete (→ card flips off "Studying up").
    func testReReadingFractionTracksRaptorProgress() async throws {
        let id = UUID()

        center.post(name: RaptorTreeService.didStartNotification, object: nil,
                    userInfo: [RaptorTreeService.documentIDKey: id])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(tracker.isReReading(id))
        XCTAssertEqual(tracker.reReadingFraction(id), 0, "starts at 0%")

        center.post(name: RaptorTreeService.didProgressNotification, object: nil,
                    userInfo: [RaptorTreeService.documentIDKey: id,
                               RaptorTreeService.processedClustersKey: 3,
                               RaptorTreeService.totalClustersKey: 12])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tracker.reReadingFraction(id) ?? -1, 0.25, accuracy: 0.001, "3/12 → 25%")

        center.post(name: RaptorTreeService.didBuildNotification, object: nil,
                    userInfo: [RaptorTreeService.documentIDKey: id,
                               RaptorTreeService.summaryNodeCountKey: 9])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(tracker.isReReading(id))
        XCTAssertNil(tracker.reReadingFraction(id), "cleared on build-complete")
    }

    /// "Cooling down" is scoped to the in-flight document AND a paced thermal
    /// state. With the test host at `.nominal` thermal, even the current doc must
    /// NOT read as cooling down — guards against the label firing spuriously.
    func testNotCoolingDownAtNominalThermal() async throws {
        let current = UUID()
        try await postQueueChange(current: current, embedQueue: [])
        XCTAssertEqual(tracker.currentIndexingDocumentID, current)
        XCTAssertFalse(tracker.isCoolingDown(current),
                       "nominal thermal ⇒ no cooling-down label, even on the in-flight doc")
    }
}

// ========== BLOCK 01: INDEXING TRACKER QUEUE-MIRROR TESTS - END ==========
