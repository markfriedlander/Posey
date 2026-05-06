import Foundation

// ========== BLOCK 01: DEBUG LOG HELPER - START ==========
/// Task 13 #3 (2026-05-03): Posey's diagnostic logging is gated by
/// build configuration. `dbgLog(...)` is a thin wrapper over `NSLog`
/// in DEBUG builds and a no-op in RELEASE — no string interpolation,
/// no system-log overhead, no runtime cost. Production users never
/// see Posey's verbose diagnostic chatter (AskPosey refusal detection,
/// citation scoring, retry traces, etc.).
///
/// Use `dbgLog(...)` for chatty diagnostics that help debugging during
/// development. Reserve `NSLog` itself for **error paths that should
/// be visible in production crash reports** (persistence failures,
/// unexpected state). Both styles coexist.
///
/// Format string follows `NSLog`'s rules — `%@` for objects, `%d` for
/// ints, etc. Variadic CVarArg matches NSLog's signature so
/// callsites can be a near drop-in replacement.
@inlinable
public func dbgLog(_ format: String, _ args: CVarArg...) {
    #if DEBUG
    withVaList(args) { va in
        NSLogv(format, va)
    }
    let rendered = String(format: format, arguments: args)
    InAppLogBuffer.shared.append(rendered)
    #endif
}
// ========== BLOCK 01: DEBUG LOG HELPER - END ==========


// ========== BLOCK 02: IN-APP LOG BUFFER - START ==========
/// Circular buffer of recent log lines, kept on-device so the local
/// API can serve them via the LOGS verb. Diagnostic-only — production
/// builds skip the append.
public final class InAppLogBuffer: @unchecked Sendable {
    public static let shared = InAppLogBuffer()
    private let queue = DispatchQueue(label: "posey.inapp.log", qos: .utility)
    private var entries: [(date: Date, message: String)] = []
    private let maxEntries = 2000

    private init() {}

    public func append(_ message: String) {
        let date = Date()
        queue.async {
            self.entries.append((date, message))
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    /// Return up to `limit` most-recent log lines. `since` (epoch ms)
    /// optionally trims to entries newer than the given timestamp so a
    /// poller can fetch only what's new.
    public func recent(limit: Int = 200, sinceEpochMs: Int? = nil) -> [[String: Any]] {
        var snapshot: [(Date, String)] = []
        queue.sync {
            snapshot = self.entries
        }
        let cutoff = sinceEpochMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        let filtered: [(Date, String)]
        if let cutoff {
            filtered = snapshot.filter { $0.0 > cutoff }
        } else {
            filtered = snapshot
        }
        let tail = filtered.suffix(limit)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return tail.map { entry in
            ["timestamp": formatter.string(from: entry.0),
             "epochMs": Int(entry.0.timeIntervalSince1970 * 1000),
             "message": entry.1]
        }
    }

    public func clear() {
        queue.async { self.entries.removeAll() }
    }
}
// ========== BLOCK 02: IN-APP LOG BUFFER - END ==========
