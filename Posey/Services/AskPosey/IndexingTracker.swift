import Foundation
import Combine

// ========== BLOCK 01: INDEXING TRACKER - START ==========
/// Observable view-friendly mirror of the indexing state broadcast by
/// `DocumentEmbeddingIndex` via `NotificationCenter`.
///
/// SwiftUI views (the reader banner, the eventual library row indicator)
/// subscribe to one of these via `@StateObject` or `@ObservedObject`,
/// and the published `indexingDocumentIDs` set drives the visible UI.
/// The tracker has no work of its own — it's just a translation layer
/// from notifications to `@Published`. Multiple instances can coexist
/// (one per scene); each one observes the same notifications
/// independently.
///
/// `@MainActor` on the class so the publisher firing always lands on
/// main and SwiftUI doesn't need to re-route. Notifications are posted
/// on the main queue from `DocumentEmbeddingIndex.enqueueIndexing` so
/// the hop is essentially free.
@MainActor
final class IndexingTracker: ObservableObject {

    /// Documents currently mid-indexing (background work in flight).
    /// Empty when nothing is being indexed.
    @Published private(set) var indexingDocumentIDs: Set<UUID> = []

    /// Latest progress snapshot per in-flight document. Updated by
    /// `.documentIndexingDidProgress` notifications posted every 50
    /// chunks during the embedding pass. Cleared on completion or
    /// failure. UI uses this to render
    /// "Indexing 847 of 3,300 sections" instead of an indeterminate
    /// spinner.
    @Published private(set) var indexingProgress: [UUID: IndexingProgress] = [:]

    /// Last completed chunk count per document, kept for ~few seconds
    /// after completion so the UI can show a brief "Indexed N
    /// sections." confirmation. Cleared via `dismissCompletion(for:)`
    /// or after a configurable retention window. Not used in v1's
    /// minimal banner — present so a future "Indexed N" pill UI can
    /// read it without reshaping the model.
    @Published private(set) var lastCompletedChunkCounts: [UUID: Int] = [:]

    /// Documents whose AFM metadata extraction is currently running.
    /// Set when `.metadataEnhancementDidStart` fires; cleared on
    /// either DidComplete or DidFail. Tracks the second stage of the
    /// background-enhancement pipeline (chunking is the first).
    @Published private(set) var metadataExtractingDocumentIDs: Set<UUID> = []

