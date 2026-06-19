import XCTest
@testable import Posey

/// Pillar 1 proof: the document-level serial gate runs EXACTLY ONE document-pass
/// at a time, embedding (tier 1) fully before RAPTOR (tier 2), no matter how
/// many documents are submitted at once — the structural guarantee that no
/// operator action can stack indexing work and re-create the 2026-06-17 thermal
/// incident, while getting every document Ask-able as fast as possible.
///
/// Entirely off-device: a fake `DocumentIndexer` records ordering + concurrency
/// + mid-pass cancellation, so the queue's contract is verified with no database
/// and no model.
final class DocumentIndexingQueueTests: XCTestCase {

    // MARK: Test doubles

    /// One recorded step: which pass ran for which document.
    struct Step: Equatable { let phase: DocumentIndexingPhase; let id: UUID }

    /// Records peak concurrency (must stay 1) and the exact ordered sequence of
    /// passes, plus which were cancelled mid-pass.
    actor Recorder {
        private var current = 0
        private(set) var maxConcurrent = 0
        private(set) var steps: [Step] = []
        private(set) var cancelledMidPass: [Step] = []

        func enter(_ s: Step) {
            current += 1
            maxConcurrent = max(maxConcurrent, current)
            steps.append(s)
        }
        func exit(_ s: Step, cancelled: Bool) {
            current -= 1
            if cancelled { cancelledMidPass.append(s) }
        }
    }

    /// Stand-in for the real embed + RAPTOR passes. Marks enter/exit around a
    /// sleep so overlap is observable, and honors cooperative cancellation
    /// exactly as the live indexer must.
    struct FakeIndexer: DocumentIndexer {
        let recorder: Recorder
        let sleepNanos: UInt64
        func embed(_ id: UUID) async { await run(.init(phase: .embedding, id: id)) }
        func buildRaptor(_ id: UUID) async { await run(.init(phase: .raptor, id: id)) }
        private func run(_ s: Step) async {
            await recorder.enter(s)
            try? await Task.sleep(nanoseconds: sleepNanos)
            await recorder.exit(s, cancelled: Task.isCancelled)
        }
    }

    // MARK: Helpers

    private func waitUntilIdle(_ queue: DocumentIndexingQueue,
                               timeoutMs: Int = 6000) async {
        for _ in 0..<(timeoutMs / 5) {
            let s = await queue.snapshot()
            if s.current == nil && s.embedQueue.isEmpty && s.raptorQueue.isEmpty { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("queue did not reach idle within \(timeoutMs)ms")
    }

    // MARK: Tests

    /// THE central guarantee: submit 4 documents at once → exactly one pass at a
    /// time, ALL embeddings (in FIFO order) before ANY RAPTOR (in FIFO order).
    func testEmbedAllBeforeRaptor_oneAtATime_fifo() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 3_000_000))

        let ids = (0..<4).map { _ in UUID() }
        for id in ids { await queue.enqueue(id) }
        await waitUntilIdle(queue)

        let peak = await recorder.maxConcurrent
        XCTAssertEqual(peak, 1, "exactly one document-pass at a time")

