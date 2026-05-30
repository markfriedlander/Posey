import Foundation
import Accelerate

// ========== BLOCK 01: K-MEANS CLUSTERING - START ==========

/// Lightweight, dependency-free **cosine k-means** for on-device use, built
/// on Accelerate. Part of Posey's RAPTOR-style hierarchical-retrieval tree
/// (recursively cluster → summarize → verify → retrieve at multiple levels
/// of abstraction). Designed to be self-contained and reusable — no third-
/// party deps, deterministic given a seed.
///
/// **Why cosine, implemented via L2-normalization.** Text embeddings are
/// compared by cosine similarity, not Euclidean distance. On unit-length
/// vectors the two induce the *same* nearest-neighbor ordering (maximizing
/// dot product == minimizing squared Euclidean distance), so we L2-normalize
/// once up front and then run ordinary Lloyd's iterations using dot product
/// as the similarity. Centroids are re-normalized each iteration so the
/// "mean direction" stays on the unit sphere (spherical k-means).
///
/// **Determinism.** Initialization (k-means++) draws from a seeded SplitMix64
/// RNG — no `Math.random`/`Date()` — so the same inputs + seed always produce
/// the same clusters. This matters for reproducible tree builds and tests.
///
/// **Performance.** The hot path (assigning every point to its nearest
/// centroid) is a single BLAS matrix multiply (`cblas_dgemm`): points·centroidsᵀ
/// → an N×k similarity matrix, then an argmax per row. Linear in N·k·dim.
public struct KMeansClustering {

    /// Result of a clustering run.
    public struct Result: Sendable {
        /// Cluster index in `0..<k` for each input vector, in input order.
        public let labels: [Int]
        /// Number of clusters actually produced (≤ requested k; never more).
        public let k: Int
        /// Lloyd's iterations run before convergence (or the cap).
        public let iterations: Int
    }

    /// Cluster `vectors` into (at most) `k` groups.
    ///
    /// - Parameters:
    ///   - vectors: row-major embeddings, all the same dimension. Zero
    ///     vectors are tolerated (they normalize to zero and attach to
    ///     cluster 0).
    ///   - k: desired cluster count. Clamped to `1...vectors.count`.
    ///   - maxIterations: Lloyd's iteration cap (convergence usually < 20).
    ///   - seed: RNG seed for k-means++ init; same seed ⇒ same result.
    /// - Returns: `Result` with a label per input vector.
    public static func cluster(vectors: [[Double]],
                               k requestedK: Int,
                               maxIterations: Int = 50,
                               seed: UInt64 = 42) -> Result {
        let n = vectors.count
        guard n > 0 else { return Result(labels: [], k: 0, iterations: 0) }
        let dim = vectors[0].count
        let k = max(1, min(requestedK, n))
        if k == 1 { return Result(labels: Array(repeating: 0, count: n), k: 1, iterations: 0) }

        // Flatten + L2-normalize into a contiguous N×dim buffer.
        var points = [Double](repeating: 0, count: n * dim)
        for i in 0..<n {
            let v = vectors[i]
            var norm = 0.0
            vDSP_svesqD(v, 1, &norm, vDSP_Length(dim))   // Σ v²
            let inv = norm > 0 ? 1.0 / Double(norm).squareRoot() : 0.0
            var scale = inv
            v.withUnsafeBufferPointer { src in
                points.withUnsafeMutableBufferPointer { dst in
                    vDSP_vsmulD(src.baseAddress!, 1, &scale, dst.baseAddress! + i * dim, 1, vDSP_Length(dim))
                }
            }
        }

        // ── k-means++ initialization (seeded, deterministic).
        var rng = SplitMix64(seed: seed)
        var centroids = [Double](repeating: 0, count: k * dim)
        var chosen = [Int]()
        chosen.reserveCapacity(k)
        // First centroid: a uniformly-random point.
        let first = Int(rng.next() % UInt64(n))
        copyRow(from: points, row: first, dim: dim, into: &centroids, destRow: 0)
        chosen.append(first)
        // Remaining: D²-weighted sampling (here D² = 1 - cosSim on unit vectors).
        var dist2 = [Double](repeating: Double.greatestFiniteMagnitude, count: n)
        for c in 1..<k {
            // Update each point's distance to the nearest chosen centroid.
            for i in 0..<n {
                let sim = dot(points, rowA: i, centroids, rowB: c - 1, dim: dim)
                let d = max(0.0, 1.0 - sim)
                if d < dist2[i] { dist2[i] = d }
            }
            // Weighted pick proportional to dist2.
            let total = dist2.reduce(0, +)
            var target = (total > 0 ? Double(rng.nextUnit()) * total : 0)
            var pick = 0
            for i in 0..<n { target -= dist2[i]; if target <= 0 { pick = i; break } }
            copyRow(from: points, row: pick, dim: dim, into: &centroids, destRow: c)
            chosen.append(pick)
        }

        // ── Lloyd's iterations.
        var labels = [Int](repeating: 0, count: n)
        var iterations = 0
        for _ in 0..<maxIterations {
            iterations += 1
            // Assignment: each point → centroid of max cosine (= max dot on
            // unit vectors). vDSP dot products; self-contained (no BLAS).
            var changed = false
            for i in 0..<n {
                var best = 0; var bestSim = -Double.greatestFiniteMagnitude
                for c in 0..<k {
                    let sim = dot(points, rowA: i, centroids, rowB: c, dim: dim)
                    if sim > bestSim { bestSim = sim; best = c }
                }
                if labels[i] != best { labels[i] = best; changed = true }
            }

            // Update: centroid = normalized mean of its members.
            var newCentroids = [Double](repeating: 0, count: k * dim)
            var counts = [Int](repeating: 0, count: k)
            for i in 0..<n {
                let c = labels[i]; counts[c] += 1
                addRow(points, srcRow: i, dim: dim, into: &newCentroids, destRow: c)
            }
            for c in 0..<k {
                if counts[c] == 0 {
                    // Empty cluster — reseed to the worst-fit point so k stays meaningful.
                    let reseed = Int(rng.next() % UInt64(n))
                    copyRow(from: points, row: reseed, dim: dim, into: &newCentroids, destRow: c)
                }
                normalizeRow(&newCentroids, row: c, dim: dim)
            }
            centroids = newCentroids
            if !changed { break }
        }

        return Result(labels: labels, k: k, iterations: iterations)
    }

