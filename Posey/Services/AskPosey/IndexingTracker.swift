import Foundation
import Combine

// ========== BLOCK 01: INDEXING TRACKER - START ==========

/// Observable view-friendly mirror of `UnitEmbeddingService`'s
/// progress notifications. Drives the reader's "Still learning
/// this document — N%" affordance in the Ask Posey menu.
///
/// **History:** the legacy `DocumentEmbeddingIndex` posted
/// `documentIndexingDidStart/Progress/Complete` that this tracker
/// listened to. 8f tore out that index; this file was neutered
/// (all queries returned nil/false) so the banner never showed.
/// 2026-05-24 follow-up: re-wired to `UnitEmbeddingService`'s
/// new `unitEmbeddingDidStart/Progress/Complete` notifications.
/// SwiftUI view code (`@StateObject private var indexingTracker =
/// IndexingTracker()` in `ReaderView` and `AskPoseyView`) is
/// unchanged; the same public surface works.
@MainActor
final class IndexingTracker: ObservableObject {

    static let sharedForChat = IndexingTracker()

    /// Per-document progress snapshot. Empty after .didComplete fires.
    @Published private(set) var indexingProgress: [UUID: IndexingProgress] = [:]
    /// Convenience set used by SwiftUI `.animation(value:)` modifiers
    /// that watch "is any indexing happening?" rather than a specific
    /// document's progress.
    @Published private(set) var indexingDocumentIDs: Set<UUID> = []

    /// Documents whose RAPTOR summary tree is currently building — the
    /// "re-reading for the big picture" state that runs AFTER embedding
    /// completes (so a doc here has already passed `isIndexing == false`).
    /// Non-blocking: Ask Posey is already openable; this only drives the
    /// "still deepening" status copy. Set on `RaptorTreeService.didStart`,
    /// cleared on `.didBuild`. (2026-06-17)
    @Published private(set) var reReadingDocumentIDs: Set<UUID> = []

    /// RAPTOR build progress (clusters summarized / total) per document, for the
    /// "Studying up — N%" label. Present only while a build is in flight; set to
    /// 0 on `didStart`, updated on `didProgress`, removed on `didBuild`.
    /// (2026-06-18)
    @Published private(set) var reReadingProgress: [UUID: Double] = [:]

    /// 2026-06-19 (Mark) — Tier-2 Vision OCR progress (0…1) per document, for the
    /// status board's pipeline view. Present only while OCR is in flight.
    @Published private(set) var ocrProgress: [UUID: Double] = [:]

    /// 2026-06-19 — documents in the brief chunking (string-split) stage.
    @Published private(set) var chunkingDocumentIDs: Set<UUID> = []

    /// Main-actor mirror of `DocumentIndexingQueue`'s embed lane (Pillar 4b):
    /// document → 1-based position among the documents WAITING to be embedded
    /// (the in-flight document is excluded — it's "Reading ahead", not queued).
    /// Lets a library card show a precise "Queued #k" without touching the queue
    /// actor. Empty when the embed lane is empty. (2026-06-18)
    @Published private(set) var embedQueuePositions: [UUID: Int] = [:]

    /// The document the queue is currently working (embedding or RAPTOR), or nil
    /// when idle. Used to scope the "Cooling down" label to the one doc actually
    /// generating heat. (2026-06-18)
    @Published private(set) var currentIndexingDocumentID: UUID?

    /// True while the device is thermally throttled (`.serious`/`.critical`), so
    /// the `ThermalGovernor` is pacing/pausing heavy work. Surfaces as "Cooling
    /// down" on whichever card is the current in-flight document — a paced import
    /// is slow ON PURPOSE; the label keeps that from reading as broken. (2026-06-18)
    @Published private(set) var isThermallyPaced: Bool = false

    /// 2026-06-19 — TRUE pause, not just throttle. The `ThermalGovernor` only
    /// *stops* at `.critical`; at `.serious` it keeps working, 250ms slower per
    /// chunk. The status surface uses THIS (critical only) for "Catching my
    /// breath…", so a `.serious` stretch reads as steady progress ("Reading
    /// ahead — N%") instead of a stall (Mark, 2026-06-19: the old "Cooling down"
    /// fired at `.serious` while the doc was still embedding, reading as stopped).
    @Published private(set) var isThermallyPaused: Bool = false

    /// Same shape as the pre-8f struct so view code that destructures
    /// the optional doesn't break.
    struct IndexingProgress: Equatable, Sendable {
        let processed: Int
        let total: Int
        var fraction: Double {
            total > 0 ? Double(processed) / Double(total) : 0
        }
    }

    private var cancellables: Set<AnyCancellable> = []

