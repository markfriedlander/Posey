import Foundation
import UIKit

// ========== BLOCK 01: SUSPECT TOKEN DETECTOR - START ==========

/// Phase 2.2 Step 6 — Tier 3 fusion-repair detector.
///
/// Scans plainText for tokens that look like PDFKit fused two or more
/// words together. Returns a deduped, ordered set of suspect tokens
/// to send to AFM for split-or-keep classification.
///
/// **Shape filter** (necessary):
///   - All-caps run of ≥ 8 letters with no internal whitespace
///     (catches "ANETERNAL" → 9; "HOFSTADTER" → 10; "DIFFERENT" → 9
///     legitimately; AFM will keep those unchanged)
///   - Token of length ≥ 7 with at least one internal `[a-z][A-Z]`
///     boundary (catches camelCase fusion like "wordWord" /
///     "TitleWord"; PascalCase identifiers / brand names ("YouTube",
///     "iPhone") get sent to AFM too — it'll keep them)
///
/// **Precision filters** (drop tokens AFM doesn't need to see):
///   - `UITextChecker` says the lowercased form is a known word —
///     skip (it's already a single legitimate word)
///   - Token can't be split into 2+ known words via any single split
///     point — skip (no possible fusion, AFM wouldn't have anything
///     to do)
///
/// Per CLAUDE.md Rule 6 (local inference is free) we don't need to
/// minimize suspect-set size — we just need the set to be a
/// reasonable input. Generous shape filter + cheap dictionary filter
/// keeps the precision useful without aggressive guessing.
///
/// Returned tokens preserve original case so the swap-back uses
/// `\b<ORIGINAL>\b` exactly.
enum SuspectTokenDetector {

    /// Detect suspect fusion tokens in `plainText`. Returns up to
    /// `maxResults` unique tokens in first-occurrence order so the
    /// runner can process the most prominent fusion artifacts first.
    static func detect(in plainText: String, maxResults: Int = 1_000) -> [String] {
        guard !plainText.isEmpty else { return [] }
        let checker = UITextChecker()

        // Whitespace-tokenize. Don't punctuation-split — fusion
        // tokens often carry trailing punctuation we want to ignore
        // separately via word boundaries.
        let raw = plainText.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        var seen = Set<String>()
        var suspects: [String] = []

        for rawToken in raw {
            // Strip surrounding punctuation. "HOFSTADTER," → "HOFSTADTER".
            let token = rawToken.trimmingCharacters(in: .punctuationCharacters)
            if token.isEmpty { continue }
            if seen.contains(token) { continue }

            if !shapeLooksFused(token) { continue }

            let lower = token.lowercased()
            if isKnownWord(lower, checker: checker) { continue }
            if !canSplitIntoKnownWords(lower, checker: checker) { continue }

            seen.insert(token)
            suspects.append(token)
            if suspects.count >= maxResults { break }
        }
        return suspects
    }

    /// Shape filter — first gate. Cheap. Runs on every token.
    fileprivate static func shapeLooksFused(_ token: String) -> Bool {
        // All-caps fusion shape.
        if token.count >= 8 {
            var letterCount = 0
            var allUppercase = true
            for ch in token where ch.isLetter {
                letterCount += 1
                if !ch.isUppercase { allUppercase = false; break }
            }
            if letterCount >= 8 && allUppercase {
                return true
            }
        }
        // CamelCase / PascalCase fusion shape.
        if token.count >= 7 {
            var prev: Character? = nil
            for ch in token {
                if let p = prev, p.isLetter, ch.isLetter, p.isLowercase, ch.isUppercase {
                    return true
                }
                prev = ch
            }
        }
        return false
    }

    /// True iff `UITextChecker` recognizes `lowercased` as a single
    /// English word OR as a known proper noun. Catches "HOFSTADTER"
    /// (proper name in Apple's dictionary), "DIFFERENT" (word), etc.
    fileprivate static func isKnownWord(_ lowercased: String, checker: UITextChecker) -> Bool {
        let ns = lowercased as NSString
        let range = checker.rangeOfMisspelledWord(
            in: lowercased,
            range: NSRange(location: 0, length: ns.length),
            startingAt: 0,
            wrap: false,
            language: "en"
        )
        return range.location == NSNotFound
    }

    /// Greedy bipartite split — does there exist any split point such
    /// that both halves are known words? Catches "ANETERNAL" → "AN" +
    /// "ETERNAL". Skips tokens that can't be split into 2+ valid words.
    /// Tokens with > 2 fused words (rare) still pass because most can
    /// be split bipartitely with at least one valid bisection.
    fileprivate static func canSplitIntoKnownWords(_ lowercased: String, checker: UITextChecker) -> Bool {
        let chars = Array(lowercased)
        if chars.count < 4 { return false }
        for i in 2..<(chars.count - 1) {
            let left = String(chars[0..<i])
            let right = String(chars[i..<chars.count])
            if isKnownWord(left, checker: checker), isKnownWord(right, checker: checker) {
                return true
            }
        }
        return false
    }
}

// ========== BLOCK 01: SUSPECT TOKEN DETECTOR - END ==========