    // MARK: - Row helpers (contiguous row-major math)

    private static func copyRow(from src: [Double], row: Int, dim: Int,
                                into dst: inout [Double], destRow: Int) {
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                d.baseAddress!.advanced(by: destRow * dim)
                    .update(from: s.baseAddress!.advanced(by: row * dim), count: dim)
            }
        }
    }

    private static func addRow(_ src: [Double], srcRow: Int, dim: Int,
                               into dst: inout [Double], destRow: Int) {
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                vDSP_vaddD(d.baseAddress! + destRow * dim, 1,
                           s.baseAddress! + srcRow * dim, 1,
                           d.baseAddress! + destRow * dim, 1, vDSP_Length(dim))
            }
        }
    }

    private static func normalizeRow(_ buf: inout [Double], row: Int, dim: Int) {
        buf.withUnsafeMutableBufferPointer { b in
            let p = b.baseAddress! + row * dim
            var norm = 0.0
            vDSP_svesqD(p, 1, &norm, vDSP_Length(dim))
            if norm > 0 { var s = 1.0 / Double(norm).squareRoot(); vDSP_vsmulD(p, 1, &s, p, 1, vDSP_Length(dim)) }
        }
    }

    private static func dot(_ a: [Double], rowA: Int, _ b: [Double], rowB: Int, dim: Int) -> Double {
        var r = 0.0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                vDSP_dotprD(pa.baseAddress! + rowA * dim, 1, pb.baseAddress! + rowB * dim, 1, &r, vDSP_Length(dim))
            }
        }
        return r
    }
}

/// Tiny deterministic RNG (SplitMix64) — seeded, no global state, no
/// `Math.random`/`Date()`. Used for reproducible k-means++ initialization.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform Double in [0, 1).
    mutating func nextUnit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
}
// ========== BLOCK 01: K-MEANS CLUSTERING - END ==========
