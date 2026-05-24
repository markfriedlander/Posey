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
}

// ========== BLOCK 01: INDEXING TRACKER - END ==========
