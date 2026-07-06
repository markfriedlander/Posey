import Foundation

// ========== BLOCK 01: IMPORT TRACE — PURPOSE - START ==========
/// A durable, timestamped record of a document import's order of operations,
/// written to a FILE ON DISK so it survives a force-quit of the app.
///
/// Why this exists (Mark, 2026-07-05): a large scanned PDF (the 814-page
/// SAG-AFTRA CBA) froze during import with the on-screen counter stuck on
/// "OCR: page 140". That counter only ticks on scanned (no-text) pages and
/// says nothing about the many post-loop phases, so it could NOT tell us
/// which page or which step actually stalled. The in-memory `InAppLogBuffer`
/// (served by the `LOGS` verb) is wiped on force-quit, so it can't survive a
/// hang the user has to kill. This logger:
///   • appends one line per import step, each stamped with elapsed time and
///     the two memory numbers that matter on the 8 GB phone
///     (`os_proc_available_memory` = how much more we can use before iOS
///     jetsam-kills us; `phys_footprint` = how much we're using now);
///   • FLUSHES (`fsync`) after every line, so the LAST line on disk is the
///     step the import was inside when it froze;
///   • persists to Documents, so after the user force-quits and relaunches,
///     `DUMP_IMPORT_TRACE` reads back exactly where the clock stopped.
///
/// Best-effort by design: every file operation is guarded and silent on
/// failure — a diagnostic must never itself break or slow an import.
// ========== BLOCK 01: IMPORT TRACE — PURPOSE - END ==========

// ========== BLOCK 02: IMPORT TRACE — LOGGER - START ==========
public final class ImportTrace: @unchecked Sendable {
    public static let shared = ImportTrace()

    private let lock = NSLock()
    private var handle: FileHandle?
    private var startDate: Date?

    /// Documents/import-trace.log — the durable record read back by
    /// `DUMP_IMPORT_TRACE`. Documents survives relaunch and app updates.
    private static var fileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("import-trace.log")
    }

    private init() {}

    /// Start a trace for one import. **Never truncates** — the trace ACCUMULATES
    /// across imports and is erased ONLY by an explicit `CLEAR_IMPORT_TRACE`
    /// (Mark, 2026-07-05: "it has to stay there until it's deleted on purpose by
    /// us"). Each import appends a delimited header, then holds a write handle
    /// open so every `event` is a cheap append + fsync (not a full-file rewrite).
    public func begin(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        // Close any handle left open by a previous (killed) run.
        try? handle?.close()
        handle = nil
        startDate = Date()

        guard let url = Self.fileURL else { return }
        // A blank line before each header separates one import's record from the
        // previous one when several accumulate in the same file.
        let header = "\n===== IMPORT TRACE: \(label) =====\n" +
                     "started \(Self.wallClock(Date()))\n" +
                     "columns: +elapsedSeconds  free=availableMB  used=footprintMB  event\n"
        do {
            // Create the file on the very first import; NEVER overwrite an
            // existing trace — open it and seek to the end so this import's
            // lines are appended after any prior import's record.
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            if let data = header.data(using: .utf8) {
                try h.write(contentsOf: data)
                try h.synchronize()
            }
            handle = h
        } catch {
            handle = nil
        }
    }

    /// Append one timestamped, memory-stamped line and flush it to disk
    /// immediately so a freeze leaves the in-progress step as the last line.
    public func event(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        let elapsed = startDate.map { Date().timeIntervalSince($0) } ?? 0
        let free = processAvailableMemoryMB()
        let used = processFootprintMB()
        let freeStr = free.isInfinite ? "  n/a" : String(format: "%5.0f", free)
        let line = String(format: "+%8.2fs  free=%@MB  used=%5.0fMB  %@\n",
                          elapsed, freeStr, used, message)
        guard let data = line.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()   // fsync — survive a hard kill
        } catch {
            // best-effort: drop the line rather than disturb the import
        }
    }

    /// Mark the import complete and close the handle.
    public func end(_ message: String) {
        event(message)
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    /// Read the whole trace back (for the `DUMP_IMPORT_TRACE` verb). Uses an
    /// independent read so it works while an import is still writing.
    public func contents() -> String {
        guard let url = Self.fileURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return "(no import trace recorded)"
        }
        return text
    }

    /// Delete the trace file (for `CLEAR_IMPORT_TRACE`).
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    private static func wallClock(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
// ========== BLOCK 02: IMPORT TRACE — LOGGER - END ==========
