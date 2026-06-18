import XCTest
@testable import Posey

/// Pillar 1 proof: the document-level serial gate runs EXACTLY ONE document's
/// pipeline at a time, in FIFO order, no matter how many are submitted at once
/// — the structural guarantee that no operator action (antenna or file-picker,
/// 1 doc or 10) can stack indexing work on the device and re-create the
/// 2026-06-17 thermal incident. Also proves the escape switch halts the
/// in-flight document and clears the queue, and that per-document cancel drops
/// a queued document before it ever runs.
///
/// Entirely off-device: a fake `DocumentIndexer` records ordering + concurrency
/// + mid-flight cancellation, so the queue's contract is verified with no
/// database and no model.
final class DocumentIndexingQueueTests: XCTestCase {

    // MARK: Test doubles

    /// Records what the queue actually did: peak concurrency (must stay 1),
    /// the order documents started, which finished, and which were cancelled
    /// mid-flight.
    actor Recorder {
        private var current = 0
        private(set) var maxConcurrent = 0
        private(set) var started: [UUID] = []
        private(set) var finished: [UUID] = []
        private(set) var cancelledMidFlight: [UUID] = []

        func enter(_ id: UUID) {
            current += 1
            maxConcurrent = max(maxConcurrent, current)
            started.append(id)
        }
        func exit(_ id: UUID, cancelled: Bool) {
            current -= 1
            finished.append(id)
            if cancelled { cancelledMidFlight.append(id) }
        }
    }

    /// Stand-in for the real embed + RAPTOR pipeline. Marks enter/exit around a
    /// sleep so overlap is observable, and honors cooperative cancellation
    /// exactly as the live indexer must (the sleep throws on cancel → returns
    /// early → records that it was cancelled mid-flight).
    struct FakeIndexer: DocumentIndexer {
        let recorder: Recorder
        let sleepNanos: UInt64
        func indexDocument(_ documentID: UUID) async {
            await recorder.enter(documentID)
            try? await Task.sleep(nanoseconds: sleepNanos)
            await recorder.exit(documentID, cancelled: Task.isCancelled)
        }
    }

    // MARK: Helpers

    /// Poll until the queue is fully idle (no in-flight doc, empty queue) or a
    /// timeout. The fast path is the common case; the timeout guards against a
    /// hang regressing into a stuck test.
    private func waitUntilIdle(_ queue: DocumentIndexingQueue,
                               timeoutMs: Int = 5000) async {
        for _ in 0..<(timeoutMs / 5) {
            let snap = await queue.snapshot()
            if snap.current == nil && snap.queue.isEmpty { return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        XCTFail("queue did not reach idle within \(timeoutMs)ms")
    }

    // MARK: Tests

    /// THE central guarantee: submit 10 documents at once; the queue must run
    /// them one at a time, in order, never two concurrently.
    func testRunsExactlyOneDocumentAtATime() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 3_000_000))

        let ids = (0..<10).map { _ in UUID() }
        for id in ids { await queue.enqueue(id) }
        await waitUntilIdle(queue)

        let peak = await recorder.maxConcurrent
        XCTAssertEqual(peak, 1, "queue must index exactly one document at a time")

        let started = await recorder.started
        XCTAssertEqual(started, ids, "documents must index in FIFO order")

        let finished = await recorder.finished
        XCTAssertEqual(Set(finished), Set(ids), "every document must finish")
    }

    /// A second enqueue of the same document while it is queued or in flight is
    /// a no-op — never a parallel re-run.
    func testIdempotentEnqueue() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 50_000_000))

        let id = UUID()
        await queue.enqueue(id)
        await queue.enqueue(id) // in-flight → skipped
        await queue.enqueue(id) // still in-flight → skipped
        await waitUntilIdle(queue)

        let started = await recorder.started
        XCTAssertEqual(started.filter { $0 == id }.count, 1,
                       "a re-enqueued in-flight document must not run twice")
    }

    /// The escape switch: cancel the in-flight document and clear everything
    /// queued, returning all affected IDs for the caller to re-index later.
    func testExpungeAllHaltsInFlightAndClearsQueue() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 200_000_000))

        let ids = (0..<5).map { _ in UUID() }
        for id in ids { await queue.enqueue(id) }
        // Let the first document get in-flight (well before its 200ms finishes).
        try? await Task.sleep(nanoseconds: 30_000_000)

        let affected = await queue.expungeAll()
        XCTAssertEqual(Set(affected), Set(ids),
                       "expunge reports the in-flight doc plus all queued docs")

        await waitUntilIdle(queue)
        let snap = await queue.snapshot()
        XCTAssertNil(snap.current, "no document in flight after expunge")
        XCTAssertTrue(snap.queue.isEmpty, "queue cleared after expunge")

        let cancelledMid = await recorder.cancelledMidFlight
        XCTAssertEqual(cancelledMid, [ids.first],
                       "exactly the in-flight document is halted mid-flight")
        let started = await recorder.started
        XCTAssertEqual(started, [ids.first],
                       "the queued documents never started")
    }

    /// Per-document cancel (a document delete) drops a still-queued document so
    /// it never runs, without disturbing the others.
    func testCancelQueuedDocumentNeverRuns() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 40_000_000))

        let ids = (0..<4).map { _ in UUID() }
        for id in ids { await queue.enqueue(id) }
        // ids[0] is in-flight (40ms); cancel ids[2] while it is still queued.
        await queue.cancel(ids[2])
        await waitUntilIdle(queue)

        let started = await recorder.started
        XCTAssertFalse(started.contains(ids[2]),
                       "a cancelled queued document must never start")
        XCTAssertEqual(Set(started), Set([ids[0], ids[1], ids[3]]),
                       "the other documents still run")
    }
}
