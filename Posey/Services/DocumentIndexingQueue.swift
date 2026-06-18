import Foundation

// ========== BLOCK 01: DOCUMENT INDEXER SEAM - START ==========

/// The per-document indexing work that `DocumentIndexingQueue` serializes.
///
/// **Why a seam.** Production wires this to the real pipeline — build chunks +
/// embed every leaf (`UnitEmbeddingService`) then build the summary tree
/// (`RaptorTreeService`). Tests inject a fake to prove the queue's ordering and
/// one-at-a-time guarantee WITHOUT a database or any model, so the central
/// safety property is verifiable entirely off-device.
///
/// **Contract.** `indexDocument` MUST run the document's WHOLE pipeline and
/// return only when that document is fully indexed (or cancelled). That return
/// is what makes "one document fully done before the next starts" real — the
/// queue awaits it before popping the next ID.
///
/// **Cooperative cancellation.** The implementation MUST honor `Task`
/// cancellation: check `Task.isCancelled` at fine granularity (every chunk /
/// between summaries) and return promptly when asked. The escape switch and
/// per-document cancel both work by cancelling the in-flight `Task`, so a halt
/// only lands as fast as the implementation checks — fine-grained checks are
/// what let a halt land in ~1–2s even under sustained load (the specific
/// failure of the antenna `RESET_ALL` during the 2026-06-17 incident was that
/// it had no fast cooperative-cancel path and waited on the pegged phone).
protocol DocumentIndexer: Sendable {
    func indexDocument(_ documentID: UUID) async
}

// ========== BLOCK 01: DOCUMENT INDEXER SEAM - END ==========


// ========== BLOCK 02: DOCUMENT INDEXING QUEUE - START ==========

