import Foundation

// ========== BLOCK 01: PDF ENHANCEMENT SERVICE - START ==========

/// Phase 2.2 background enhancement pipeline owner.
///
/// **Step 3 scope (this file):** actor skeleton + DB-backed state
/// helpers + cancellation set + bootstrap. **No tier work runs yet.**
/// Step 5 (Tier 2 Vision runner) and Step 6 (Tier 3 AFM fusion repair)
/// will fill in `runTier2(...)` and `runTier3(...)` respectively. The
/// shape here lets Step 4 enqueue documents post-persistence without
/// blocking on the work being implemented.
///
/// Why an actor: gives us free serialization on the queue + on the
/// cancellation set. Mirrors `DocumentEmbeddingIndex`'s pattern of a
/// nonisolated outer container with an actor-isolated state core.
/// Single global instance owned by the app and configured at launch
/// with the live `DatabaseManager`.
///
/// State model (per document, persisted in `documents.enhancement_status`):
///
///   na        Nothing to enhance — non-PDF, or PDF with zero flagged
///             pages AND zero Tier 3 suspect tokens.
///   pending   Enqueued but not yet started.
///   tier2     Tier 2 (Vision) currently running.
///   tier3     Tier 3 (AFM fusion repair) currently running.
///   complete  Both tiers finished (or one finished and the other had
///             nothing to do).
///   failed    Aborted. See `documents.enhancement_error`.
///
/// Resume semantics on app launch (`bootstrap()`):
///   - `pending`         → start from the beginning
///   - `tier2`           → resume from the first flagged page not in
///                         `tier2_pages_done`
///   - `tier3`           → restart from scratch (AFM is fast; not worth
///                         per-token checkpointing mid-pass)
///   - `failed`/`complete`/`na` → leave alone
///
/// All public methods are `async` because the actor's isolation is
/// awaited from the calling site. Method-internal calls into the
/// MainActor-isolated `DatabaseManager` use `await MainActor.run { ... }`.
actor PDFEnhancementService {

    // MARK: Shared instance

    /// App-wide singleton. Configured once at app launch via
    /// `configure(databaseManager:)`. Before configuration all
    /// methods log + no-op silently — safe to call from test
    /// harnesses that don't bring up the full app.
    static let shared = PDFEnhancementService()

    // MARK: State

    private var databaseManager: DatabaseManager?

    /// FIFO of document IDs waiting to be processed. We don't dedupe
    /// on enqueue — `processNext` is the gate that decides what to
    /// do with each entry.
    private var queue: [UUID] = []

    /// The document currently being processed by the drain loop, or
    /// nil if idle. Used by the bootstrap to avoid re-enqueueing
    /// something already in flight.
    private var currentDocumentID: UUID?

    /// Cancellation set. A document delete (LibraryViewModel /
    /// DELETE_DOCUMENT / RESET_ALL) adds the ID here; the runner
    /// checks at every tier boundary and bails. Matches the existing
    /// `DocumentEmbeddingIndex.cancelIndexing` pattern.
    private var cancelled: Set<UUID> = []

    /// True while `drainQueue` is actively iterating. Prevents
    /// concurrent drains from a flurry of enqueue calls — only one
    /// drain loop at a time; subsequent enqueues just append.
    private var draining: Bool = false

    private init() {}

    // MARK: Configuration

    /// Wire the live DatabaseManager. Must be called once at app
    /// launch before any enhancement work can run. Subsequent calls
    /// replace the manager (used by some test harnesses that swap
    /// in a fresh DB mid-session).
    func configure(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        dbgLog("PDFEnhancementService: configured")
    }

    // MARK: Public API

    /// Enqueue a document for background enhancement. Idempotent —
    /// already-queued and currently-processing IDs are silently
    /// skipped. Called by `PDFLibraryImporter` right after
    /// `persistParsedDocument` succeeds (Step 4 wires this in).
    func enqueue(_ documentID: UUID) {
        if currentDocumentID == documentID || queue.contains(documentID) {
            return
        }
        // Clear any prior cancellation so a re-imported document
        // (delete + re-import within the same app run) gets a fresh
        // chance.
        cancelled.remove(documentID)
        queue.append(documentID)
        dbgLog("PDFEnhancementService: enqueued %@ (queue=%d)",
               documentID.uuidString, queue.count)
        Task { await drainQueue() }
    }

    /// Cancel any in-flight or queued enhancement for the document.
    /// Mirrors `DocumentEmbeddingIndex.cancelIndexing`. Safe to call
    /// from any actor — wraps via the actor's isolation.
    func cancel(_ documentID: UUID) {
        cancelled.insert(documentID)
        queue.removeAll { $0 == documentID }
        dbgLog("PDFEnhancementService: cancelled %@", documentID.uuidString)
    }

    /// On-launch sweep. Re-enqueues documents that were mid-flight
    /// when the app last terminated (status = pending / tier2 / tier3).
    /// Called from `PoseyApp` right after the DatabaseManager is
    /// ready and before the UI binds to the library.
    func bootstrap() async {
        guard let db = databaseManager else {
            dbgLog("PDFEnhancementService: bootstrap skipped (no databaseManager)")
            return
        }
        let inFlight: [DatabaseManager.EnhancementStatusRow]
        do {
            inFlight = try await MainActor.run {
                try db.documentsByEnhancementStatus(["pending", "tier2", "tier3"])
            }
        } catch {
            dbgLog("PDFEnhancementService: bootstrap query failed: %@",
                   String(describing: error))
            return
        }
        for row in inFlight {
            enqueue(row.documentID)
        }
        dbgLog("PDFEnhancementService: bootstrap re-enqueued %d documents",
               inFlight.count)
    }

    // MARK: Inspection (used by GET_ENHANCEMENT_STATUS in Step 7)

    /// Snapshot of in-memory queue state for diagnostics.
    func snapshot() -> (queue: [UUID], current: UUID?, cancelled: [UUID]) {
        (queue, currentDocumentID, Array(cancelled))
    }

    // MARK: Drain loop

    /// Iteratively pop documents from the queue and process each.
    /// Re-entrant-safe via the `draining` flag — only one loop runs
    /// at a time even under heavy enqueue pressure.
    private func drainQueue() async {
        if draining { return }
        draining = true
        defer { draining = false }

        while !queue.isEmpty {
            let next = queue.removeFirst()
            if cancelled.contains(next) {
                cancelled.remove(next)
                continue
            }
            currentDocumentID = next
            await processDocument(next)
            currentDocumentID = nil
            // Re-check cancellation between docs — a delete during
            // tier work for doc A may have queued doc B and cancelled
            // doc C; we want to honor C's cancel before reaching it.
        }
    }

    /// Process a single document through Tier 2 → Tier 3 → embedding.
    /// **Step 3 stub:** logs and writes a `complete` status. The real
    /// tier work lands in Steps 5 + 6 + 7.
    private func processDocument(_ documentID: UUID) async {
        dbgLog("PDFEnhancementService: would process %@ (Step 3 stub — no tier work yet)",
               documentID.uuidString)
        // Don't transition status yet — Step 4 introduces the
        // 'pending' state at persistence; Steps 5/6/7 advance it.
        // Step 3 ships the actor skeleton only.
    }
}

// ========== BLOCK 01: PDF ENHANCEMENT SERVICE - END ==========
