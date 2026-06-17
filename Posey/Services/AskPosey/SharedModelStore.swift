import Foundation

// ========== BLOCK 01: SHARED MODEL STORE - PATHS - START ==========

/// The on-device store for Ask Posey's downloadable AI models (the MLX answer
/// LLMs and the Nomic embedder asset). Lives in the **App Group container**
/// `group.com.MarkFriedlander.aifamily` so that (a) iOS cannot silently purge
/// multi-GB models the way it can purge `Library/Caches`, and (b) the Posey
/// app family (Posey + Hal) can share a single copy instead of each app keeping
/// its own.
///
/// **App-family contract (built here in Posey; Hal adopts it in a later
/// update).** Both apps point at the same container + the same on-disk layout
/// and coordinate ownership through `manifest.json` (see BLOCK 03). Until Hal
/// adopts it, Posey is the sole participant — the refcount is trivial, but the
/// protocol is already in place so sharing "just works" when Hal lands, with no
/// further migration on Posey's side.
///
/// 2026-06-16 — introduced as P3 of the Ask Posey V1 release plan
/// (`docs-internal/ASK_POSEY_STORAGE_IMPL.md`).
enum SharedModelStore {

    /// The shared App Group identifier. Must match Hal's exactly.
    static let appGroupID = "group.com.MarkFriedlander.aifamily"

    /// This app's stable identity for ownership claims in the manifest.
    static var thisAppID: String { Bundle.main.bundleIdentifier ?? "com.MarkFriedlander.Posey" }

    /// Container root for shared models, under a `Models/` subfolder so other
    /// shared state can coexist later. **Fallback:** if the container is
    /// unavailable (entitlement missing, a Simulator without the group, a
    /// misconfigured build) we degrade to per-app Caches rather than crash —
    /// Ask Posey keeps working, just without cross-app sharing or purge
    /// protection.
    static var root: URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("Models", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// The HuggingFace-style cache root inside the store. Both the MLX models
    /// (`huggingface/models/<id>`) and the Nomic asset (passed as `downloadBase`
    /// to `swift-embeddings`) live under here.
    static var huggingFaceRoot: URL {
        root.appendingPathComponent("huggingface", isDirectory: true)
    }

    /// Directory for one MLX model id. Matches the legacy Caches layout
    /// (`huggingface/models/<modelID>`) so detection/load/delete are unchanged
    /// apart from the root.
    static func mlxModelDir(_ modelID: String) -> URL {
        huggingFaceRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }
}
// ========== BLOCK 01: SHARED MODEL STORE - PATHS - END ==========

// ========== BLOCK 03: REFCOUNT MANIFEST (app-family co-ownership) - START ==========

extension SharedModelStore {

    /// `manifest.json` at the store root tracks which apps in the family claim
    /// each model, so deleting from one app only removes the files when **no**
    /// app still claims them. All access is wrapped in `NSFileCoordinator` so
    /// Posey and Hal can read/write concurrently without corruption.
    private static var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    private struct Manifest: Codable {
        var version: Int = 1
        var models: [String: Entry] = [:]
        struct Entry: Codable {
            var claimedBy: [String] = []   // bundle ids
            var repo: String?              // hf repo id (identity: repo@rev#quant — recorded for cross-app match)
            var sizeBytes: Int64?
        }
    }

    /// Record that THIS app uses `modelID` (called on a completed download).
    static func claim(modelID: String, repo: String?, sizeBytes: Int64?) {
        mutateManifest { m in
            var e = m.models[modelID] ?? Manifest.Entry()
            if !e.claimedBy.contains(thisAppID) { e.claimedBy.append(thisAppID) }
            if let repo { e.repo = repo }
            if let sizeBytes { e.sizeBytes = sizeBytes }
            m.models[modelID] = e
        }
    }

    /// Release THIS app's claim on `modelID`. Returns `true` iff NO app claims
    /// it anymore — i.e. it is now safe to delete the files from disk. The
    /// caller (`deleteModel`) removes the files only on `true`.
    @discardableResult
    static func releaseClaim(modelID: String) -> Bool {
        var safeToDelete = false
        mutateManifest { m in
            guard var e = m.models[modelID] else { safeToDelete = true; return }
            e.claimedBy.removeAll { $0 == thisAppID }
            if e.claimedBy.isEmpty {
                m.models.removeValue(forKey: modelID)
                safeToDelete = true
            } else {
                m.models[modelID] = e
            }
        }
        return safeToDelete
    }

    // MARK: coordinated read / write

    private static func readManifest(_ coordinator: NSFileCoordinator) -> Manifest {
        var result = Manifest()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: manifestURL, options: [], error: &coordError) { url in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
            result = decoded
        }
        return result
    }

    private static func mutateManifest(_ body: (inout Manifest) -> Void) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator()
        // Read-then-write under a single write coordination so two apps can't
        // interleave a lost update.
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: manifestURL, options: [], error: &coordError) { url in
            var manifest = Manifest()
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(Manifest.self, from: data) {
                manifest = decoded
            }
            body(&manifest)
            if let out = try? JSONEncoder().encode(manifest) {
                try? out.write(to: url, options: .atomic)
            }
        }
    }
}
// ========== BLOCK 03: REFCOUNT MANIFEST - END ==========