/// The single front door for ALL background document indexing — the
/// document-level serial gate.
///
/// **Why this exists (2026-06-18, post-incident).** `HeavyWorkLane` serializes
/// heavy compute at *single-op* granularity (one embed / one summary app-wide),
/// which prevents memory-jetsam stacking but lets documents **interleave**
/// chunk-by-chunk, and it has no admission control. On 2026-06-17 a three-book
/// batch import poured ~5,000 embed ops + RAPTOR through the lane back-to-back
/// and the phone overheated to unusable. The lane's guarantee is "one op at a
/// time," never "okay to dump 5,000 ops." This queue adds the missing layer:
/// it admits **exactly ONE document at a time** and runs that document's entire
/// pipeline (extract → embed → RAPTOR) to completion before the next document
/// starts — so no operator action (antenna or file-picker, 1 doc or 10) can
/// stack work on the device. `HeavyWorkLane` stays underneath as
/// defense-in-depth; this queue is the primary admission gate.
///
/// **State model.** Mirrors `RaptorTreeService` / `PDFEnhancementService`
/// deliberately (same idiom): a FIFO `queue`, a `currentDocumentID`, a
/// `cancelled` set, and a `draining` re-entrancy guard. The one addition is
/// `currentJob` — the `Task` running the in-flight document — held so the
/// escape switch / per-doc cancel can cancel it and halt mid-document.
///
/// **Not yet wired (increment 1a).** This actor and its proof tests land first,
/// unwired, changing no runtime behavior. Increment 1b injects the live indexer
/// (awaitable embed + RAPTOR) and reroutes the importer enqueue call-sites
/// through `enqueue`. Pillar 2 (thermal pacing) lives inside the live indexer's
/// per-chunk loop; Pillar 4 (queue-aware status) reads `snapshot()`.
actor DocumentIndexingQueue {

    // MARK: Shared instance

    /// App-wide singleton. Configured once at launch via `configure(indexer:)`.
    /// Before configuration `enqueue` runs each document as an instant no-op
    /// (nothing to index without a wired pipeline), so it is always safe to
    /// call.
    static let shared = DocumentIndexingQueue()

    // MARK: Injected work

    private var indexer: DocumentIndexer?

    // MARK: State (mirrors RaptorTreeService / PDFEnhancementService)

    /// FIFO of document IDs awaiting full indexing.
    private var queue: [UUID] = []
    /// The document currently indexing, or nil if idle.
    private var currentDocumentID: UUID?
    /// IDs cancelled (per-doc delete / escape switch) — checked before work.
    private var cancelled: Set<UUID> = []
    /// True while `drainQueue` is iterating — only one drain loop at a time.
    private var draining = false
    /// The `Task` running the in-flight document's pipeline. Cancelled by the
    /// escape switch / per-doc cancel so a halt lands fast even mid-document.
    private var currentJob: Task<Void, Never>?

    /// Internal (not private) so `@testable` unit tests can construct a fresh,
    /// isolated instance per test. Production always uses `.shared`.
    init() {}

    // MARK: Configuration

    /// Wire the live per-document pipeline. Called once at launch.
    func configure(indexer: DocumentIndexer) {
        self.indexer = indexer
        dbgLog("DocumentIndexingQueue: configured")
    }

    // MARK: Public API

    /// Enqueue a document for full background indexing. Idempotent — an ID
    /// already queued or in flight is skipped. The work runs strictly after
    /// every document ahead of it has fully finished.
    func enqueue(_ documentID: UUID) {
        if currentDocumentID == documentID || queue.contains(documentID) { return }
        cancelled.remove(documentID)
        queue.append(documentID)
        dbgLog("DocumentIndexingQueue: enqueued %@ (queue=%d)",
               documentID.uuidString, queue.count)
        Task { await drainQueue() }
    }

    /// Cancel any queued or in-flight indexing for one document (document
    /// delete). If it is the in-flight document, its `Task` is cancelled so it
    /// stops promptly; queued entries are simply removed.
    func cancel(_ documentID: UUID) {
        cancelled.insert(documentID)
        queue.removeAll { $0 == documentID }
        if currentDocumentID == documentID { currentJob?.cancel() }
        dbgLog("DocumentIndexingQueue: cancelled %@", documentID.uuidString)
    }

    /// THE ESCAPE SWITCH. Halt all background indexing immediately: cancel the
    /// in-flight document's `Task` (stops heavy work within a fine-grained
    /// cancellation check — ~1–2s even under load) and clear the queue.
    ///
    /// Returns every affected document ID (the in-flight one plus everything
    /// queued) so the caller can discard each document's partial index state
    /// and mark it "needs indexing," then re-index them later through THIS same
    /// safe queue. By design this does NOT auto-resume — the device is hot when
    /// the user taps it, so re-indexing waits for the caller (once thermal is
    /// nominal again, or on a deliberate tap). Document text is untouched
    /// (written atomically at import, before any indexing), so only the index
    /// is expunged; documents remain fully readable.
    @discardableResult
    func expungeAll() -> [UUID] {
        var affected: [UUID] = []
        if let current = currentDocumentID { affected.append(current) }
        affected.append(contentsOf: queue)
        for id in affected { cancelled.insert(id) }
        queue.removeAll()
        currentJob?.cancel()
        dbgLog("DocumentIndexingQueue: EXPUNGE — halted + cleared %d document(s)",
               affected.count)
        return affected
    }

    /// Ordered snapshot for the queue-aware status surface (Pillar 4) and
    /// diagnostics: the document currently indexing (if any) followed by the
    /// queued IDs in the exact order they will run.
    func snapshot() -> (current: UUID?, queue: [UUID]) {
        (currentDocumentID, queue)
    }

    // MARK: Drain loop

    /// Pop documents off the queue and fully index each, one at a time.
    /// Re-entrant-safe via `draining`. The in-flight document runs in its own
    /// `Task` (`currentJob`) so a cancel/expunge can stop it mid-document while
    /// this loop is suspended on `await job.value`.
    private func drainQueue() async {
        if draining { return }
        draining = true
        defer { draining = false }

        while !queue.isEmpty {
            let next = queue.removeFirst()
            if cancelled.contains(next) { cancelled.remove(next); continue }
            currentDocumentID = next
            let work = indexer
            let job = Task {
                if let work { await work.indexDocument(next) }
            }
            currentJob = job
            await job.value
            currentJob = nil
            currentDocumentID = nil
            cancelled.remove(next)
        }
    }
}

// ========== BLOCK 02: DOCUMENT INDEXING QUEUE - END ==========
