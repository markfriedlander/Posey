import Foundation

// ========== BLOCK 01: READER OBSERVATION - START ==========

/// Phase 2.2 reader-state hub consulted by `PDFEnhancementService` to
/// implement reader-aware processing priority + TTS lock + viewport
/// lock.
///
/// Three flavors of information flow into the enhancement service:
///
///   1. **Current reader offset** — for priority ordering. Pages whose
///      chunks contain or sit near the reader's current position get
///      processed first; chunks far away update freely in the
///      background.
///
///   2. **TTS in-use chunk** — for the speech lock. While a chunk is
///      actively being spoken by AVSpeechSynthesizer, do not update
///      its text. Defer until the utterance completes.
///
///   3. **Viewport-visible chunks** — for the viewport lock. While a
///      chunk is currently visible on screen (rendered by the reader),
///      do not update its text — the user would see a flicker as the
///      text changes underneath them. Defer until the chunk scrolls
///      off.
///
/// Producers (writers):
///   - `ReaderViewModel` posts current offset + visible chunk IDs on
///     scroll / position changes
///   - `SpeechPlaybackService` posts the in-use chunk ID on utterance
///     enqueue / didFinish / didCancel
///
/// Consumer (reader):
///   - `PDFEnhancementService` reads via `await MainActor.run { ... }`
///     at every chunk-update boundary
///
/// Single global @MainActor instance — values are small, mutations are
/// frequent (every scroll tick), and main-actor isolation matches the
/// SwiftUI observers that produce them.
///
/// **Note on chunk identity:** chunks don't have UUIDs in Posey's
/// schema. They're identified by `(documentID, chunkIndex)`. The
/// `ChunkID` typealias below makes that explicit at the call site.
@MainActor
final class ReaderObservation {

    /// Composite chunk identity used everywhere this hub references
    /// "a chunk": document UUID + chunk index within that document.
    /// Hashable for Set membership; small + cheap.
    struct ChunkID: Hashable, Sendable {
        let documentID: UUID
        let chunkIndex: Int
    }

    /// App-wide singleton.
    static let shared = ReaderObservation()

    /// The document the reader currently has open (nil while in the
    /// library or in a non-reader sheet). Snapshotted by the
    /// enhancement service alongside `currentOffset` to decide whether
    /// priority ordering even applies — if `openDocumentID` doesn't
    /// match the document being enhanced, default to sequential.
    private(set) var openDocumentID: UUID?

    /// Character offset of the active sentence (TTS) or the centered/
    /// top sentence (silent reading). nil when no document is open.
    /// Update frequency: ~every few seconds during continuous reading.
    private(set) var currentOffset: Int?

    /// Chunks the reader is currently rendering on screen, identified
    /// by `(documentID, chunkIndex)`. The viewport lock checks
    /// membership here before applying an enhancement update.
    private(set) var visibleChunks: Set<ChunkID> = []

    /// Chunk the speech synthesizer is actively speaking from. Cleared
    /// in the synthesizer delegate's `didFinish` / `didCancel`. The
    /// TTS lock checks against this single value before updating a
    /// chunk's text.
    private(set) var ttsInUseChunk: ChunkID?

    /// **8f follow-up #12 — units-rebuild bridge.**
    ///
    /// Identity of the `document_units` row whose text covers the
    /// reader's current active sentence. Published by `ReaderView` on
    /// segment changes; consumed by `PDFEnhancementService` to decide
    /// whether a Tier 2 page rewrite would yank text out from under
    /// the user's eyes — it would, if the page's unit set contains
    /// this id. nil when no document is open, or before the reader
    /// has finished its first content load.
    ///
    /// Replaces the legacy `(documentID, chunkIndex)` lock surface
    /// (`visibleChunks`, `ttsInUseChunk`) for page-level lock checks
    /// in the post-rebuild architecture. The chunk-id fields are
    /// kept for now in case future code resurrects per-chunk locks.
    private(set) var currentUnitID: UUID?

    /// Posted whenever any of the four fields above changes — so the
    /// enhancement service can drain its per-chunk pending-update
    /// buffer when a chunk that was locked becomes free again.
    static let didChange = Notification.Name("Posey.ReaderObservation.didChange")

    private init() {}

    // MARK: Writers

    func setOpenDocument(_ documentID: UUID?) {
        guard openDocumentID != documentID else { return }
        openDocumentID = documentID
        // Clear stale per-document state.
        currentOffset = nil
        visibleChunks = []
        ttsInUseChunk = nil
        currentUnitID = nil
        post()
    }

    func setCurrentOffset(_ offset: Int?) {
        guard currentOffset != offset else { return }
        currentOffset = offset
        post()
    }

    func setVisibleChunks(_ chunks: Set<ChunkID>) {
        guard visibleChunks != chunks else { return }
        visibleChunks = chunks
        post()
    }

    func setTTSInUse(_ chunk: ChunkID?) {
        guard ttsInUseChunk != chunk else { return }
        ttsInUseChunk = chunk
        post()
    }

    func setCurrentUnit(_ id: UUID?) {
        guard currentUnitID != id else { return }
        currentUnitID = id
        post()
    }

    private func post() {
        NotificationCenter.default.post(name: ReaderObservation.didChange, object: nil)
    }

    // MARK: Reader (consumed by the enhancement service)

    /// Snapshot of all four fields for cross-actor consumption.
    /// Returned by value so the actor that reads it gets a stable
    /// view that won't shift under its feet during processing.
    struct Snapshot: Sendable {
        let openDocumentID: UUID?
        let currentOffset: Int?
        let visibleChunks: Set<ChunkID>
        let ttsInUseChunk: ChunkID?
        let currentUnitID: UUID?
    }

    func snapshot() -> Snapshot {
        Snapshot(
            openDocumentID: openDocumentID,
            currentOffset: currentOffset,
            visibleChunks: visibleChunks,
            ttsInUseChunk: ttsInUseChunk,
            currentUnitID: currentUnitID
        )
    }
}

// ========== BLOCK 01: READER OBSERVATION - END ==========
