import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: RAPTOR TREE SERVICE - START ==========

/// Background owner of the production RAPTOR tree build.
///
/// **Why this exists.** `RaptorTreeBuilder` (cluster → AFM-summarize →
/// verify) was fully implemented but only ever invoked by the DEBUG-only
/// `BUILD_RAPTOR_TREE` antenna verb, so a shipping Release build produced
/// ZERO summary nodes — the "collapsed tree" the docstrings advertise never
/// existed for a real reader (code audit 2026-06-07, confirmed finding #1).
/// This service is the real production trigger.
///
/// **Contract — "usable now, improves in background"** (the same one the PDF
/// enhancement pipeline uses, and which `RaptorTreeBuilder`'s header calls
/// out explicitly). A document is fully readable and answerable from its leaf
/// chunks the instant indexing finishes; the summary tree builds afterward on
/// a background actor and, once stored, simply joins the existing retrieval
/// pool — `HybridRetriever` already fuses leaves + summaries with NO retriever
/// change, because both live in `unit_embedding_chunks` and summary nodes sit
/// at `chunk_index >= raptorSummaryIndexBase`.
///
/// **Trigger points:**
///   - After a document's leaf chunks finish embedding
///     (`UnitEmbeddingService.fillEmbeddings` completion) → `enqueue`.
///     Re-firing on a re-index (Tier-2/3 rewrite, re-import) is correct: the
///     leaves changed, so the tree is rebuilt (`replaceSummaryNodes` clears
///     the old summaries first).
///   - On app launch (`bootstrap`) → enqueue any document that has enough
///     embedded leaves but no summary tree yet. This builds trees for the
///     pre-existing library (imported before this feature) and resumes any
///     build interrupted by termination.
///
/// **State model.** Deliberately schema-free: "does a tree exist?" is just
/// `raptorSummaryNodeCount(for:) > 0`, and the in-memory queue/`draining`
/// flag (mirroring `PDFEnhancementService`) serialize the work. No
/// `raptor_status` column — the count is the single source of truth, so there
/// is nothing to migrate or keep consistent.
///
/// **AFM gate.** RAPTOR summaries require Apple Foundation Models. On a device
/// where AFM is unavailable the whole service no-ops up front (no clustering,
/// no per-cluster backoff sleeps) so it never wastes work that can't succeed;
/// when AFM later becomes available a re-index re-triggers the build.
actor RaptorTreeService {

    // MARK: Shared instance

    /// App-wide singleton. Configured once at launch via
    /// `configure(databaseManager:)`. Before configuration every method
    /// safely no-ops.
    static let shared = RaptorTreeService()

    // MARK: Tuning

    /// Minimum embedded leaf chunks before a tree is worth building. Below
    /// this, the handful of leaves are already directly retrievable and an
    /// abstraction layer adds noise, not signal.
    private static let minLeavesForBuild = 24
    /// Cap on leaves fed into one build, to bound k-means + the number of
    /// AFM summary calls on very large books. The builder truncates each
    /// cluster's source to its own input budget; this bounds breadth.
    private static let maxLeavesForBuild = 600

    /// Adaptive cluster count: aim for ~20 leaves per cluster (coherent,
    /// summarizable groups), clamped to a sane band.
    private static func clusterCount(forLeaves n: Int) -> Int {
        max(6, min(32, n / 20))
    }

    // MARK: Notification API

    /// Posted on the main thread after a document's summary tree finishes
    /// building (success or no-op). userInfo: `documentID` (UUID),
    /// `summaryNodeCount` (Int).
    static let didBuildNotification = Notification.Name("posey.raptor.didBuild")
    static let documentIDKey = "posey.raptor.documentID"
    static let summaryNodeCountKey = "posey.raptor.summaryNodeCount"

    /// Posted on the main thread when a REAL build begins for a document —
    /// i.e. AFM is available, the leaf-count threshold is met, and clustering
    /// is about to run (not for the cheap no-op cases). userInfo: `documentID`.
    /// Drives the reader's "re-reading for the big picture" status. The paired
    /// `didBuildNotification` ends that status. (2026-06-17)
    static let didStartNotification = Notification.Name("posey.raptor.didStart")

    // MARK: State

    private var databaseManager: DatabaseManager?
    /// FIFO of document IDs awaiting a build.
    private var queue: [UUID] = []
    /// The document currently building, or nil if idle.
    private var currentDocumentID: UUID?
    /// IDs cancelled (document deleted / RESET_ALL) — checked before work.
    private var cancelled: Set<UUID> = []
    /// True while `drainQueue` is iterating — only one drain loop at a time.
    private var draining: Bool = false

    private init() {}

    // MARK: Configuration

    /// Wire the live DatabaseManager. Called once at launch before any build
    /// can run. Mirrors `PDFEnhancementService.configure`.
    func configure(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        dbgLog("RaptorTreeService: configured")
    }

    // MARK: Public API

    /// Enqueue a document for a background tree build. Idempotent — an ID
    /// already queued or in flight is skipped.
    func enqueue(_ documentID: UUID) {
        if currentDocumentID == documentID || queue.contains(documentID) { return }
        cancelled.remove(documentID)
        queue.append(documentID)
        dbgLog("RaptorTreeService: enqueued %@ (queue=%d)",
               documentID.uuidString, queue.count)
        Task { await drainQueue() }
    }

    /// Cancel any queued or in-flight build for `documentID`. Called on
    /// document delete / RESET_ALL so a build can't resurrect summary rows
    /// the cascade just swept.
    func cancel(_ documentID: UUID) {
        cancelled.insert(documentID)
        queue.removeAll { $0 == documentID }
        dbgLog("RaptorTreeService: cancelled %@", documentID.uuidString)
    }

    /// On-launch sweep: enqueue every document that has enough embedded
    /// leaves but no summary tree yet (pre-feature library + interrupted
    /// builds). Skips documents that already have summaries so a tree is
    /// never rebuilt on every launch.
    func bootstrap() async {
        guard isAFMAvailable else {
            dbgLog("RaptorTreeService: bootstrap skipped (AFM unavailable)")
            return
        }
        guard let db = databaseManager else {
            dbgLog("RaptorTreeService: bootstrap skipped (no databaseManager)")
            return
        }
        let candidates: [UUID]
        do {
            candidates = try await MainActor.run { () throws -> [UUID] in
                var ids: [UUID] = []
                for doc in try db.documents() {
                    let leaves = try db.embeddedLeafChunkCount(for: doc.id)
                    guard leaves >= Self.minLeavesForBuild else { continue }
                    let summaries = try db.raptorSummaryNodeCount(for: doc.id)
                    if summaries == 0 { ids.append(doc.id) }
                }
                return ids
            }
        } catch {
            dbgLog("RaptorTreeService: bootstrap query failed: %@", String(describing: error))
            return
        }
        // 2026-06-18 — route bootstrap rebuilds through the single document
        // queue (embed is a no-op for these already-embedded docs; the tree
        // then builds in the same serial slot) so a launch sweep of N docs
        // can't fan out heavy work — it drains one document at a time.
        for id in candidates { await DocumentIndexingQueue.shared.enqueue(id) }
        dbgLog("RaptorTreeService: bootstrap enqueued %d document(s)", candidates.count)
    }

    /// Snapshot of in-memory queue state for diagnostics (antenna verb).
    func snapshot() -> (queue: [UUID], current: UUID?, cancelled: [UUID]) {
        (queue, currentDocumentID, Array(cancelled))
    }

    /// Build the summary tree for ONE document and return when done — the
    /// awaitable entry the `DocumentIndexingQueue`'s `LiveDocumentIndexer`
    /// calls inside a document's serial slot, right after its leaves finish
    /// embedding. Self-gates exactly like the old fire-and-forget path (AFM
    /// availability, minimum leaf count) so it is a cheap no-op when those
    /// aren't met, and honors `Task` cancellation inside `buildTree`.
    /// (2026-06-18 — replaces the `enqueue` → internal-drain path for the
    /// production pipeline; the document queue now owns embed→RAPTOR ordering.)
    func build(_ documentID: UUID) async {
        await buildTree(for: documentID)
    }

    // MARK: Drain loop

    /// Pop documents off the queue and build each, one at a time.
    /// Re-entrant-safe via `draining`.
    private func drainQueue() async {
        if draining { return }
        draining = true
        defer { draining = false }

        while !queue.isEmpty {
            let next = queue.removeFirst()
            if cancelled.contains(next) { cancelled.remove(next); continue }
            currentDocumentID = next
            await buildTree(for: next)
            currentDocumentID = nil
        }
    }

    // MARK: Build

    /// Build (or rebuild) the layer-1 summary tree for one document:
    /// load embedded leaves → cluster + AFM-summarize + verify
    /// (`RaptorTreeBuilder`) → embed each verified summary → store via
    /// `replaceSummaryNodes`. Best-effort: any failure logs and leaves the
    /// existing summaries (if any) untouched.
    private func buildTree(for documentID: UUID) async {
        guard isAFMAvailable else { return }
        guard let db = databaseManager else { return }
        if cancelled.contains(documentID) { cancelled.remove(documentID); return }

        // Load embedded leaves + the full document text (entity-grounding
        // haystack) in one main-actor hop.
        let leaves: [StoredUnitEmbeddingChunk]
        let docText: String
        do {
            (leaves, docText) = try await MainActor.run { () throws -> ([StoredUnitEmbeddingChunk], String) in
                let all = try db.unitEmbeddingChunks(for: documentID)
                let embeddedLeaves = all
                    .filter { $0.embedding != nil && $0.chunkIndex < DatabaseManager.raptorSummaryIndexBase }
                    .sorted { $0.chunkIndex < $1.chunkIndex }
                let text = (try? db.plainText(for: documentID)) ?? ""
                return (embeddedLeaves, text)
            }
        } catch {
            dbgLog("RaptorTreeService: load failed for %@: %@",
                   documentID.uuidString, String(describing: error))
            return
        }

        guard leaves.count >= Self.minLeavesForBuild else {
            dbgLog("RaptorTreeService: %@ has %d embedded leaves (< %d) — no tree",
                   documentID.uuidString, leaves.count, Self.minLeavesForBuild)
            return
        }

        // Committed to a real build now (AFM present, threshold met). Announce
        // the start so the reader can show "re-reading for the big picture".
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.didStartNotification, object: nil,
                userInfo: [Self.documentIDKey: documentID])
        }

        let slice = Array(leaves.prefix(Self.maxLeavesForBuild))
        let inputNodes = slice.map {
            RaptorTreeBuilder.InputNode(
                chunkIndex: $0.chunkIndex, text: $0.text, embedding: $0.embedding!,
                startUnitID: $0.startUnitID, endUnitID: $0.endUnitID)
        }
        let k = Self.clusterCount(forLeaves: slice.count)

        let builder = RaptorTreeBuilder()
        let config = RaptorTreeBuilder.Config(clusterCount: k)
        let summaryNodes = await builder.buildLayer(
            layer: 1, nodes: inputNodes, documentText: docText, config: config)

        if cancelled.contains(documentID) { await postDidBuild(documentID, count: 0); cancelled.remove(documentID); return }
        guard !summaryNodes.isEmpty else {
            dbgLog("RaptorTreeService: %@ produced 0 summary nodes (k=%d, leaves=%d)",
                   documentID.uuidString, k, slice.count)
            await postDidBuild(documentID, count: 0)   // clear the "re-reading" status
            return
        }

        // Embed each verified summary into the SAME space as the leaves
        // (`.document` purpose), then store in the collapsed pool.
        var toStore: [StoredUnitEmbeddingChunk] = []
        toStore.reserveCapacity(summaryNodes.count)
        for (i, node) in summaryNodes.enumerated() {
            if Task.isCancelled { return }
            let text = node.text
            // Global serial lane — embedding a RAPTOR summary is heavy
            // background compute; serialize app-wide (was a free Task.detached).
            let emb = await HeavyWorkLane.shared.run(label: "RAPTOR-embed") {
                EmbeddingProvider.shared.embed(text, as: .document)
            }
            toStore.append(StoredUnitEmbeddingChunk(
                id: UUID(),
                documentID: documentID,
                chunkIndex: DatabaseManager.raptorSummaryIndexBase + i,
                startUnitID: node.startUnitID,
                startIntraOffset: 0,
                endUnitID: node.endUnitID,
                endIntraOffset: 0,
                text: text,
                embedding: emb))
        }

        if cancelled.contains(documentID) { cancelled.remove(documentID); return }
        let summariesToStore = toStore   // immutable snapshot for the @Sendable closure
        do {
            try await MainActor.run { try db.replaceSummaryNodes(summariesToStore, for: documentID) }
        } catch {
            dbgLog("RaptorTreeService: store failed for %@: %@",
                   documentID.uuidString, String(describing: error))
            await postDidBuild(documentID, count: 0)   // clear the "re-reading" status
            return
        }

        let storedCount = summariesToStore.count
        dbgLog("RaptorTreeService: built %d summary node(s) for %@ (k=%d, leaves=%d)",
               storedCount, documentID.uuidString, k, slice.count)
        await postDidBuild(documentID, count: storedCount)
    }

    /// Post the terminal `didBuildNotification` on the main thread. Always
    /// follows a `didStartNotification` (on success OR post-start failure), so
    /// any "re-reading…" status the start raised is reliably cleared.
    private func postDidBuild(_ documentID: UUID, count: Int) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.didBuildNotification, object: nil,
                userInfo: [Self.documentIDKey: documentID,
                           Self.summaryNodeCountKey: count])
        }
    }

    // MARK: AFM availability

    /// True iff Apple Foundation Models can summarize on this device. The
    /// builder also guards internally, but checking here avoids enqueuing /
    /// clustering / per-cluster backoff sleeps that could never succeed.
    private var isAFMAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
            return false
        }
        return false
        #else
        return false
        #endif
    }
}

// ========== BLOCK 01: RAPTOR TREE SERVICE - END ==========
