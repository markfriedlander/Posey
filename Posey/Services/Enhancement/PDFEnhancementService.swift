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
    /// in a fresh DB mid-session). End-of-enhancement indexing
    /// always routes through `UnitEmbeddingService.shared` since
    /// 8f's tear-down — no per-service wiring needed.
    func configure(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        dbgLog("PDFEnhancementService: configured")
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
    /// Tier 2 = Vision OCR + reconciler + streaming chunk replacement with
    /// reader-aware priority + TTS + viewport locks. Tier 3 = AFM fusion-token
    /// repair (`runTier3`, applied via `DatabaseManager.replaceTokenInUnits`).
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

        // 2026-05-31 (ingestion audit, Bug F) — re-detect document structure
        // against the now-corrected text BEFORE marking complete + firing the
        // chunker. A PDF whose TOC page was a scanned image extracted zero
        // text at Tier-1, so TOC/heading detection found nothing. Tier-2
        // Vision has now filled that text in; re-running the text-pattern
        // detectors recovers the TOC + promotes the chapter headings that
        // were undetectable at import. Runs before the chunker fire so the
        // rebuilt chunks see the corrected unit kinds. No-op (early return)
        // when Tier-1 already found structure.
        await redetectStructureIfNeeded(documentID: documentID)

        if cancelled.contains(documentID) {
            cancelled.remove(documentID)
            return
        }

        do {
            try await MainActor.run {
                try db.updateEnhancementState(documentID: documentID, status: "complete", error: nil)
            }
            // Source PDF no longer needed once enhancement is done — UNLESS the
            // user chose to keep originals (Mark, 2026-06-30), which retains the
            // source so any phase can be re-run later (REPARSE_PDF etc.). Deleting
            // the DOCUMENT still drops its source regardless (that path is separate).
            if !DocumentIndexingQueue.keepOriginalsDefault {
                PDFSourceStore.delete(documentID)
            }

            // 2026-05-23 — Step 8f: the unit-anchored chunker runs
            // at end-of-enhancement. The corrected units are the
            // source of truth and the chunk set must reflect them.
            // Fire-and-forget; the service is actor-serialized
            // internally. (The legacy DocumentEmbeddingIndex handoff
            // that used to live here was removed in 8f.)
            Task.detached {
                await UnitEmbeddingService.shared.enqueueIndexing(
                    documentID: documentID, databaseManager: db
                )
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

    // MARK: Structure re-detection (Bug F)

    /// Re-run TEXT-PATTERN structure detection against the corrected unit text
    /// and, if a TOC/headings were recovered that Tier-1 missed, persist them.
    ///
    /// **The bug this fixes.** TOC + heading detection ran only at Tier-1
    /// import. A PDF whose TOC page is a scanned IMAGE yields zero text for
    /// that page at Tier-1, so the detectors find nothing and the document
    /// opens with 0 navigation. Tier-2 Vision later OCRs the TOC page and
    /// writes the recovered text into the page's units — but detection never
    /// re-ran, so the document stayed 0-nav and the recovered TOC read aloud
    /// as dot-leader prose. This method closes that gap.
    ///
    /// **STEP 3 — the category + why the gate keys on TOC ENTRIES, not skip.**
    /// The category is "any PDF whose navigable structure (TOC entries +
    /// heading units) is missing after import, but whose post-enhancement text
    /// can yield it." The thing we recover is NAVIGATION — `document_toc`
    /// entries the chapter sheet jumps to, plus promoted heading units. The
    /// reliable "navigation is missing" signal is therefore `tocCount == 0`,
    /// NOT the skip offset. This distinction is load-bearing and was found
    /// empirically (see below). Within the category:
    ///   • Tier-1 found NOTHING (toc=0, skip=0): re-detect builds both. ✓
    ///   • Tier-1 set a SKIP but no entries (toc=0, skip>0): re-detect builds
    ///     the entries + headings and preserves/refines the skip. ✓ This is the
    ///     dominant real case and the one a skip-based gate wrongly blocked.
    ///     It happens because `PDFDocumentImporter` OCRs no-text pages
    ///     synchronously at import (2× DeviceGray) — good enough for the
    ///     generalized detector to set a skip REGION, but the import-OCR
    ///     reading order (titles in one column, page numbers in another) often
    ///     defeats the run-on entry parser, so 0 entries. Tier-2's 4× extractor
    ///     then produces clean title→number adjacency the parser CAN read — but
    ///     only if the re-detect actually runs. Verified on the synthetic
    ///     scanned-TOC fixture: import set skip=221/toc=0; Tier-2 text parsed
    ///     to 6 entries once the gate let the re-detect proceed.
    ///   • No formal TOC at all: re-detect finds nothing → stays 0-nav. ✓ no
    ///     regression (cheap string-only pass, no inference).
    ///   • PDF that ALREADY has TOC entries (toc>0 — dot-leader text layer or
    ///     PDFKit outline): we **early-return**. Re-detecting a doc that already
    ///     navigates risks DOUBLING the TOC or fighting outline-derived entries
    ///     this text-only pass can't reproduce. Keying on `tocCount == 0` fixes
    ///     the bug with zero doubling risk. Residual: a doc with a PARTIAL
    ///     Tier-1 TOC plus an additional scanned-TOC page does not get the
    ///     scanned entries merged in — merging partial TOCs across a text/
    ///     outline boundary is riskier, has no corpus example, and is filed
    ///     rather than built speculatively.
    ///   • Heading promotion uses the hardened title-validated
    ///     `applyHeadingMarkers` — a recovered TOC title that doesn't head any
    ///     body unit is dropped (no false headings), and OCR line-wrap in the
    ///     titles ("Chapter One: The Salt\nMarsh") is absorbed by its
    ///     whitespace-tolerant match.
    ///
    /// Deliberately uses only the TEXT-PATTERN detectors (dot-leader +
    /// generalized), NOT the PDFKit outline / outline-walker: those read the
    /// PDF's embedded structural outline, which is import-time metadata Tier-2
    /// OCR never changes — re-running them would find exactly what Tier-1 did.
    private func redetectStructureIfNeeded(documentID: UUID) async {
        guard let db = databaseManager else { return }

        struct Inputs {
            let plainText: String
            let units: [ContentUnit]
            let tocCount: Int
            let skipOffset: Int
        }

        let inputs: Inputs?
        do {
            inputs = try await MainActor.run { () throws -> Inputs in
                let pt = try db.plainText(for: documentID) ?? ""
                let us = try db.units(for: documentID)
                let toc = try db.tocEntries(for: documentID)
                // The skip OFFSET (>0) — NOT skip_unit_id — is the reliable
                // "Tier-1 found a skip region" signal. The importer sets
                // skip_unit_id to the first unit even when the offset is 0
                // (firstUnit(atOrAfterPlainTextOffset: 0) returns units.first),
                // so its presence would falsely gate every PDF out of the
                // re-detect. Verified empirically on the scanned-TOC fixture:
                // a doc with 0 TOC and 0 skip still had skip_unit_id set.
                let skipOffset = try db.playbackSkipOffset(for: documentID)
                return Inputs(
                    plainText: pt,
                    units: us,
                    tocCount: toc.count,
                    skipOffset: skipOffset
                )
            }
        } catch {
            dbgLog("PDFEnhancementService: Bug F re-detect — input read failed for %@: %@",
                   documentID.uuidString, String(describing: error))
            return
        }
        guard let inputs else { return }

        // Gate: re-detect only when NAVIGATION is missing (no TOC entries).
        // A pre-existing skip with zero entries still needs entries built, so
        // the gate keys on tocCount, not skip (see the doc comment above).
        if inputs.tocCount > 0 {
            dbgLog("PDFEnhancementService: Bug F re-detect — %@ already has %d TOC entries, skipping",
                   documentID.uuidString, inputs.tocCount)
            return
        }
        if inputs.plainText.isEmpty || inputs.units.isEmpty { return }

        // Reconstruct per-page text from the corrected units: each pageBreak
        // unit starts a page; prose-bearing units accumulate; join a page's
        // text with "\n\n" (the persister's plain_text join convention, so the
        // offsets line up with applyHeadingMarkers' own unit-start arithmetic).
        let ordered = inputs.units.sorted { $0.sequence < $1.sequence }
        var pageTexts: [String] = []
        var current: [String] = []
        var startedPage = false
        for unit in ordered {
            if unit.kind == .pageBreak {
                if startedPage { pageTexts.append(current.joined(separator: "\n\n")) }
                current = []
                startedPage = true
            } else if unit.kind.carriesProseText {
                current.append(unit.text)
            }
        }
        if startedPage { pageTexts.append(current.joined(separator: "\n\n")) }
        if pageTexts.isEmpty { return }

        // Run the text-pattern detectors against the corrected text.
        let detected = PDFTextStructureDetector.detect(
            pageTexts: pageTexts, plainText: inputs.plainText
        )
        guard detected.skipOffset > 0 || !detected.entries.isEmpty else {
            dbgLog("PDFEnhancementService: Bug F re-detect — nothing recovered on %@",
                   documentID.uuidString)
            return
        }

        // Skip offset: prefer the freshly-detected region, but never REGRESS a
        // skip the importer already established.
        let finalSkipOffset = detected.skipOffset > 0 ? detected.skipOffset : inputs.skipOffset

        // Promote headings via the hardened shared path. Gate promotion by the
        // skip UNIT (identity) so a TOC-LISTING entry in the front matter is not
        // promoted to a chapter heading — only the body occurrences are. Ruler
        // migration #3b (2026-06-28): translate the R1 skip offset to a unit once
        // (against inputs.units) rather than comparing offsets across two rulers.
        let markersByOffset: [Int: ContentUnitBuilder.HeadingMarker] = Dictionary(
            detected.entries.map {
                ($0.plainTextOffset, ContentUnitBuilder.HeadingMarker(level: $0.level, title: $0.title))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let promotedUnits = ContentUnitBuilder.applyHeadingMarkers(
            to: inputs.units,
            headingMarkersByOffset: markersByOffset,
            skipUnitID: ContentUnitBuilder.firstUnit(
                in: inputs.units, atOrAfterPlainTextOffset: finalSkipOffset)?.id
        )

        // Diff: which units became headings? Map by id for a stable compare.
        let oldKindByID = Dictionary(uniqueKeysWithValues: inputs.units.map { ($0.id, $0.kind) })
        var promotions: [DatabaseManager.HeadingPromotion] = []
        for unit in promotedUnits where unit.kind == .heading && oldKindByID[unit.id] == .prose {
            promotions.append(DatabaseManager.HeadingPromotion(
                unitID: unit.id,
                level: unit.metadata.headingLevel ?? 1,
                titleLength: unit.metadata.titleLength
            ))
        }

        // Skip offset already resolved above (finalSkipOffset). Never REGRESS a
        // skip the importer established — if the re-detect produced entries but
        // no skip region (rare; the dot-leader path can), the Tier-1 skip is
        // kept. Map it to a unit.
        let skipUnitID = ContentUnitBuilder.firstUnit(
            in: inputs.units, atOrAfterPlainTextOffset: finalSkipOffset
        )?.id

        let storedTOC: [StoredTOCEntry] = detected.entries.compactMap { e in
            // Resolve to the durable paragraph identity (same ruler); drop one that
            // can't anchor (Position Rule).
            guard let uid = ContentUnitBuilder.firstUnit(
                in: inputs.units, atOrAfterPlainTextOffset: e.plainTextOffset)?.id else { return nil }
            return StoredTOCEntry(
                title: e.title,
                plainTextOffset: e.plainTextOffset,
                unitID: uid,
                playOrder: e.playOrder,
                level: e.level
            )
        }

        // Snapshot the accumulated promotions into a `let` so the MainActor.run
        // closure captures by value (Swift 6 concurrency — no captured var).
        let finalPromotions = promotions
        do {
            try await MainActor.run {
                try db.applyRedetectedStructure(
                    documentID: documentID,
                    tocEntries: storedTOC,
                    promotions: finalPromotions,
                    skipUnitID: skipUnitID,
                    skipOffset: finalSkipOffset,
                    skipSource: finalSkipOffset > 0 ? "heuristic" : ""
                )
            }
            dbgLog("PDFEnhancementService: Bug F re-detect APPLIED on %@ — toc=%d headings=%d skip=%d",
                   documentID.uuidString, storedTOC.count, finalPromotions.count, finalSkipOffset)
        } catch {
            dbgLog("PDFEnhancementService: Bug F re-detect — persist failed for %@: %@",
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

    // 2026-06-19 (Mark) — Tier-2 Vision OCR progress, for the embedding status
    // board's pipeline view. Per-flagged-page: didStart (total), didProgress
    // (processed/total) after each page lands, didComplete to clear. Mirrors the
    // RAPTOR notification shape that `IndexingTracker` already consumes.
    static let ocrDidStart = Notification.Name("Posey.PDFEnhancementService.ocrDidStart")
    static let ocrDidProgress = Notification.Name("Posey.PDFEnhancementService.ocrDidProgress")
    static let ocrDidComplete = Notification.Name("Posey.PDFEnhancementService.ocrDidComplete")
    static let ocrProcessedPagesKey = "ocrProcessedPages"
    static let ocrTotalPagesKey = "ocrTotalPages"

    /// Post an OCR progress notification on the main thread (value-type payload).
    private func postOCR(_ name: Notification.Name, documentID: UUID,
                         processed: Int, total: Int) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: name, object: nil,
                userInfo: [Self.notificationDocumentIDKey: documentID,
                           Self.ocrProcessedPagesKey: processed,
                           Self.ocrTotalPagesKey: total])
        }
    }

    // MARK: Tier 3 — AFM fusion repair

    /// Run Tier 3 (AFM fusion-token correction) on the document.
    /// Detects suspect tokens via `SuspectTokenDetector`, skips any
    /// already-corrected ones (idempotency via
    /// `document_afm_corrections`), and for each remaining token:
    /// asks AFM via `FusionCorrectionAFM.correct`, records the
    /// verdict, and (if AFM proposed a change) applies the swap
    /// across the whole document via `DatabaseManager.replaceTokenInUnits`.
    ///
    /// Sequential per Mark's directive — one token per AFM call (Rule
    /// 6: local inference is free; batching gives no quality benefit
    /// for a per-token decision and costs prompt clarity). The actor
    /// isolation provides natural pacing without an explicit
    /// cooldown (matches Phase B chunk enhancement).
    /// Extract the line/sentence around the FIRST occurrence of `token`
    /// in `plainText` so AFM can judge fusion-vs-notation in context
    /// (Mark, 2026-06-09). Returns the enclosing newline-delimited line,
    /// capped to a ~240-char window centered on the token so a long
    /// paragraph doesn't bloat the prompt. Falls back to the bare token
    /// if it can't be located (shouldn't happen — detector found it here).
    private static func contextLine(for token: String, in plainText: String) -> String {
        guard let r = plainText.range(of: token) else { return token }
        let lineStart = plainText.range(of: "\n", options: .backwards,
                                        range: plainText.startIndex..<r.lowerBound)?.upperBound
            ?? plainText.startIndex
        let lineEnd = plainText.range(of: "\n",
                                      range: r.upperBound..<plainText.endIndex)?.lowerBound
            ?? plainText.endIndex
        var line = String(plainText[lineStart..<lineEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLen = 240
        if line.count > maxLen, let tr = line.range(of: token) {
            let tStart = line.distance(from: line.startIndex, to: tr.lowerBound)
            let half = maxLen / 2
            let lo = max(0, tStart - half)
            let hi = min(line.count, tStart + token.count + half)
            let loIdx = line.index(line.startIndex, offsetBy: lo)
            let hiIdx = line.index(line.startIndex, offsetBy: hi)
            line = String(line[loIdx..<hiIdx])
        }
        return line.isEmpty ? token : line
    }

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

        // 2026-05-23 — Step 8f: the dead `existingChunks` read /
        // legacy embedding-kind sniff was removed. End-of-tier
        // chunker fire (UnitEmbeddingService) handles chunk
        // regeneration on the updated units.

        var processedCount = 0
        var appliedCount = 0
        for token in toProcess {
            if cancelled.contains(documentID) {
                dbgLog("PDFEnhancementService: Tier 3 cancelled mid-run on %@",
                       documentID.uuidString)
                return
            }

            // 2026-06-09 (Mark) — give AFM the line the token sits in so
            // it can tell a real word-fusion from formula/code/notation
            // (the `Va:(atO)=a → VA AT O` formula-mangling fix). The
            // context comes straight from this plainText, where the
            // detector found the token.
            let context = Self.contextLine(for: token, in: plainText)
            // Global serial lane — AFM fusion-split is heavy background
            // compute; only one heavy op runs app-wide at a time.
            let verdict = await HeavyWorkLane.shared.run(label: "AFM-fusion") {
                await FusionCorrectionAFM.correct(token, context: context)
            }
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
            // affected units regenerate in the same transaction; the
            // stored character_count refreshes once at end (plain_text /
            // display_text are derived from units on demand, not stored).
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

        // OCR progress instrumentation (board pipeline view). Total = ALL flagged
        // pages; processed starts at the already-done set. `defer` guarantees the
        // complete-clear fires on every exit (cancel / error / normal).
        let ocrTotal = allFlagged.count
        postOCR(Self.ocrDidStart, documentID: documentID, processed: pagesDone.count, total: ocrTotal)
        defer { postOCR(Self.ocrDidComplete, documentID: documentID, processed: ocrTotal, total: ocrTotal) }

        // 2026-05-23 — Step 8f: existing-chunks read removed.
        // Tier 2 page swaps work directly on units now; the
        // chunker fires end-of-enhancement.

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
                let locked = await pageIsLockedForUpdate(
                    page.pageIndex,
                    documentID: documentID,
                    snapshot: snapshot,
                    db: db
                )
                if !locked {
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
                postOCR(Self.ocrDidProgress, documentID: documentID,
                        processed: pagesDone.count, total: ocrTotal)
                continue
            }

            // 2026-05-27 — Run PDFWatermarkStripper on Vision OCR
            // output. Tier 1 (PDFKit) already passes through the
            // stripper at import time, so the persisted plainText is
            // clean. But Tier 2 (Vision) bypassed the stripper — and
            // Vision picks up watermarks PDFKit had stripped (the
            // ChmMagic banner in Cryptography for Dummies is the
            // canonical case: PDFKit reads it as a single per-page
            // string the stripper recognizes, while Vision reads it
            // as visually-rendered text that matches the same regex).
            // Without stripping, the reconciler accepts the Vision
            // text as "more text wins" and reintroduces the watermark.
            // Global serial lane — Vision OCR is the heaviest background op;
            // run it as the single in-flight heavy op (off-main, serialized).
            let rawVisionText = await HeavyWorkLane.shared.run(label: "OCR-page\(page.pageIndex)") {
                PDFTier2VisionExtractor.extract(pdfPage)
            }
            let visionText = PDFWatermarkStripper.strip(rawVisionText)
            if rawVisionText.count != visionText.count {
                dbgLog("PDFEnhancementService: page %d on %@ — watermark stripped from Vision (%d → %d chars)",
                       page.pageIndex, documentID.uuidString,
                       rawVisionText.count, visionText.count)
            }

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
                // sentences regenerate; stored character_count refreshes
                // (plain_text / display_text derive from units on demand).
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

    /// **8f follow-up #12 — unit-aware page lock.**
    ///
    /// Returns true when applying a Tier 2 rewrite to this page
    /// would yank text out from under the reader's eyes — i.e.
    /// the unit the user's current sentence sits in belongs to
    /// this page's content unit set.
    ///
    /// Cheap path (no DB query) when:
    ///   - The reader has no document open (`openDocumentID` nil)
    ///   - The reader is on a different document
    ///   - The reader hasn't resolved a current unit yet (e.g. mid-
    ///     content-load, or sentence offset out of bounds)
    ///
    /// When all three above are false, query `unitIDsForPage` on
    /// main and check membership. The query is linear in unit
    /// count and runs at most once per page in the work-queue
    /// loop — well within the budget for the per-page cadence.
    ///
    /// Defensive cap: `maxLockDeferralsPerPage` upstream still
    /// applies if a chunk is *persistently* locked (user parked
    /// on a page Tier 2 wants to rewrite). The worst case is
    /// well-bounded.
    private func pageIsLockedForUpdate(
        _ pageIndex: Int,
        documentID: UUID,
        snapshot: ReaderObservation.Snapshot,
        db: DatabaseManager
    ) async -> Bool {
        guard snapshot.openDocumentID == documentID,
              let unitID = snapshot.currentUnitID else {
            return false
        }
        let pageUnits: Set<UUID>
        do {
            pageUnits = try await MainActor.run {
                try db.unitIDsForPage(documentID: documentID, pageNumber: pageIndex)
            }
        } catch {
            // DB error → fail open (don't block forward progress).
            return false
        }
        return pageUnits.contains(unitID)
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

    // 2026-05-23 — Step 8f: the `segmentAndEmbed` static helper
    // fed the legacy `DatabaseManager.rewritePageText` transaction,
    // which was itself deleted earlier in the rebuild (commit
    // `862883a`). With no callers remaining, the helper is gone too.
}

// ========== BLOCK 01: PDF ENHANCEMENT SERVICE - END ==========