    /// Snapshot of indexing progress for one document.
    struct IndexingProgress: Equatable, Sendable {
        let processed: Int
        let total: Int
        /// Convenience for the banner — clamped to [0, 1] in case a
        /// rounding error ever produces a value slightly outside.
        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(processed) / Double(total)))
        }
    }

    private var subscriptions: Set<AnyCancellable> = []

    init(notificationCenter: NotificationCenter = .default) {
        notificationCenter.publisher(for: .documentIndexingDidStart)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleStart(note) }
            .store(in: &subscriptions)
        notificationCenter.publisher(for: .documentIndexingDidProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleProgress(note) }
            .store(in: &subscriptions)
        notificationCenter.publisher(for: .documentIndexingDidComplete)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleComplete(note) }
            .store(in: &subscriptions)
        notificationCenter.publisher(for: .documentIndexingDidFail)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleFail(note) }
            .store(in: &subscriptions)
        // Metadata enhancement (stage 2) — same shape as indexing.
        notificationCenter.publisher(for: DocumentEmbeddingIndex.metadataEnhancementDidStart)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleMetadataStart(note) }
            .store(in: &subscriptions)
        notificationCenter.publisher(for: DocumentEmbeddingIndex.metadataEnhancementDidComplete)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleMetadataComplete(note) }
            .store(in: &subscriptions)
        notificationCenter.publisher(for: DocumentEmbeddingIndex.metadataEnhancementDidFail)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleMetadataFail(note) }
            .store(in: &subscriptions)
    }

    /// Convenience the UI calls to ask "is this document being indexed
    /// right now?" without unwrapping the published set every time.
    func isIndexing(_ documentID: UUID) -> Bool {
        indexingDocumentIDs.contains(documentID)
    }

    /// True when EITHER chunking or metadata extraction is in flight.
    /// This is the signal the unified progress ring on the Ask Posey
    /// sparkle icon listens to.
    func isEnhancing(_ documentID: UUID) -> Bool {
        indexingDocumentIDs.contains(documentID)
            || metadataExtractingDocumentIDs.contains(documentID)
    }

    /// Unified background-enhancement progress, [0, 1], across both
    /// stages combined.
    ///
    /// Total units = totalChunks + 1 (the +1 is the metadata
    /// extraction step). Progress = chunksProcessed +
    /// (metadata-stage-finished ? 1 : 0), divided by total. Returns
    /// nil when nothing is enhancing.
    ///
    /// Edge cases:
    /// - Chunking complete + metadata still running → returns
    ///   totalChunks / (totalChunks + 1) ≈ "almost done."
    /// - Chunking running, total unknown yet → falls back to a
    ///   conservative estimate so the ring doesn't snap to 0%.
    /// - Both stages already finished → returns nil (the document is
    ///   no longer in either in-flight set).
    func unifiedProgress(for documentID: UUID) -> Double? {
        guard isEnhancing(documentID) else { return nil }

        // Stage 1: chunking. If we have a progress snapshot, use it;
        // else assume the chunking pass hasn't reported yet — start
        // at a small non-zero floor so the ring is visible.
        let chunkFraction: Double
        let totalChunks: Int
        if let progress = indexingProgress[documentID] {
            totalChunks = max(progress.total, 1)
            chunkFraction = Double(progress.processed) / Double(totalChunks + 1)
        } else if indexingDocumentIDs.contains(documentID) {
            // Chunking started, no progress posted yet. Render a 5%
            // floor so the ring is visible immediately.
            return 0.05
        } else {
            // Chunking already finished — completion handler removed
            // it from indexingDocumentIDs. We're now in the metadata
            // stage. Use the last known chunk count if recorded.
            totalChunks = max(lastCompletedChunkCounts[documentID] ?? 1, 1)
            chunkFraction = Double(totalChunks) / Double(totalChunks + 1)
        }

        // Stage 2: metadata. Adds the +1 unit when complete. While
        // running, contributes 0 (it's a single-step stage).
        let metadataDone = !metadataExtractingDocumentIDs.contains(documentID)
            && (indexingDocumentIDs.contains(documentID) == false)
        let metadataFraction: Double = metadataDone
            ? Double(1) / Double(totalChunks + 1)
            : 0

        return min(1.0, max(0.0, chunkFraction + metadataFraction))
    }

    /// Clear the completion record for a document so the "Indexed N"
    /// pill stops being eligible to render. Caller's responsibility to
    /// call after the brief confirmation window passes; v1 doesn't
    /// invoke it because the v1 banner is in-progress only.
    func dismissCompletion(for documentID: UUID) {
        lastCompletedChunkCounts.removeValue(forKey: documentID)
    }

    // MARK: - Notification handlers

    private func handleStart(_ note: Notification) {
        guard let id = documentID(from: note) else { return }
        indexingDocumentIDs.insert(id)
        // If the user re-imports a document while a previous "completed"
        // confirmation is still showing, drop it so the banner state
        // moves cleanly back to "in progress."
        lastCompletedChunkCounts.removeValue(forKey: id)
        indexingProgress.removeValue(forKey: id)
    }

    private func handleProgress(_ note: Notification) {
        guard let id = documentID(from: note),
              let processed = note.userInfo?[DocumentEmbeddingIndex.notificationProcessedChunksKey] as? Int,
              let total = note.userInfo?[DocumentEmbeddingIndex.notificationTotalChunksKey] as? Int
        else { return }
        // Make sure the doc is in the in-flight set even if a
        // .didStart notification was lost — progress arriving for
        // an unknown doc still represents work happening.
        indexingDocumentIDs.insert(id)
        indexingProgress[id] = IndexingProgress(processed: processed, total: total)
    }

    private func handleComplete(_ note: Notification) {
        guard let id = documentID(from: note) else { return }
        indexingDocumentIDs.remove(id)
        indexingProgress.removeValue(forKey: id)
        if let count = note.userInfo?[DocumentEmbeddingIndex.notificationChunkCountKey] as? Int {
            lastCompletedChunkCounts[id] = count
        }
    }

    private func handleFail(_ note: Notification) {
        guard let id = documentID(from: note) else { return }
        indexingDocumentIDs.remove(id)
        indexingProgress.removeValue(forKey: id)
        // Don't record a chunk count for failures — UI must not show
        // "Indexed 0 sections" or similar.
        lastCompletedChunkCounts.removeValue(forKey: id)
    }

    private func handleMetadataStart(_ note: Notification) {
        guard let id = documentID(from: note) else { return }
        metadataExtractingDocumentIDs.insert(id)
    }

    private func handleMetadataComplete(_ note: Notification) {
        guard let id = documentID(from: note) else { return }
        metadataExtractingDocumentIDs.remove(id)
    }

    private func handleMetadataFail(_ note: Notification) {
        guard let id = documentID(from: note) else { return }
        // Treat failure same as completion for UI purposes — the
        // metadata stage is no longer in flight, the ring should
        // disappear. The document still works without metadata.
        metadataExtractingDocumentIDs.remove(id)
    }

    private func documentID(from note: Notification) -> UUID? {
        note.userInfo?[DocumentEmbeddingIndex.notificationDocumentIDKey] as? UUID
    }
}
// ========== BLOCK 01: INDEXING TRACKER - END ==========