        let steps = await recorder.steps
        let expected = ids.map { Step(phase: .embedding, id: $0) }
                     + ids.map { Step(phase: .raptor, id: $0) }
        XCTAssertEqual(steps, expected,
                       "all embeds (FIFO) must run before all RAPTOR (FIFO)")
    }

    /// A document imported mid-RAPTOR embeds BEFORE the remaining RAPTOR work —
    /// embedding always preempts deepening (at the next document boundary).
    func testNewImportPreemptsPendingRaptor() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 30_000_000))

        let a = UUID(), b = UUID()
        await queue.enqueue(a)
        await queue.enqueue(b)
        // a,b embed (FIFO), then a's RAPTOR starts. Inject c during the RAPTOR
        // phase — it must embed before b's RAPTOR.
        try? await Task.sleep(nanoseconds: 75_000_000) // ~ into a's RAPTOR
        let c = UUID()
        await queue.enqueue(c)
        await waitUntilIdle(queue)

        let steps = await recorder.steps
        let idxCEmbed = steps.firstIndex(of: Step(phase: .embedding, id: c))
        let idxBRaptor = steps.firstIndex(of: Step(phase: .raptor, id: b))
        XCTAssertNotNil(idxCEmbed, "c must embed")
        XCTAssertNotNil(idxBRaptor, "b must get RAPTOR")
        if let e = idxCEmbed, let r = idxBRaptor {
            XCTAssertLessThan(e, r, "a newly imported doc embeds before remaining RAPTOR")
        }
        let peak = await recorder.maxConcurrent
        XCTAssertEqual(peak, 1, "still one pass at a time")
    }

    /// `enqueueRaptorOnly` (the on-launch sweep of already-embedded docs) runs
    /// only the RAPTOR pass, no embed.
    func testRaptorOnlyLaneSkipsEmbed() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 3_000_000))

        let id = UUID()
        await queue.enqueueRaptorOnly(id)
        await waitUntilIdle(queue)

        let steps = await recorder.steps
        XCTAssertEqual(steps, [Step(phase: .raptor, id: id)],
                       "raptor-only lane runs RAPTOR with no embed")
    }

    /// A re-enqueue of a document still in the embed lane is a no-op (no double
    /// run).
    func testIdempotentEnqueue() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 50_000_000))

        let id = UUID()
        await queue.enqueue(id)
        await queue.enqueue(id)
        await queue.enqueue(id)
        await waitUntilIdle(queue)

        let steps = await recorder.steps
        let embeds = steps.filter { $0 == Step(phase: .embedding, id: id) }
        XCTAssertEqual(embeds.count, 1, "a re-enqueued document must not embed twice")
    }

    /// 2026-06-19 regression: work enqueued BEFORE `configure(indexer:)` must
    /// survive and run once the indexer lands — not be silently dropped. This
    /// reproduces the antenna-races-launch window (the antenna server starts
    /// from `LibraryView.onAppear`, unordered vs. `PoseyApp.task`'s configure):
    /// a REINDEX/import in that window enqueued against a nil indexer and the
    /// drain loop used to dequeue it into a no-op job and discard it, leaving
    /// the document stuck at "Preparing" with no recovery.
    func testEnqueueBeforeConfigureStillIndexes() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()

        // Enqueue BEFORE the indexer is wired (the race window). The item must
        // sit in the lane, NOT be consumed.
        let a = UUID(), b = UUID()
        await queue.enqueue(a)
        await queue.enqueueRaptorOnly(b)
        // Give any erroneously-kicked drain a chance to (wrongly) consume it.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let pre = await queue.snapshot()
        XCTAssertNil(pre.current, "nothing runs before the indexer is configured")
        XCTAssertEqual(pre.embedQueue, [a], "pre-wire embed enqueue is held, not dropped")
        XCTAssertEqual(pre.raptorQueue, [b], "pre-wire raptor enqueue is held, not dropped")

        // Wire the indexer — this must drain the deferred work.
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 3_000_000))
        await waitUntilIdle(queue)

        let embedded = Set(await recorder.steps.filter { $0.phase == .embedding }.map { $0.id })
        let raptored = Set(await recorder.steps.filter { $0.phase == .raptor }.map { $0.id })
        XCTAssertTrue(embedded.contains(a), "the pre-wire embed runs after configure")
        XCTAssertTrue(raptored.contains(b), "the pre-wire raptor-only runs after configure")
    }

    /// The escape switch: cancel the in-flight pass and clear both lanes,
    /// returning all affected IDs.
    func testExpungeAllHaltsInFlightAndClearsBothLanes() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 200_000_000))

        let ids = (0..<5).map { _ in UUID() }
        for id in ids { await queue.enqueue(id) }
        try? await Task.sleep(nanoseconds: 30_000_000) // first doc in-flight (embedding)

        let affected = await queue.expungeAll()
        XCTAssertEqual(Set(affected), Set(ids),
                       "expunge reports the in-flight doc plus all queued docs")

        await waitUntilIdle(queue)
        let s = await queue.snapshot()
        XCTAssertNil(s.current)
        XCTAssertTrue(s.embedQueue.isEmpty && s.raptorQueue.isEmpty, "both lanes cleared")

        let cancelledMid = await recorder.cancelledMidPass
        XCTAssertEqual(cancelledMid, [Step(phase: .embedding, id: ids.first!)],
                       "exactly the in-flight doc is halted mid-pass")
        let steps = await recorder.steps
        XCTAssertEqual(steps, [Step(phase: .embedding, id: ids.first!)],
                       "no queued doc ran, and no RAPTOR was scheduled after the halt")
    }

    /// Per-document cancel drops a still-queued document from the embed lane so
    /// it never runs.
    func testCancelQueuedDocumentNeverRuns() async {
        let recorder = Recorder()
        let queue = DocumentIndexingQueue()
        await queue.configure(indexer: FakeIndexer(recorder: recorder, sleepNanos: 40_000_000))

        let ids = (0..<4).map { _ in UUID() }
        for id in ids { await queue.enqueue(id) }
        await queue.cancel(ids[2]) // still queued behind ids[0]'s embed
        await waitUntilIdle(queue)

        let embedded = Set(await recorder.steps.filter { $0.phase == .embedding }.map { $0.id })
        XCTAssertFalse(embedded.contains(ids[2]), "a cancelled queued document must never embed")
        XCTAssertEqual(embedded, Set([ids[0], ids[1], ids[3]]), "the others still embed")
    }
}
