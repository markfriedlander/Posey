import Foundation
import PDFKit

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
    /// 2026-05-22 Phase 2.2 Step 7 — the embedding index is held here
    /// so the enhancement runner can trigger indexing at end-of-Tier-3
    /// on the corrected text rather than at persistence-time on the
    /// Tier 1 first pass.
    private var embeddingIndex: DocumentEmbeddingIndex?

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
    /// in a fresh DB mid-session). The `embeddingIndex` is optional
    /// — when present the runner triggers indexing on the final
    /// corrected text at end-of-Tier-3 instead of at persistence
    /// time (Phase 2.2 Step 7).
    func configure(databaseManager: DatabaseManager,
                   embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
        dbgLog("PDFEnhancementService: configured (embeddingIndex=%@)",
               embeddingIndex == nil ? "nil" : "set")
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
    /// **Step 5 (this commit):** runs Tier 2 (Vision OCR + reconciler
    /// + streaming chunk replacement with reader-aware priority + TTS
    /// + viewport locks). Tier 3 stub remains — Step 6 fills it in.
    private func processDocument(_ documentID: UUID) async {
        guard let db = databaseManager else {
            dbgLog("PDFEnhancementService: processDocument(%@) skipped — no databaseManager",
                   documentID.uuidString)
            return
        }

        // Cancellation gate before any work.
        if cancelled.contains(documentID) {
            cancelled.remove(documentID)
            return
        }

        // Mark tier2 status. Best-effort; failures log but the work
        // still runs.
        do {
            try await MainActor.run {
                try db.updateEnhancementState(documentID: documentID, status: "tier2", error: nil)
            }
        } catch {
            dbgLog("PDFEnhancementService: failed to set tier2 status for %@: %@",
                   documentID.uuidString, String(describing: error))
        }

        await runTier2(documentID: documentID)

        if cancelled.contains(documentID) {
            cancelled.remove(documentID)
            return
        }

        // Tier 3 — AFM fusion repair. Mark status, run, then
        // transition to complete.
        do {
            try await MainActor.run {
                try db.updateEnhancementState(documentID: documentID, status: "tier3", error: nil)
            }
        } catch {
            dbgLog("PDFEnhancementService: failed to set tier3 status for %@: %@",
                   documentID.uuidString, String(describing: error))
        }

        await runTier3(documentID: documentID)

        if cancelled.contains(documentID) {
            cancelled.remove(documentID)
            return
        }

        do {
            try await MainActor.run {
                try db.updateEnhancementState(documentID: documentID, status: "complete", error: nil)
            }
            // Source PDF no longer needed once enhancement is done.
            PDFSourceStore.delete(documentID)

            // Step 7 — trigger embedding indexing on the corrected
            // text. PDFLibraryImporter.persistDocument no longer
            // enqueues this for PDFs precisely so we can defer to
            // here. If `embeddingIndex` wasn't wired we fall back
            // to no-op + log (the doc will still be readable, just
            // without Ask Posey RAG until a re-import).
            if let index = embeddingIndex {
                let doc: Document?
                do {
                    doc = try await MainActor.run { () throws -> Document? in
                        try db.documents().first(where: { $0.id == documentID })
                    }
                } catch {
                    dbgLog("PDFEnhancementService: failed to load doc for embedding handoff: %@",
                           String(describing: error))
                    doc = nil
                }
                if let doc {
                    await MainActor.run {
                        index.enqueueIndexing(doc)
                    }
                    dbgLog("PDFEnhancementService: embedding indexing enqueued for %@",
                           documentID.uuidString)
                }
            } else {
                dbgLog("PDFEnhancementService: no embeddingIndex wired; skipped indexing handoff for %@",
                       documentID.uuidString)
            }

            // Step 7 — post completion notification so the library
            // view can refresh the stale character count + any
            // future "enhancement complete" indicator.
            await MainActor.run {
                NotificationCenter.default.post(
                    name: PDFEnhancementService.enhancementDidComplete,
                    object: nil,
                    userInfo: [
                        PDFEnhancementService.notificationDocumentIDKey: documentID
                    ]
                )
            }
        } catch {
            dbgLog("PDFEnhancementService: failed to mark complete for %@: %@",
                   documentID.uuidString, String(describing: error))
        }
    }

    // MARK: Notifications

    /// Posted on the main thread when a document transitions to
    /// `enhancement_status = 'complete'`. `userInfo` includes the
    /// document UUID under `notificationDocumentIDKey`. Library /
    /// Reader views subscribe to refresh stale state.
    static let enhancementDidComplete = Notification.Name(
        "Posey.PDFEnhancementService.didComplete"
    )
    static let notificationDocumentIDKey = "documentID"

    // MARK: Tier 3 — AFM fusion repair

    /// Run Tier 3 (AFM fusion-token correction) on the document.
    /// Detects suspect tokens via `SuspectTokenDetector`, skips any
    /// already-corrected ones (idempotency via
    /// `document_afm_corrections`), and for each remaining token:
    /// asks AFM via `FusionCorrectionAFM.correct`, records the
    /// verdict, and (if AFM proposed a change) applies the swap
    /// across the whole document via `DatabaseManager.replaceTokenInDocument`.
    ///
    /// Sequential per Mark's directive — one token per AFM call (Rule
    /// 6: local inference is free; batching gives no quality benefit
    /// for a per-token decision and costs prompt clarity). The actor
    /// isolation provides natural pacing without an explicit
    /// cooldown (matches Phase B chunk enhancement).
    private func runTier3(documentID: UUID) async {
        guard let db = databaseManager else { return }

        let plainText: String
        do {
            plainText = try await MainActor.run {
                try db.plainText(for: documentID) ?? ""
            }
        } catch {
            dbgLog("PDFEnhancementService: Tier 3 — failed to read plainText for %@: %@",
                   documentID.uuidString, String(describing: error))
            return
        }
        if plainText.isEmpty {
            dbgLog("PDFEnhancementService: Tier 3 skipped — empty plainText on %@",
                   documentID.uuidString)
            return
        }

        let allSuspects = SuspectTokenDetector.detect(in: plainText)
        if allSuspects.isEmpty {
            dbgLog("PDFEnhancementService: Tier 3 — no suspect tokens on %@",
                   documentID.uuidString)
            return
        }

        let alreadyProcessed: Set<String>
        do {
            alreadyProcessed = try await MainActor.run {
                try db.existingAFMCorrections(for: documentID)
            }
        } catch {
            dbgLog("PDFEnhancementService: Tier 3 — failed to read corrections for %@: %@",
                   documentID.uuidString, String(describing: error))
            return
        }

        let toProcess = allSuspects.filter { !alreadyProcessed.contains($0) }
        if toProcess.isEmpty {
            dbgLog("PDFEnhancementService: Tier 3 — every suspect already processed on %@",
                   documentID.uuidString)
            return
        }
        dbgLog("PDFEnhancementService: Tier 3 starting on %@ — %d suspect tokens (already done %d, total %d)",
               documentID.uuidString, toProcess.count, alreadyProcessed.count, allSuspects.count)

        // Determine embedding kind for re-embeds on chunks the swap
        // touches. Same logic as Tier 2.
        let existingChunks: [StoredDocumentChunk]
        do {
            existingChunks = try await MainActor.run { try db.chunks(for: documentID) }
        } catch {
            dbgLog("PDFEnhancementService: Tier 3 — failed to read chunks for %@: %@",
                   documentID.uuidString, String(describing: error))
            return
        }
        // Tier 3 no longer re-embeds chunks inline (rebuild step 7b)
        // — chunk-table embeddings are derived from units and will be
        // regenerated by the unit-aware embedding chunker (step 8).
        _ = existingChunks

        var processedCount = 0
        var appliedCount = 0
        for token in toProcess {
            if cancelled.contains(documentID) {
                dbgLog("PDFEnhancementService: Tier 3 cancelled mid-run on %@",
                       documentID.uuidString)
                return
            }

            let verdict = await FusionCorrectionAFM.correct(token)
            guard let corrected = verdict else {
                // AFM unavailable or refused — skip silently.
                dbgLog("PDFEnhancementService: Tier 3 — AFM returned nil for token '%@'", token)
                processedCount += 1
                continue
            }

            // Record the verdict regardless of whether it differs —
            // ensures the same token isn't re-asked next run.
            do {
                try await MainActor.run {
                    try db.recordAFMCorrection(
                        documentID: documentID,
                        original: token,
                        corrected: corrected
                    )
                }
            } catch {
                dbgLog("PDFEnhancementService: Tier 3 — failed to record correction '%@' → '%@': %@",
                       token, corrected, String(describing: error))
            }

            processedCount += 1
            if corrected == token { continue }

            // Apply the swap atomically across the document via the
            // unit-based replacement (rebuild step 7b). Sentences for
            // affected units regenerate in the same transaction;
            // derived plain_text / display_text refresh once at end.
            do {
                let result = try await MainActor.run {
                    try db.replaceTokenInUnits(
                        documentID: documentID,
                        original: token,
                        corrected: corrected,
                        sourceTier: "tier3_afm"
                    )
                }
                if result.unitsTouched > 0 {
                    appliedCount += 1
                    dbgLog("PDFEnhancementService: Tier 3 — '%@' → '%@' on %@ (occurrences=%d units=%d)",
                           token, corrected, documentID.uuidString,
                           result.totalOccurrences, result.unitsTouched)
                }
            } catch {
                dbgLog("PDFEnhancementService: Tier 3 — swap failed for '%@' → '%@': %@",
                       token, corrected, String(describing: error))
            }

            // Persist running count for diagnostics. Snapshot the
            // value into a let so the MainActor.run closure captures
            // by value (Swift 6 concurrency requirement).
            let runningCount = processedCount
            do {
                try await MainActor.run {
                    try db.updateEnhancementState(
                        documentID: documentID,
                        status: "tier3",
                        tier3TokensDone: runningCount,
                        error: nil
                    )
                }
            } catch { /* best-effort */ }
        }

        dbgLog("PDFEnhancementService: Tier 3 finished on %@ — processed %d, applied %d swaps",
               documentID.uuidString, processedCount, appliedCount)
    }

    // MARK: Tier 2 — Vision rescue with streaming chunk replacement

    /// Maximum times a single page can be deferred due to TTS/viewport
    /// locks before we give up and apply the update anyway. Defensive
    /// cap on an edge case (a chunk persistently visible / always
    /// being spoken).
    private static let maxLockDeferralsPerPage = 8

    /// Run Tier 2 (Vision OCR + reconciler) on every flagged page in
    /// the document that hasn't already been processed. Reader-aware
    /// priority ordering: pages whose chunks contain or sit near the
    /// reader's current position go first; pages far from the reader
    /// update in the background.
    private func runTier2(documentID: UUID) async {
        guard let db = databaseManager else { return }

        // ── Load source PDF ──────────────────────────────────────
        guard let pdfData = PDFSourceStore.read(documentID),
              let document = PDFDocument(data: pdfData) else {
            dbgLog("PDFEnhancementService: Tier 2 skipped for %@ — source PDF unavailable",
                   documentID.uuidString)
            return
        }

        // ── Load page flags + already-done set ──────────────────
        guard let flagsRecord = PageFlagsStore.read(documentID: documentID) else {
            dbgLog("PDFEnhancementService: Tier 2 skipped for %@ — no page flags",
                   documentID.uuidString)
            return
        }
        let allFlagged: [PDFPageFlags] = flagsRecord.flags.filter { $0.needsTier2 }
        if allFlagged.isEmpty {
            dbgLog("PDFEnhancementService: Tier 2 — no flagged pages on %@",
                   documentID.uuidString)
            return
        }
        let statusRow: DatabaseManager.EnhancementStatusRow?
        do {
            statusRow = try await MainActor.run {
                try db.enhancementStatus(for: documentID)
            }
        } catch {
            dbgLog("PDFEnhancementService: failed to read status for %@: %@",
                   documentID.uuidString, String(describing: error))
            return
        }
        var pagesDone: Set<Int> = {
            guard let row = statusRow,
                  let data = row.tier2PagesDoneJSON.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([Int].self, from: data) else {
                return []
            }
            return Set(arr)
        }()
        let toProcess: [PDFPageFlags] = allFlagged.filter { !pagesDone.contains($0.pageIndex) }
        if toProcess.isEmpty {
            dbgLog("PDFEnhancementService: Tier 2 — every flagged page already done on %@",
                   documentID.uuidString)
            return
        }
        dbgLog("PDFEnhancementService: Tier 2 starting on %@ — %d pages (already-done %d, total flagged %d)",
               documentID.uuidString, toProcess.count, pagesDone.count, allFlagged.count)

        // ── Determine embedding kind from existing chunks ───────
        let existingChunks: [StoredDocumentChunk]
        do {
            existingChunks = try await MainActor.run {
                try db.chunks(for: documentID)
            }
        } catch {
            dbgLog("PDFEnhancementService: failed to read existing chunks for %@: %@",
                   documentID.uuidString, String(describing: error))
            return
        }
        // Tier 2 no longer re-embeds chunks inline (rebuild step 7b)
        // — chunk-table embeddings are derived from units and get
        // regenerated by the unit-aware embedding chunker (step 8).
        _ = existingChunks

        // ── Work loop with priority + locks + cancellation ──────
        var deferralCounts: [Int: Int] = [:]  // pageIndex → defer count
        var workQueue: [PDFPageFlags] = toProcess

        while !workQueue.isEmpty {
            if cancelled.contains(documentID) {
                dbgLog("PDFEnhancementService: Tier 2 cancelled mid-run on %@",
                       documentID.uuidString)
                return
            }

            // Snapshot reader state for priority + locks.
            let snapshot: ReaderObservation.Snapshot = await ReaderObservation.shared.snapshot()
            let boundaries: [Int]
            do {
                boundaries = try await MainActor.run { try db.contentBoundaries(for: documentID) }
            } catch {
                dbgLog("PDFEnhancementService: failed to read boundaries: %@", String(describing: error))
                return
            }

            // Compute reader's page (if doc is open + offset known).
            let readerPage: Int? = {
                guard snapshot.openDocumentID == documentID,
                      let offset = snapshot.currentOffset,
                      !boundaries.isEmpty else { return nil }
                var i = 0
                for (idx, b) in boundaries.enumerated() {
                    if offset >= b { i = idx } else { break }
                }
                return i
            }()

            // Sort the queue by priority. If we have a reader page,
            // smaller |pageIndex - readerPage| wins. Otherwise
            // sequential by pageIndex.
            workQueue.sort { a, b in
                if let rp = readerPage {
                    let da = abs(a.pageIndex - rp)
                    let db_ = abs(b.pageIndex - rp)
                    if da != db_ { return da < db_ }
                }
                return a.pageIndex < b.pageIndex
            }

            // Try the highest-priority page; if locked, defer to back
            // of queue and try the next one.
            var pickedIndex: Int? = nil
            for (qi, page) in workQueue.enumerated() {
                if !pageIsLockedForUpdate(page.pageIndex,
                                          boundaries: boundaries,
                                          chunks: existingChunks,
                                          documentID: documentID,
                                          snapshot: snapshot) {
                    pickedIndex = qi
                    break
                }
                // Otherwise increment defer count; if maxed out,
                // accept the page anyway (defensive).
                let cnt = (deferralCounts[page.pageIndex] ?? 0) + 1
                deferralCounts[page.pageIndex] = cnt
                if cnt >= Self.maxLockDeferralsPerPage {
                    dbgLog("PDFEnhancementService: page %d hit defer cap on %@ — applying anyway",
                           page.pageIndex, documentID.uuidString)
                    pickedIndex = qi
                    break
                }
            }
            guard let qIndex = pickedIndex else {
                // Every page locked — wait briefly, retry.
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            let page = workQueue.remove(at: qIndex)

            // ── Run Vision on the chosen page ──────────────────
            guard let pdfPage = document.page(at: page.pageIndex) else {
                dbgLog("PDFEnhancementService: page(at: %d) is nil on %@",
                       page.pageIndex, documentID.uuidString)
                pagesDone.insert(page.pageIndex)
                await persistPagesDone(pagesDone, for: documentID, db: db)
                continue
            }

            let visionText = PDFTier2VisionExtractor.extract(pdfPage)

            // Read current page text from plainText slice for the
            // reconciler comparison.
            let pageOldText: String
            do {
                pageOldText = try await MainActor.run { () throws -> String in
                    let pt = try db.plainText(for: documentID) ?? ""
                    let bs = try db.contentBoundaries(for: documentID)
                    guard page.pageIndex < bs.count else { return "" }
                    let lo = bs[page.pageIndex]
                    let hi = (page.pageIndex + 1 < bs.count) ? bs[page.pageIndex + 1] : pt.count
                    guard lo <= hi, hi <= pt.count else { return "" }
                    let s = pt.index(pt.startIndex, offsetBy: lo)
                    let e = pt.index(pt.startIndex, offsetBy: hi)
                    return String(pt[s..<e])
                }
            } catch {
                dbgLog("PDFEnhancementService: failed to read page %d text for %@: %@",
                       page.pageIndex, documentID.uuidString, String(describing: error))
                continue
            }

            let mergeResult = PDFTier12Reconciler.merge(
                tier1: pageOldText,
                tier2: visionText,
                mode: page.tier2Mode
            )

            if mergeResult.decision == .visionWon {
                dbgLog("PDFEnhancementService: page %d on %@ → vision_won (%d → %d chars)",
                       page.pageIndex, documentID.uuidString,
                       pageOldText.count, mergeResult.text.count)
                // Apply the page rewrite atomically via the unit-based
                // replacement (rebuild step 7b). Page content units
                // (between consecutive pageBreak units) are swapped
                // for new prose units derived from the Vision text;
                // sentences regenerate; derived plain_text refreshes.
                do {
                    let result = try await MainActor.run { () throws -> DatabaseManager.ReplacePageUnitsResult in
                        try db.replaceUnitsForPage(
                            documentID: documentID,
                            pageNumber: page.pageIndex,
                            newPageText: mergeResult.text,
                            sourceTier: "tier2_vision"
                        )
                    }
                    dbgLog("PDFEnhancementService: page %d unit rewrite removed=%d inserted=%d",
                           page.pageIndex, result.removedUnitCount, result.insertedUnitCount)
                } catch {
                    dbgLog("PDFEnhancementService: page %d rewrite failed for %@: %@",
                           page.pageIndex, documentID.uuidString, String(describing: error))
                }
            } else {
                dbgLog("PDFEnhancementService: page %d on %@ → %@ (kept tier 1)",
                       page.pageIndex, documentID.uuidString, mergeResult.decision.rawValue)
            }

            pagesDone.insert(page.pageIndex)
            await persistPagesDone(pagesDone, for: documentID, db: db)
        }

        dbgLog("PDFEnhancementService: Tier 2 finished on %@", documentID.uuidString)
    }

    /// True iff updating page `pageIndex` would touch a chunk the
    /// reader is currently rendering or TTS is currently speaking.
    private func pageIsLockedForUpdate(
        _ pageIndex: Int,
        boundaries: [Int],
        chunks: [StoredDocumentChunk],
        documentID: UUID,
        snapshot: ReaderObservation.Snapshot
    ) -> Bool {
        // Compute the plainText range for this page.
        guard pageIndex < boundaries.count else { return false }
        let lo = boundaries[pageIndex]
        let hi = (pageIndex + 1 < boundaries.count) ? boundaries[pageIndex + 1] : Int.max
        let overlapping = chunks.filter { $0.startOffset < hi && $0.endOffset > lo }
        // Only check locks if this is the document the reader has open.
        guard snapshot.openDocumentID == documentID else { return false }
        for chunk in overlapping {
            let chunkID = ReaderObservation.ChunkID(
                documentID: documentID, chunkIndex: chunk.chunkIndex
            )
            if snapshot.ttsInUseChunk == chunkID { return true }
            if snapshot.visibleChunks.contains(chunkID) { return true }
        }
        return false
    }

    /// Persist the tier2_pages_done set as JSON, best-effort.
    private func persistPagesDone(_ pages: Set<Int>, for documentID: UUID, db: DatabaseManager) async {
        let sorted = pages.sorted()
        let json = (try? JSONEncoder().encode(sorted))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        do {
            try await MainActor.run {
                try db.updateEnhancementState(
                    documentID: documentID,
                    status: "tier2",
                    tier2PagesDoneJSON: json,
                    error: nil
                )
            }
        } catch {
            dbgLog("PDFEnhancementService: persistPagesDone failed for %@: %@",
                   documentID.uuidString, String(describing: error))
        }
    }

    // MARK: Segmenter + embedder hookup

    /// Re-segment `text` into chunks via the same sentence-aware
    /// chunker `DocumentEmbeddingIndex` uses, then embed each chunk
    /// against the document's existing embedding kind so retrieval
    /// stays consistent. Static helper — no actor isolation needed.
    nonisolated static func segmentAndEmbed(text: String, kind: String) -> [StoredDocumentChunk] {
        let cfg = DocumentEmbeddingIndexConfiguration.default
        let chunks = DocumentEmbeddingIndex.chunk(text, configuration: cfg)
        return chunks.map { c in
            let vector = DocumentEmbeddingIndex.embedTextWithKind(text: c.text, kind: kind)
            return StoredDocumentChunk(
                chunkIndex: c.chunkIndex,
                startOffset: c.startOffset,
                endOffset: c.endOffset,
                text: c.text,
                embedding: vector,
                embeddingKind: kind,
                pageStart: 0, pageEnd: 0, revision: 0, sourceTier: "tier2_vision"
            )
        }
    }
}

// ========== BLOCK 01: PDF ENHANCEMENT SERVICE - END ==========
