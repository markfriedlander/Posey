import Foundation
import CryptoKit

// ========== BLOCK 01: CONTENT HASHER - START ==========

/// **Bundle 2b (2026-05-26)** — content-hash helpers for duplicate
/// detection. Hashing the raw source-file bytes is the only reliable
/// way to detect re-imports across the enhancement pipeline; the
/// post-enhancement plainText drifts as Tier 2 Vision and Tier 3
/// AFM rewrite units, so character-count or plainText comparison
/// would generate spurious duplicates after enhancement runs.
enum ContentHasher {

    /// SHA-256 of raw bytes, lowercase hex.
    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of file bytes at `url`, lowercase hex. Throws if the
    /// file can't be read; the caller should fall back gracefully
    /// (treat as no hash).
    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256(data)
    }
}

// ========== BLOCK 01: CONTENT HASHER - END ==========