    init(notificationCenter: NotificationCenter = .default) {
        notificationCenter.publisher(for: UnitEmbeddingService.didStartNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleStart(note) }
            .store(in: &cancellables)
        notificationCenter.publisher(for: UnitEmbeddingService.didProgressNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleProgress(note) }
            .store(in: &cancellables)
        notificationCenter.publisher(for: UnitEmbeddingService.didCompleteNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleComplete(note) }
            .store(in: &cancellables)
        // RAPTOR re-reading status (post-embedding, non-blocking).
        notificationCenter.publisher(for: RaptorTreeService.didStartNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleRaptorStart(note) }
            .store(in: &cancellables)
        notificationCenter.publisher(for: RaptorTreeService.didProgressNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleRaptorProgress(note) }
            .store(in: &cancellables)
        notificationCenter.publisher(for: RaptorTreeService.didBuildNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleRaptorBuild(note) }
            .store(in: &cancellables)
        // Queue lane state → precise "Queued #k" + current-doc identity (Pillar 4b).
        notificationCenter.publisher(for: DocumentIndexingQueue.queueDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleQueueChange(note) }
            .store(in: &cancellables)
        // 2026-06-19 — Tier-2 Vision OCR progress (board pipeline view).
        notificationCenter.publisher(for: PDFEnhancementService.ocrDidStart)
            .receive(on: RunLoop.main).sink { [weak self] n in self?.handleOCR(n, clear: false) }
            .store(in: &cancellables)
        notificationCenter.publisher(for: PDFEnhancementService.ocrDidProgress)
            .receive(on: RunLoop.main).sink { [weak self] n in self?.handleOCR(n, clear: false) }
            .store(in: &cancellables)
        notificationCenter.publisher(for: PDFEnhancementService.ocrDidComplete)
            .receive(on: RunLoop.main).sink { [weak self] n in self?.handleOCR(n, clear: true) }
            .store(in: &cancellables)
        // 2026-06-19 — chunking (string-split) stage.
        notificationCenter.publisher(for: UnitEmbeddingService.chunkingDidStartNotification)
            .receive(on: RunLoop.main).sink { [weak self] n in self?.handleChunking(n, started: true) }
            .store(in: &cancellables)
        notificationCenter.publisher(for: UnitEmbeddingService.chunkingDidFinishNotification)
            .receive(on: RunLoop.main).sink { [weak self] n in self?.handleChunking(n, started: false) }
            .store(in: &cancellables)
        // Thermal pressure → "Cooling down" on the in-flight card (Pillar 4b).
        // Read once for the initial state, then track the system notification.
        isThermallyPaced = Self.isPaced(ProcessInfo.processInfo.thermalState)
        isThermallyPaused = (ProcessInfo.processInfo.thermalState == .critical)
        notificationCenter.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                let state = ProcessInfo.processInfo.thermalState
                self?.isThermallyPaced = Self.isPaced(state)
                self?.isThermallyPaused = (state == .critical)
            }
            .store(in: &cancellables)
    }

    /// `.serious`/`.critical` are where `ThermalGovernor` adds real cooldowns
    /// (250ms) or fully pauses — i.e. where the user would otherwise see an
    /// unexplained slowdown. `.nominal`/`.fair` are the always-on light yields,
    /// not worth surfacing.
    private static func isPaced(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    // MARK: - Public surface (matches pre-8f shape)

    /// True iff the named document currently has a fill in flight.
    /// Used by the reader's Ask Posey menu to show the banner.
    /// Identical semantics to `isIndexing` — the pre-8f tracker
    /// distinguished "indexing chunks" from "AFM metadata
    /// enhancement"; with metadata enhancement torn out, both
    /// collapse to one signal.
    func isEnhancing(_ documentID: UUID) -> Bool {
        return indexingProgress[documentID] != nil
    }

    func isIndexing(_ documentID: UUID) -> Bool {
        return indexingProgress[documentID] != nil
    }

    /// Pre-8f returned a fraction (0…1) for the unified
    /// chunks+metadata signal. Today same fraction, computed off
    /// the single-stage chunk fill.
    func unifiedProgress(for documentID: UUID) -> Double? {
        return indexingProgress[documentID]?.fraction
    }

    /// True while this document's RAPTOR summary tree is building (the
    /// post-embedding "re-reading for the big picture" deepening). Distinct
    /// from `isIndexing`: a doc can be done indexing (openable) yet still
    /// re-reading. (2026-06-17)
    func isReReading(_ documentID: UUID) -> Bool {
        return reReadingDocumentIDs.contains(documentID)
    }

    /// RAPTOR build progress (0…1) for the "Studying up — N%" label, or nil if
    /// no build is in flight (or it hasn't reported a cluster yet).
    func reReadingFraction(_ documentID: UUID) -> Double? {
        return reReadingProgress[documentID]
    }

    /// 1-based position of a document among those WAITING to be embedded, or nil
    /// if it is not waiting (idle, in-flight, or already embedded). Drives the
    /// library card's "Queued #k". (Pillar 4b)
    func queuePosition(_ documentID: UUID) -> Int? {
        return embedQueuePositions[documentID]
    }

    /// True when this document is the current in-flight one AND the device is
    /// thermally paced — i.e. its indexing is deliberately slowed to protect the
    /// device. Scoped to the in-flight doc so only the card actually generating
    /// heat reads "Cooling down". (Pillar 4b)
    func isCoolingDown(_ documentID: UUID) -> Bool {
        return isThermallyPaced && currentIndexingDocumentID == documentID
    }

    /// 2026-06-19 — True ONLY when this in-flight document's indexing is actually
    /// PAUSED (`.critical`), not merely throttled (`.serious`). The status surface
    /// shows "Catching my breath…" only here; at `.serious` it shows progress,
    /// because the doc IS still embedding.
    func isCriticallyPaused(_ documentID: UUID) -> Bool {
        return isThermallyPaused && currentIndexingDocumentID == documentID
    }

    // MARK: - Notification handlers

    private func handleStart(_ note: Notification) {
        guard let id = note.userInfo?[UnitEmbeddingService.documentIDKey] as? UUID,
              let total = note.userInfo?[UnitEmbeddingService.totalChunksKey] as? Int else {
            return
        }
        indexingProgress[id] = IndexingProgress(processed: 0, total: total)
        indexingDocumentIDs.insert(id)
    }

    private func handleProgress(_ note: Notification) {
        guard let id = note.userInfo?[UnitEmbeddingService.documentIDKey] as? UUID,
              let processed = note.userInfo?[UnitEmbeddingService.processedChunksKey] as? Int,
              let total = note.userInfo?[UnitEmbeddingService.totalChunksKey] as? Int else {
            return
        }
        indexingProgress[id] = IndexingProgress(processed: processed, total: total)
    }

    private func handleComplete(_ note: Notification) {
        guard let id = note.userInfo?[UnitEmbeddingService.documentIDKey] as? UUID else { return }
        indexingProgress.removeValue(forKey: id)
        indexingDocumentIDs.remove(id)
    }

    private func handleRaptorStart(_ note: Notification) {
        guard let id = note.userInfo?[RaptorTreeService.documentIDKey] as? UUID else { return }
        reReadingDocumentIDs.insert(id)
        reReadingProgress[id] = 0   // "Studying up — 0%" until the first cluster reports
    }

    private func handleRaptorProgress(_ note: Notification) {
        guard let id = note.userInfo?[RaptorTreeService.documentIDKey] as? UUID,
              let done = note.userInfo?[RaptorTreeService.processedClustersKey] as? Int,
              let total = note.userInfo?[RaptorTreeService.totalClustersKey] as? Int,
              total > 0 else { return }
        reReadingProgress[id] = Double(done) / Double(total)
    }

    private func handleRaptorBuild(_ note: Notification) {
        guard let id = note.userInfo?[RaptorTreeService.documentIDKey] as? UUID else { return }
        reReadingDocumentIDs.remove(id)
        reReadingProgress.removeValue(forKey: id)
    }

    // 2026-06-19 — Tier-2 OCR + chunking handlers/accessors (board pipeline).
    private func handleOCR(_ note: Notification, clear: Bool) {
        guard let id = note.userInfo?[PDFEnhancementService.notificationDocumentIDKey] as? UUID else { return }
        if clear { ocrProgress.removeValue(forKey: id); return }
        let processed = note.userInfo?[PDFEnhancementService.ocrProcessedPagesKey] as? Int ?? 0
        let total = note.userInfo?[PDFEnhancementService.ocrTotalPagesKey] as? Int ?? 0
        ocrProgress[id] = total > 0 ? Double(processed) / Double(total) : 0
    }

    private func handleChunking(_ note: Notification, started: Bool) {
        guard let id = note.userInfo?[UnitEmbeddingService.documentIDKey] as? UUID else { return }
        if started { chunkingDocumentIDs.insert(id) } else { chunkingDocumentIDs.remove(id) }
    }

    /// OCR fraction (0…1) for a document, or nil if not OCR'ing.
    func ocrFraction(_ documentID: UUID) -> Double? { ocrProgress[documentID] }
    /// True while a document is in the brief chunking (string-split) stage.
    func isChunking(_ documentID: UUID) -> Bool { chunkingDocumentIDs.contains(documentID) }

    private func handleQueueChange(_ note: Notification) {
        let embed = note.userInfo?[DocumentIndexingQueue.embedQueueKey] as? [UUID] ?? []
        currentIndexingDocumentID = note.userInfo?[DocumentIndexingQueue.currentDocumentIDKey] as? UUID
        // Map the waiting embed lane to 1-based positions (index 0 → "Queued #1").
        var positions: [UUID: Int] = [:]
        for (offset, id) in embed.enumerated() { positions[id] = offset + 1 }
        embedQueuePositions = positions
    }
}

// ========== BLOCK 01: INDEXING TRACKER - END ==========
