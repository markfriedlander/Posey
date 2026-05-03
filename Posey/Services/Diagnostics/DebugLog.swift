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
    #endif
}
// ========== BLOCK 01: DEBUG LOG HELPER - END ==========
