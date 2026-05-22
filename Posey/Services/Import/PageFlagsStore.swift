import Foundation

// ========== BLOCK 01: PAGE FLAGS STORE - START ==========

/// JSON sidecar persistence for `PDFPageFlags`.
///
/// Phase 1 calibration storage. One file per document keyed by the
/// document's UUID, written when `PDFLibraryImporter` finishes
/// persisting a parsed PDF. Read on demand by the
/// `LIST_PAGE_FLAGS:<doc-id>` antenna verb.
///
/// Sidecar (not a DB table) because:
///   - calibration is short-lived; we don't want a schema migration
///     for data that may not exist in the final shape
///   - inspecting JSON on disk during calibration is trivial
///   - the file can be deleted without touching the DB if the
///     detector is recalibrated and old records are no longer useful
///
/// Location: `~/Library/Application Support/PoseyPageFlags/<uuid>.json`.
/// Application Support is the appropriate domain for app-managed,
/// non-user-facing data that should survive launches and not be
/// evicted by iOS under storage pressure.
struct PageFlagsStore {

    /// Top-level JSON shape written to disk.
    struct Record: Codable, Sendable {
        let documentID: String
        let fileName: String?
        let pageCount: Int
        let detectorVersion: String
        let assessedAt: Date
        let flags: [PDFPageFlags]

        /// Per-document summary the antenna can hand back without
        /// the caller having to walk the per-page array.
        var summary: Summary {
            let flagged = flags.filter { $0.needsTier2 }
            var modeCounts: [String: Int] = [:]
            for f in flagged {
                modeCounts[f.tier2Mode.rawValue, default: 0] += 1
            }
            // Phase 2: aggregate the Tier 2 runtime outcomes.
            var tier2Counts: [String: Int] = [:]
            for f in flags {
                if let outcome = f.tier2, outcome.ran {
                    tier2Counts[outcome.decision, default: 0] += 1
                }
            }
            return Summary(
                pageCount: pageCount,
                flaggedCount: flagged.count,
                modeCounts: modeCounts,
                tier2Counts: tier2Counts
            )
        }
    }

    struct Summary: Codable, Sendable {
        let pageCount: Int
        let flaggedCount: Int
        let modeCounts: [String: Int]
        /// Phase 2: counts keyed by `Tier2Outcome.decision` for pages
        /// where Tier 2 ran. Includes empty-text fallback outcomes
        /// (`fallback_ocr_used`, `fallback_ocr_empty`) so calibration
        /// has a unified view of every Vision invocation.
        let tier2Counts: [String: Int]
    }

    static let detectorVersion: String = "v1.1-phase2"

    // MARK: Disk layout

    private static var directory: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("PoseyPageFlags", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
        return dir
    }

    private static func fileURL(for documentID: UUID) -> URL? {
        directory?.appendingPathComponent("\(documentID.uuidString).json")
    }

    // MARK: Public

    /// Persist a freshly-assessed set of flags for a document.
    /// Best-effort — failures log but do not throw, since calibration
    /// telemetry should never break an import.
    static func write(
        flags: [PDFPageFlags],
        for documentID: UUID,
        fileName: String?,
        pageCount: Int
    ) {
        guard let url = fileURL(for: documentID) else {
            dbgLog("PageFlagsStore: no Application Support directory available")
            return
        }
        let record = Record(
            documentID: documentID.uuidString,
            fileName: fileName,
            pageCount: pageCount,
            detectorVersion: detectorVersion,
            assessedAt: Date(),
            flags: flags
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            dbgLog("PageFlagsStore: write failed for %@: %@",
                   documentID.uuidString,
                   String(describing: error))
        }
    }

    /// Read flags previously persisted for a document, if any. Returns
    /// nil when no calibration record exists yet (document predates
    /// the detector or was imported in a build without it).
    static func read(documentID: UUID) -> Record? {
        guard let url = fileURL(for: documentID),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Record.self, from: data)
        } catch {
            dbgLog("PageFlagsStore: read failed for %@: %@",
                   documentID.uuidString,
                   String(describing: error))
            return nil
        }
    }

    /// Remove a calibration record. Called on document delete so
    /// stale sidecars don't accumulate.
    static func delete(documentID: UUID) {
        guard let url = fileURL(for: documentID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// ========== BLOCK 01: PAGE FLAGS STORE - END ==========
