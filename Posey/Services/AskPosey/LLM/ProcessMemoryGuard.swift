// ProcessMemoryGuard.swift
// Posey
//
// Faithful port of Hal Universal/ProcessMemoryGuard.swift (2026-05-26).
// iOS process-memory introspection + pre-flight refusal for MLX model
// loads. The load-bearing fix for the same Gemma jetsam case Hal hit
// during MLX→MLX swap with heavy prior context.
//
// Two pieces:
//
//   1. Pre-flight refusal. Before LLMModelFactory.loadContainer runs
//      (which mmaps safetensors and faults pages), check
//      os_proc_available_memory() against the model's estimated
//      requirement. If insufficient, surface a user-facing error
//      instead of letting iOS jetsam-kill the process.
//
//   2. Headroom poll. After unload-during-swap, poll
//      os_proc_available_memory() at ~150 ms intervals up to
//      timeoutSeconds. iOS Mach VM reclamation is lazy; the actual
//      wait depends on prior memory pressure.
//
// Required-memory formula (Hal-calibrated 2026-05-18):
//
//   sizeGB × 1024 × 0.75 + 250
//
// where:
//   - 0.75 ≈ effective dirty-memory ratio for 4-bit quantized
//     safetensors loaded via mmap.
//   - 250 MB safety margin = process baseline (Swift/SwiftUI ~150 MB)
//     + KV-cache headroom + buffer above iOS's dirty-memory cliff.
//
// Calibration note (Hal Item 11, 2026-05-18): an earlier 1.05×/300 MB
// formula refused Gemma 4 E2B at cold launch where the iPhone 16 Plus
// reports only ~3.3 GB available. The 0.75× ratio lets cold-launch
// Gemma succeed (need 3015 MB, have ~3300) while still catching the
// swap-after-heavy-context case.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Bytes the process can still allocate before iOS terminates it,
/// converted to MB. Returns `.infinity` on platforms where the API
/// isn't available so callers fail open rather than blocking loads.
@inline(__always)
nonisolated func processAvailableMemoryMB() -> Double {
    #if !os(macOS)
    let bytes = os_proc_available_memory()
    if bytes == 0 { return .infinity }  // 0 = unsupported / over limit
    return Double(bytes) / (1024.0 * 1024.0)
    #else
    return .infinity
    #endif
}

/// Estimated MB the process needs available for a successful MLX load.
/// `sizeGB` comes from the catalog; unknown models default to 2.5 GB.
nonisolated func requiredMemoryMBForLoad(sizeGB: Double?) -> Double {
    let s = sizeGB ?? 2.5
    let effectiveResidentMB = s * 1024.0 * 0.75
    return effectiveResidentMB + 250.0
}

struct MemoryHeadroomResult {
    let success: Bool
    let finalAvailableMB: Double
    let pollsTaken: Int
    let elapsedSeconds: Double
}

/// Poll until available memory reaches `requiredMB + 100 MB`, or until
/// `timeoutSeconds` elapses. Used after unload-during-swap.
nonisolated func waitForMemoryHeadroom(
    requiredMB: Double,
    timeoutSeconds: Double = 3.0,
    intervalMillis: UInt64 = 150
) async -> MemoryHeadroomResult {
    let target = requiredMB + 100.0
    let intervalNs = intervalMillis * 1_000_000
    let start = Date()
    let deadline = start.addingTimeInterval(timeoutSeconds)
    var pollCount = 0
    while Date() < deadline {
        let available = processAvailableMemoryMB()
        pollCount += 1
        let elapsed = Date().timeIntervalSince(start)
        dbgLog("MLX-MEM: headroom poll #%d availableMB=%.0f targetMB=%.0f elapsed=%.2fs",
               pollCount, available, target, elapsed)
        if available >= target {
            return MemoryHeadroomResult(
                success: true,
                finalAvailableMB: available,
                pollsTaken: pollCount,
                elapsedSeconds: elapsed
            )
        }
        try? await Task.sleep(nanoseconds: intervalNs)
    }
    let final = processAvailableMemoryMB()
    return MemoryHeadroomResult(
        success: false,
        finalAvailableMB: final,
        pollsTaken: pollCount,
        elapsedSeconds: Date().timeIntervalSince(start)
    )
}

/// User-facing message when a load is refused for memory pressure.
nonisolated func memoryRefusalMessage(
    modelDisplayName: String,
    availableMB: Double,
    requiredMB: Double
) -> String {
    let availableGB = availableMB / 1024.0
    let requiredGB = requiredMB / 1024.0
    let availableStr: String = availableMB.isInfinite
        ? "an unknown amount"
        : String(format: "%.1f GB", availableGB)
    let requiredStr = String(format: "%.1f GB", requiredGB)
    return "Not enough memory to load \(modelDisplayName) right now. I need roughly \(requiredStr) but only have \(availableStr) available. Try closing other apps, switching back to a smaller model, or restarting Posey — sometimes iOS needs a moment to reclaim memory after a model swap."
}
