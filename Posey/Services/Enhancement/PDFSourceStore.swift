import Foundation

// ========== BLOCK 01: PDF SOURCE STORE - START ==========

/// Phase 2.2 source-PDF persistence for the background enhancement
/// window.
///
/// The synchronous import path used to discard the source PDF bytes
/// the moment parsing finished (the import temp URL was unlinked via
/// `defer`). Phase 2.2 moves Tier 2 (Vision OCR on flagged pages) out
/// of the synchronous path, which means the runner needs the source
/// PDF available later — after the import finishes, after the app
/// has been backgrounded, even after the app has been relaunched
/// (bootstrap recovery).
///
/// Storage policy:
///
///   - Location: `~/Library/Application Support/PoseySourcePDFs/<uuid>.pdf`
///   - Application Support is correct for app-managed, non-user-facing
///     data that should survive launches and **not** be evicted by iOS
///     under storage pressure (Caches can be evicted; we need the
///     source until enhancement completes).
///   - Saved by `PDFLibraryImporter.persistParsedDocument` immediately
///     after the document row + chunks + sidecar are persisted.
///   - Deleted on three triggers:
///       1. The enhancement service transitions the document to
///          `enhancement_status = 'complete'` — work is done, source
///          is no longer needed
///       2. The document is deleted (LibraryViewModel.deleteDocument,
///          DELETE_DOCUMENT antenna verb, RESET_ALL antenna verb)
///       3. Enhancement fails permanently and the doc transitions
///          to `'failed'` — keep the document, drop the source
///   - Storage cost is bounded to documents currently mid-enhancement.
///     Typical PDF 1–10 MB; typical enhancement window seconds to a
///     few minutes. The on-disk overhead is negligible in practice.
///
/// Best-effort: read/write failures log and return nil/false without
/// throwing. The enhancement service degrades gracefully — if a doc's
/// source PDF is missing (older import, evicted by an external tool,
/// disk corruption), it logs and skips Tier 2 for that doc, leaving
/// it in a state where Tier 1 text remains the final output.
struct PDFSourceStore {

    private static var directory: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("PoseySourcePDFs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
        return dir
    }

    /// Where the source PDF for `documentID` lives on disk. Nil only
    /// when Application Support is unavailable (vanishingly rare).
    static func url(for documentID: UUID) -> URL? {
        directory?.appendingPathComponent("\(documentID.uuidString).pdf")
    }

    /// Persist the source PDF bytes for a document. Called once at
    /// import time. Returns true on success.
    static func save(_ data: Data, for documentID: UUID) -> Bool {
        guard let url = url(for: documentID) else {
            dbgLog("PDFSourceStore: no Application Support directory available")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            dbgLog("PDFSourceStore: save failed for %@: %@",
                   documentID.uuidString, String(describing: error))
            return false
        }
    }

    /// Read the source PDF bytes for a document. Returns nil when the
    /// source doesn't exist (older import, already deleted post-
    /// enhancement, etc.).
    static func read(_ documentID: UUID) -> Data? {
        guard let url = url(for: documentID),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            dbgLog("PDFSourceStore: read failed for %@: %@",
                   documentID.uuidString, String(describing: error))
            return nil
        }
    }

    /// Remove the source PDF for a document. Called on document
    /// delete and on enhancement completion. No-op if the source
    /// wasn't on disk to begin with.
    static func delete(_ documentID: UUID) {
        guard let url = url(for: documentID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// ========== BLOCK 01: PDF SOURCE STORE - END ==========
