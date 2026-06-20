import Foundation
import CoreML
@preconcurrency import Embeddings

// ========== BLOCK 01: EMBEDDER LOAD-TEST GATE - START ==========

/// 2026-06-19 (Mark) — embedder model-load GATE. A contained on-device load
/// test for a candidate embedding model BEFORE committing to a full
/// `EmbeddingBackend` integration (Rule 9 — prove the primitive first).
///
/// **Why this exists / what it de-risks (mxbai):** the obvious route — the
/// pre-converted `nbpe97/mxbai-embed-large-v1-CoreML` package — has a known bug
/// (outputs **NaN** when built for the iOS 18+ Core ML target; our device is
/// iOS 26) and ships no tokenizer. The better route is the SAME path Nomic
/// already uses: `swift-embeddings`' `Bert.loadModelBundle`, loading
/// `mixedbread-ai/mxbai-embed-large-v1` (a sentence-transformers BERT-large)
/// straight from HuggingFace with the tokenizer handled automatically.
/// `Bert.encode` returns `sequenceOutput[:,0,:]` — the CLS token — which is
/// exactly mxbai's recommended pooling, so this is nearly mechanical IF the
/// weights load. The one real unknown is whether mxbai's safetensors keys map
/// onto swift-embeddings' `Bert.Model` (sentence-transformers vs Google-BERT key
/// naming). This gate answers that empirically: downloads, weights load, and
/// `encode` yields a finite, L2-normalizable 1024-dim vector — or it reports the
/// exact failure. Reusable for any future BERT-family embedder.
///
/// Driven headlessly via the antenna (`EMBEDDER_LOADTEST` / `..._STATUS`).
enum EmbedderLoadTest {

    struct Report: Sendable {
        var state: String          // idle | loading | encoding | ok | error
        var repo: String
        var dim: Int?
        var allFinite: Bool?
        var l2Norm: Double?
        var sample: [Double]?      // first few values, for a sanity eyeball
        var loadMs: Int?
        var encodeMs: Int?
        var error: String?
    }

    @MainActor private(set) static var report = Report(state: "idle", repo: "")
    @MainActor private static func set(_ r: Report) { report = r }
    @MainActor static var isRunning: Bool { report.state == "loading" || report.state == "encoding" }

    /// Kick the load test for `repo` (off-main; returns immediately). Poll
    /// `report` via the status verb. Routes the heavy load+encode through the
    /// app-wide serial lane so it never overlaps other heavy work.
    static func run(repo: String) {
        Task.detached(priority: .utility) {
            await set(Report(state: "loading", repo: repo))
            let t0 = Date()
            do {
                let bundle = try await HeavyWorkLane.shared.run(label: "embedder-loadtest") {
                    try await Bert.loadModelBundle(
                        from: repo, downloadBase: SharedModelStore.huggingFaceRoot)
                }
                let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
                await set(Report(state: "encoding", repo: repo, loadMs: loadMs))

                let t1 = Date()
                let scalars: [Double] = try await HeavyWorkLane.shared.run(label: "embedder-loadtest-encode") {
                    let encoded = try bundle.encode(
                        "The quick brown fox jumps over the lazy dog.", maxLength: 512)
                    let shaped = await encoded.cast(to: Float.self).shapedArray(of: Float.self)
                    return shaped.scalars.map { Double($0) }
                }
                let encodeMs = Int(Date().timeIntervalSince(t1) * 1000)

                let allFinite = scalars.allSatisfy { $0.isFinite }
                let norm = scalars.contains(where: { !$0.isFinite })
                    ? Double.nan
                    : sqrt(scalars.reduce(0) { $0 + $1 * $1 })
                await set(Report(
                    state: "ok", repo: repo, dim: scalars.count,
                    allFinite: allFinite, l2Norm: norm,
                    sample: Array(scalars.prefix(5)),
                    loadMs: loadMs, encodeMs: encodeMs))
            } catch {
                await set(Report(
                    state: "error", repo: repo,
                    loadMs: Int(Date().timeIntervalSince(t0) * 1000),
                    error: error.localizedDescription))
            }
        }
    }
}

// ========== BLOCK 01: EMBEDDER LOAD-TEST GATE - END ==========
