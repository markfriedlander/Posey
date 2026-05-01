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

    /// Last completed chunk count per document, kept for ~few seconds
    /// after completion so the UI can show a brief "Indexed N
    /// sections." confirmation. Cleared via `dismissCompletion(for:)`
    /// or after a configurable retention window. Not used in v1's
    /// minimal banner — present so a future "Indexed N" pill UI can
    /// read it without reshaping the model.
    @Published private(set) var lastCompletedChunkCounts: [UUID: Int] = [:]

    private var subscriptions: Set<AnyCancellable> = []

    init(notificationCenter: NotificationCenter = .default) {
        notificationCenter.publisher(for: .documentIndexingDidStart)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleStart(note) }
            .store(in: &subscriptions)
        notificationCenter.publisher(for: .documentIndexingDidComplete)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleComplete(note) }
            .store(in: &subscriptions)
        notificationCenter.publisher(for: .documentIndexingDidFail)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleFail(note) }
            .store(in: &subscriptions)
    }

    /// Convenience the UI calls to ask "is this document being indexed
    /// right now?" without unwrapping the published set every time.
    func isIndexing(_ documentID: UUID) -> Bool {
        indexingDocumentIDs.contains(documentID)
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
    }

    private func handleComplete(_ note: Notification) {
        guard let id = documentID(from: note) else { return }
        indexingDocumentIDs.remove(id)
        if let count = note.userInfo?[DocumentEmbeddingIndex.notificationChunkCountKey] as? Int {
            lastCompletedChunkCounts[id] = count
        }
    }

    private func handleFail(_ note: Notification) {
        guard let id = documentID(from: note) else { return }
        indexingDocumentIDs.remove(id)
        // Don't record a chunk count for failures — UI must not show
        // "Indexed 0 sections" or similar.
        lastCompletedChunkCounts.removeValue(forKey: id)
    }

    private func documentID(from note: Notification) -> UUID? {
        note.userInfo?[DocumentEmbeddingIndex.notificationDocumentIDKey] as? UUID
    }
}
// ========== BLOCK 01: INDEXING TRACKER - END ==========
