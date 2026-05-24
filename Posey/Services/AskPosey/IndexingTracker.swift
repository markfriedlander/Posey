import Foundation
import Combine

// ========== BLOCK 01: INDEXING TRACKER (NEUTERED) - START ==========

/// **Step 8f neutering.** The legacy `DocumentEmbeddingIndex` posted
/// `documentIndexingDidStart/Progress/Complete` notifications that
/// drove the "Still learning this document — N%" UI affordance in
/// the reader's Ask Posey menu. With 8f's tear-down of
/// DocumentEmbeddingIndex, the new `UnitEmbeddingService` actor
/// runs silently (no notifications) — embedding fill is fast
/// enough at typical document sizes that the progress UI proved
/// unnecessary in practice.
///
/// This file is kept as a neutered stub preserving the public
/// surface (`isEnhancing`, `indexingProgress`, `IndexingProgress`,
/// `sharedForChat`) so view code that wires `@StateObject private
/// var indexingTracker = IndexingTracker()` doesn't have to change.
/// All progress queries return nil / false; the UI degrades to "no
/// banner visible" which is the right behavior for the new
/// fast-fill path.
///
/// 2026-05-23 — neutered in Step 8f. A future polish pass could
/// re-wire this to UnitEmbeddingService progress signals; deferred.
final class IndexingTracker: ObservableObject {

    static let sharedForChat = IndexingTracker()

    @Published private(set) var indexingProgress: [UUID: IndexingProgress] = [:]
    /// Always empty — see file-level comment. Kept on the public
    /// surface so SwiftUI `.animation(value:)` modifiers that
    /// observed the legacy set still compile.
    @Published private(set) var indexingDocumentIDs: Set<UUID> = []

    /// Same shape as the legacy struct so view code that destructures
    /// the optional doesn't break.
    struct IndexingProgress: Equatable, Sendable {
        let processed: Int
        let total: Int
        var fraction: Double {
            total > 0 ? Double(processed) / Double(total) : 0
        }
    }

    init() {}

    /// Always returns false — see file-level comment.
    func isEnhancing(_ documentID: UUID) -> Bool {
        return false
    }

    /// Always returns false — see file-level comment. Distinct from
    /// `isEnhancing`: legacy distinguished "currently indexing" from
    /// "currently in metadata enhancement"; the neutered version
    /// collapses both.
    func isIndexing(_ documentID: UUID) -> Bool {
        return false
    }

    /// Always returns nil — see file-level comment. Legacy signature
    /// returned a `Double?` fraction (0…1); preserved here so view
    /// callers (`.unifiedProgress(for:)`) keep compiling.
    func unifiedProgress(for documentID: UUID) -> Double? {
        return nil
    }
}

// ========== BLOCK 01: INDEXING TRACKER (NEUTERED) - END ==========
