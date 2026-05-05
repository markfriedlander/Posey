// BackgroundEnhancementScheduler.swift
//
// Phase B — Progressive background contextual enhancement.
//
// Walks the library's content chunks in priority order, asks AFM to
// generate a context note per chunk, re-embeds with the prepended
// note, and writes back. The result: documents get smarter over time
// while the user is reading.
//
// Mark's progressive-enhancement design (HISTORY 2026-05-05):
//   - Run continuously while the app is active.
//   - Yield immediately when the user fires an Ask Posey question.
//   - Off the main thread (well, the @MainActor calls hop briefly
//     for AFM session lifecycle, but the work is async-await-yielded).
//   - Reading-position-aware: prioritize chunks of the current
//     document at-or-after the user's reading position, then wrap
//     to chunks before that position, then move to the next document.
//   - Library-wide: keep getting smarter across the full library.
//   - Throttle on low-power / thermal pressure.
//   - Notifications drive the unified progress ring on the sparkle
//     icon (already wired in IndexingTracker).

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: NOTIFICATION NAMES - START ==========

extension Notification.Name {
    /// Fired when the scheduler starts processing a chunk.
    /// userInfo: documentID (UUID), chunkIndex (Int).
    static let chunkEnhancementDidStart = Notification.Name(
        "posey.askposey.chunkEnhancement.didStart")
    /// Fired when a chunk finishes enhancement (success).
    /// userInfo: documentID (UUID), chunkIndex (Int).
    static let chunkEnhancementDidComplete = Notification.Name(
        "posey.askposey.chunkEnhancement.didComplete")
    /// Fired when a chunk's enhancement fails. Marked ctx_status = 2;
    /// scheduler skips it on subsequent passes.
    static let chunkEnhancementDidFail = Notification.Name(
        "posey.askposey.chunkEnhancement.didFail")
    /// Fired when the scheduler completes all pending work for the
    /// current document (no more pending chunks for this docID).
    /// userInfo: documentID (UUID).
    static let chunkEnhancementDocumentDidComplete = Notification.Name(
        "posey.askposey.chunkEnhancement.documentDidComplete")

    /// Posted by ReaderView when the user's reading position changes
    /// (sentence advance, scroll, jump). userInfo: documentID (UUID),
    /// offset (Int). The scheduler subscribes and updates its
    /// reading-position-aware ordering. Posted with a debounce — not
    /// every scroll tick, just material position moves.
    static let readerPositionDidUpdate = Notification.Name(
        "posey.reader.positionDidUpdate")

    /// Posted by AskPoseyService when a user-driven AFM call begins /
    /// ends. userInfo for "begin": none. The scheduler pauses /
    /// resumes its worker around these events so AFM bandwidth is
    /// claimed by the user, not the background queue.
    static let askPoseyAFMDidBegin = Notification.Name(
        "posey.askposey.afm.didBegin")
    static let askPoseyAFMDidEnd = Notification.Name(
        "posey.askposey.afm.didEnd")
}

// ========== BLOCK 01: NOTIFICATION NAMES - END ==========


// ========== BLOCK 02: SCHEDULER - START ==========

/// Background worker that walks unenhanced content chunks across the
/// library and applies AFM-generated contextual prepends.
///
/// **Lifecycle.** Singleton-ish; one instance per app process,
/// instantiated by LibraryViewModel and held via dependency injection
/// where needed. The scheduler's worker Task runs whenever it has
/// work AND is not paused (paused by AskPoseyService for the duration
/// of a user-driven AFM call).
///
/// **Threading.** `@MainActor` because the AFM session lifecycle and
/// the chunk-enhancer closure both run there. The actual `await`
/// suspension points let other main-actor work proceed normally;
/// the work is non-blocking from the UI's perspective.
///
/// **Persistence.** Per-chunk state lives in `document_chunks.ctx_status`.
/// On app restart the scheduler picks up where it left off — pending
/// chunks resume; succeeded chunks stay succeeded.
@MainActor
final class BackgroundEnhancementScheduler {

    // MARK: Wiring

    private let database: DatabaseManager
    private let enhance: DocumentChunkContextClosure?

    /// Embedding closure. Re-embeds the enhanced chunk text using
    /// the document's existing kind so search-time grouping stays
    /// consistent. Closure-typed so the scheduler doesn't need to
    /// own the embedding-index plumbing directly.
    typealias ChunkEmbedClosure =
        @MainActor (_ text: String, _ kind: String) -> [Double]
    private let embedText: ChunkEmbedClosure

