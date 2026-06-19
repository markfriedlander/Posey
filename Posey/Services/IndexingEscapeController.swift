import Foundation
import Combine

// ========== BLOCK 01: INDEXING ESCAPE CONTROLLER - START ==========

/// Pillar 3 of the post-incident hardening — the user-facing **escape switch**.
///
/// **Why (2026-06-17 incident).** When a batch import saturated the phone, the
/// only thing that stopped the grind was force-quitting the app; the antenna
/// `RESET_ALL` timed out because it ran on the pegged device. This is the
/// in-app, main-thread control that lets a reader halt all background indexing
/// instantly and rebuild cleanly — no force-quit, no developer tools.
///
/// **What one tap does (Mark, 2026-06-18):**
///   1. **Halt now** — `DocumentIndexingQueue.expungeAll()` cancels the in-flight
///      document's `Task` (stops heavy work within a fine-grained cancellation
///      check, ~1–2s even under load) and clears both lanes.
///   2. **Discard the suspect index** — every affected document's embedding
///      chunks (leaves + summaries) are cleared, so the rebuild starts clean
///      rather than resuming an unknown, possibly-corrupted midpoint. The
///      readable document text is written atomically at import and is NOT
///      touched — books stay readable throughout.
///   3. **Rebuild when safe, not now** — a cleared document has 0 chunks, which
///      is exactly the "needs indexing" signal `healAbandonedIndexing` already
///      uses, so it survives an app restart. Within the session, a rebuild does
///      NOT auto-fire while the device is hot: if the halt happened under
///      thermal pressure, the rebuild fires automatically once the device cools
///      to `.nominal`; if the halt happened while cool (a deliberate stop, not a
///      heat event), it waits for an explicit "Rebuild now" tap. Either way the
///      rebuild runs back through the same serial + thermal-paced queue, so it
///      can never re-saturate.
@MainActor
final class IndexingEscapeController: ObservableObject {

    static let shared = IndexingEscapeController()

    /// Documents halted + cleared, awaiting a rebuild. Drives the "N book(s)
    /// waiting to rebuild" affordance. Cleared as each is re-enqueued.
    @Published private(set) var pendingReindex: Set<UUID> = []
    /// True briefly while a halt is executing (expunge + clear), so the UI can
    /// disable the button and avoid a double-tap.
    @Published private(set) var isHalting = false
    /// True when the most recent halt happened under thermal pressure — the
    /// rebuild is waiting for the device to cool (vs. a cool-state manual stop
    /// that waits for an explicit tap). Drives the status copy.
    @Published private(set) var waitingForCooldown = false

    private var database: DatabaseManager?
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    /// Wire the live DatabaseManager and start watching thermal state. Called
    /// once at launch, after `DocumentIndexingQueue` is configured.
    func configure(database: DatabaseManager) {
        self.database = database
        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.thermalStateChanged() }
            .store(in: &cancellables)
        dbgLog("IndexingEscapeController: configured")
    }

    // MARK: - The escape switch

    /// Halt all background indexing immediately and mark the affected documents
    /// for a clean rebuild. Safe to call when nothing is indexing (a no-op that
    /// still clears any lanes).
    func halt() async {
        guard let db = database else { return }
        isHalting = true
        defer { isHalting = false }

        let affected = await DocumentIndexingQueue.shared.expungeAll()

        // Discard each affected document's partial/suspect index so the rebuild
        // is clean. replaceAllUnitEmbeddingChunks([]) deletes every chunk
        // (leaves + summary nodes) → 0 chunks → "needs indexing". Document text
        // is untouched.
        for id in affected {
            try? db.replaceAllUnitEmbeddingChunks([], for: id)
        }
        pendingReindex.formUnion(affected)

        // Only auto-rebuild-on-cool if we halted because the device was hot.
        // A deliberate stop while cool stays stopped until the user taps Rebuild.
        let hot = ProcessInfo.processInfo.thermalState != .nominal
        waitingForCooldown = hot && !pendingReindex.isEmpty
        dbgLog("IndexingEscapeController: HALT — %d doc(s) cleared, hot=%@",
               affected.count, hot ? "yes" : "no")
    }

    /// Rebuild every pending document NOW (explicit user tap), regardless of
    /// thermal state. The queue + governor still serialize and pace it, so this
    /// is safe even if invoked while warm.
    func rebuildNow() {
        drainPending(reason: "user tap")
    }

    // MARK: - Thermal-gated auto-rebuild

    private func thermalStateChanged() {
        guard waitingForCooldown,
              ProcessInfo.processInfo.thermalState == .nominal else { return }
        drainPending(reason: "cooled to nominal")
    }

    private func drainPending(reason: String) {
        guard let db = database, !pendingReindex.isEmpty else { return }
        let ids = pendingReindex
        pendingReindex.removeAll()
        waitingForCooldown = false
        dbgLog("IndexingEscapeController: rebuilding %d doc(s) (%@)", ids.count, reason)
        for id in ids {
            Task.detached {
                await UnitEmbeddingService.shared.enqueueIndexing(
                    documentID: id, databaseManager: db)
            }
        }
    }
}

// ========== BLOCK 01: INDEXING ESCAPE CONTROLLER - END ==========