    init(database: DatabaseManager,
         enhance: DocumentChunkContextClosure?,
         embedText: @escaping ChunkEmbedClosure) {
        self.database = database
        self.enhance = enhance
        self.embedText = embedText

        // Subscribe to reader-position updates so the scheduler can
        // re-prioritize on the fly without an explicit caller.
        let nc = NotificationCenter.default
        nc.addObserver(forName: .readerPositionDidUpdate,
                       object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let id = note.userInfo?[DocumentEmbeddingIndex.notificationDocumentIDKey] as? UUID
            let offset = note.userInfo?["offset"] as? Int ?? 0
            Task { @MainActor in
                self.updateReadingPosition(documentID: id, offset: offset)
            }
        }
        // Subscribe to AskPoseyService's AFM-call brackets so we
        // automatically yield AFM bandwidth to the user. AskPoseyService
        // posts these notifications around classifyIntent / streamProseResponse.
        nc.addObserver(forName: .askPoseyAFMDidBegin,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
        nc.addObserver(forName: .askPoseyAFMDidEnd,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
    }

    // MARK: State

    /// Document the user is currently reading. Used to prioritize
    /// that document's chunks above other library docs, and to
    /// order chunks within it from the user's reading position
    /// outward.
    private(set) var currentReadingDocumentID: UUID?
    /// Character offset into currentReadingDocumentID's plainText.
    /// 0 when not yet known. Updated by the reader as it scrolls /
    /// auto-progresses.
    private(set) var currentReadingOffset: Int = 0

    /// True when the user is doing something AFM-blocking (asking
    /// Posey a question). Set by AskPoseyService at the start of
    /// classifyIntent / streamProseResponse and cleared at the end.
    /// While paused, the scheduler's worker task awaits resumption.
    private(set) var isPausedForUserAFM: Bool = false

    /// True when the scheduler has been started at least once. Used
    /// to avoid double-starting on every reading-position update.
    private var workerTask: Task<Void, Never>?

    /// Continuation used to wake the worker when isPausedForUserAFM
    /// flips back to false. nil when no worker is currently waiting.
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: Public surface

    /// Start the worker task (if not already running). Idempotent —
    /// safe to call from multiple sites (importer, reader appear,
    /// reading-position updates). The worker self-exits when there's
    /// no more pending work; the next start kicks it back up.
    func start() {
        // Skip if AFM not wired (older OS, test path).
        guard enhance != nil else { return }
        // Skip if already running.
        if let task = workerTask, !task.isCancelled {
            return
        }
        workerTask = Task { [weak self] in
            await self?.workerLoop()
        }
    }

    /// Stop the worker. Used on app backgrounding when we want to
    /// surrender CPU; the worker will re-start on next foreground.
    /// Safe to call from anywhere; idempotent.
    func stop() {
        workerTask?.cancel()
        workerTask = nil
        // Wake any paused waiters so they exit cleanly.
        for c in pauseWaiters {
            c.resume()
        }
        pauseWaiters.removeAll()
    }

    /// Update the reader's current document + offset. The scheduler
    /// uses this to prioritize work near the user's reading position.
    /// Cheap; safe to call on every scroll if needed (the worker
    /// re-reads the values lazily, not on every update).
    func updateReadingPosition(documentID: UUID?, offset: Int) {
        currentReadingDocumentID = documentID
        currentReadingOffset = offset
        // If a doc just became current and the worker isn't running,
        // start it. (The reader may have opened a doc with pending
        // chunks; we want enhancement to begin immediately.)
        start()
    }

    /// Pause for the duration of an AskPoseyService call. AskPoseyService
    /// brackets each user-driven AFM call with `pause()` and
    /// `resume()` so the scheduler yields its AFM access. AFM is
    /// effectively single-stream on-device; if we don't yield, the
    /// user's question waits behind whatever chunk we were processing,
    /// up to ~2s.
    func pause() {
        isPausedForUserAFM = true
    }

    func resume() {
        isPausedForUserAFM = false
        for c in pauseWaiters {
            c.resume()
        }
        pauseWaiters.removeAll()
    }

    // MARK: Worker loop

    private func workerLoop() async {
        while !Task.isCancelled {
            // 1) Honor the pause for user AFM. Block until resumed.
            if isPausedForUserAFM {
                await withCheckedContinuation { continuation in
                    pauseWaiters.append(continuation)
                }
                continue
            }

            // 2) Throttle: respect low-power and thermal pressure.
            //    These checks are very cheap; safe to do on every
            //    iteration. When throttled, sleep 30s and re-check.
            if shouldThrottle() {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                continue
            }

            // 3) Pick the next chunk to enhance. Order:
            //    a) currentReadingDocumentID's chunks at offset >=
            //       currentReadingOffset, ascending by chunk_index.
            //    b) currentReadingDocumentID's chunks at offset <
            //       currentReadingOffset, ascending.
            //    c) Other documents in the library with pending work.
            guard let next = pickNext() else {
                // No more work. Exit; the next reading-position
                // update or import will restart the worker.
                workerTask = nil
                return
            }

            // 4) Run enhancement for the picked chunk.
            await processChunk(documentID: next.documentID,
                               candidate: next.candidate,
                               documentSummary: next.summary,
                               documentTitle: next.title)

            // 5) Soft yield between chunks. AFM is on-device and
            //    effectively single-stream; even though awaits do
            //    yield the actor, the SQLite connection and the
            //    AFM model itself can saturate when chunks process
            //    back-to-back. 1.5s spacing keeps the local API
            //    responsive AND lets thermal/battery breathe; Mark's
            //    progressive-enhancement vision values steady,
            //    sustainable progress over peak throughput.
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
        }
    }

    // MARK: Selection logic

    private struct PickedChunk {
        let documentID: UUID
        let candidate: DatabaseManager.ChunkEnhancementCandidate
        let summary: String?
        let title: String
    }

    private func pickNext() -> PickedChunk? {
        // First: the document the user is reading (if any).
        if let currentID = currentReadingDocumentID,
           let pick = pickFromDocument(currentID, prioritizingOffset: currentReadingOffset) {
            return pick
        }
        // Then: any other doc in the library with pending work.
        let pendingIDs = (try? database.documentsWithPendingChunks()) ?? []
        for did in pendingIDs {
            if did == currentReadingDocumentID { continue }
            if let pick = pickFromDocument(did, prioritizingOffset: 0) {
                return pick
            }
        }
        return nil
    }

    private func pickFromDocument(_ documentID: UUID,
                                  prioritizingOffset offset: Int) -> PickedChunk? {
        let candidates: [DatabaseManager.ChunkEnhancementCandidate]
        do {
            candidates = try database.unenhancedChunks(for: documentID)
        } catch {
            return nil
        }
        guard !candidates.isEmpty else {
            // Document complete — fire one notification for the UI.
            NotificationCenter.default.post(
                name: .chunkEnhancementDocumentDidComplete,
                object: nil,
                userInfo: [
                    DocumentEmbeddingIndex.notificationDocumentIDKey: documentID
                ]
            )
            return nil
        }
        // Order: at-or-after offset first, then before offset.
        let atOrAfter = candidates.filter { $0.startOffset >= offset }
        let before = candidates.filter { $0.startOffset < offset }
        let picked = atOrAfter.first ?? before.first
        guard let candidate = picked else { return nil }

        // Document metadata (for the prompt's context).
        let metadata = (try? database.documentMetadata(for: documentID))
        let summary = metadata?.summary
        let docs = (try? database.documents()) ?? []
        let title = docs.first(where: { $0.id == documentID })?.title ?? "Untitled"

        return PickedChunk(
            documentID: documentID,
            candidate: candidate,
            summary: summary,
            title: title
        )
    }

    // MARK: Chunk processing

    private func processChunk(documentID: UUID,
                              candidate: DatabaseManager.ChunkEnhancementCandidate,
                              documentSummary: String?,
                              documentTitle: String) async {
        guard let enhance else { return }

        NotificationCenter.default.post(
            name: .chunkEnhancementDidStart,
            object: nil,
            userInfo: [
                DocumentEmbeddingIndex.notificationDocumentIDKey: documentID,
                "posey.askposey.chunkEnhancement.chunkIndex": candidate.chunkIndex
            ]
        )

        // 1) AFM call for the context note. Returns nil on refusal /
        //    error — mark failed and move on.
        let note = await enhance(candidate.text, documentSummary, documentTitle)
        guard let note, !note.isEmpty else {
            try? database.markChunkEnhancementFailed(
                documentID: documentID,
                chunkIndex: candidate.chunkIndex)
            NotificationCenter.default.post(
                name: .chunkEnhancementDidFail,
                object: nil,
                userInfo: [
                    DocumentEmbeddingIndex.notificationDocumentIDKey: documentID,
                    "posey.askposey.chunkEnhancement.chunkIndex": candidate.chunkIndex
                ]
            )
            return
        }

        // 2) Re-embed with the note prepended. Same kind as before
        //    (search-time grouping unchanged; the chunk's content
        //    just got better).
        let prepended = "\(note)\n\n\(candidate.text)"
        let newEmbedding = embedText(prepended, candidate.embeddingKind)
        guard !newEmbedding.isEmpty else {
            // Embedder failed — leave ctx_status at 0 so the worker
            // can retry later. Don't mark failed; AFM didn't refuse.
            return
        }

        // 3) Persist atomically.
        do {
            try database.saveChunkEnhancement(
                documentID: documentID,
                chunkIndex: candidate.chunkIndex,
                contextNote: note,
                embedding: newEmbedding)
        } catch {
            return
        }

        NotificationCenter.default.post(
            name: .chunkEnhancementDidComplete,
            object: nil,
            userInfo: [
                DocumentEmbeddingIndex.notificationDocumentIDKey: documentID,
                "posey.askposey.chunkEnhancement.chunkIndex": candidate.chunkIndex
            ]
        )
    }

    // MARK: Throttling

    private func shouldThrottle() -> Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        switch info.thermalState {
        case .serious, .critical: return true
        default: break
        }
        return false
    }
}

// ========== BLOCK 02: SCHEDULER - END ==========
