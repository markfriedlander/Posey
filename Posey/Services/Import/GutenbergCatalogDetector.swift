import Foundation

// ========== BLOCK 01: GUTENBERG CATALOG DETECTOR - START ==========

/// Detects Gutenberg's "multi-edition catalog page" that some
/// distributions place between the `*** START OF THE PROJECT
/// GUTENBERG EBOOK ***` marker and the actual book content.
///
/// Canonical example (illustrated Alice, Gutenberg #19033):
///
///     *** START OF THE PROJECT GUTENBERG EBOOK ALICE'S ADVENTURES IN WONDERLAND ***
///
///     There are several editions of this ebook in the Project Gutenberg collection.
///     Various characteristics of each ebook are listed to aid in selecting the
///     preferred file.
///     Click on any of the filenumbers below to quickly view each ebook.
///
///      19002
///     (Black and White illustrations)
///      19033
///     (Illustrations in Color and Black and White)
///      28885
///     (Illustrations in Color)
///     ...
///
///     [actual book begins here]
///
/// Without skipping this catalog, the reader opens (and TTS reads) the
/// catalog content before reaching the book proper. The Gutenberg
/// boundary detector lands at the `*** START ***` marker, but the
/// catalog page is real prose so the existing in-prose TOC detector
/// (which looks for "Contents" headers) doesn't help.
///
/// This detector:
///   1. Looks for the catalog anchor phrase
///      ("There are several editions" or "Click on any of the
///      filenumbers below") within the first ~3000 chars after the
///      current skip.
///   2. Walks forward past any sequence of numeric-only short lines
///      and parenthetical descriptors ("(Black and White illustrations)").
///   3. Lands at the first substantial prose line that follows —
///      typically the book title block or chapter I heading.
///
/// Returns nil when no catalog page is present, so the caller can
/// leave the skip where it is.
///
/// Added 2026-05-22 after the illustrated Alice (#19033) surfaced
/// this shape during phone verification.
enum GutenbergCatalogDetector {

    /// Search the plainText for a catalog page starting after `currentSkip`.
    /// Returns the offset of the first byte past the catalog, or nil
    /// when no catalog is present.
    static func endOfCatalogRegion(in plainText: String, after currentSkip: Int) -> Int? {
        // Cap the search window. A Gutenberg catalog page is at most
        // ~3 KB; searching deeper risks matching content prose.
        let textCount = plainText.count
        guard currentSkip < textCount else { return nil }
        let searchEnd = min(textCount, currentSkip + 3000)
        guard let startIdx = plainText.index(
            plainText.startIndex, offsetBy: currentSkip,
            limitedBy: plainText.endIndex
        ) else { return nil }
        guard let endIdx = plainText.index(
            plainText.startIndex, offsetBy: searchEnd,
            limitedBy: plainText.endIndex
        ) else { return nil }
        let slice = String(plainText[startIdx..<endIdx])

        // Anchor phrases — both forms observed in Gutenberg
        // multi-edition distributions.
        let anchors = [
            "There are several editions of this ebook",
            "Click on any of the filenumbers below"
        ]
        guard anchors.contains(where: { slice.range(of: $0, options: .caseInsensitive) != nil }) else {
            return nil
        }

        // Split the slice into lines, then walk past the catalog
        // listing (numeric-only short lines + parenthetical
        // descriptors + blank lines). Stop at the first substantial
        // prose line.
        let lines = slice.components(separatedBy: "\n")
        var cumulativeLen = currentSkip
        var anchorPassed = false
        var lastCatalogLineEnd = currentSkip

        for line in lines {
            let lineLen = line.count + 1 // +1 for the \n we split on
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            cumulativeLen += lineLen

            // Once we've seen the anchor line, the catalog has begun.
            if !anchorPassed {
                if anchors.contains(where: { trimmed.range(of: $0, options: .caseInsensitive) != nil }) {
                    anchorPassed = true
                    lastCatalogLineEnd = cumulativeLen
                }
                continue
            }

            // Inside the catalog: accept blank, numeric-only, or
            // parenthetical-descriptor lines. Anything else means
            // we've reached real content.
            if trimmed.isEmpty {
                lastCatalogLineEnd = cumulativeLen
                continue
            }
            if isNumericOnly(trimmed) {
                lastCatalogLineEnd = cumulativeLen
                continue
            }
            if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
                lastCatalogLineEnd = cumulativeLen
                continue
            }
            // Continue to accept catalog-anchor prose lines (the
            // "There are several editions" / "Click on any of the
            // filenumbers" sentences themselves may span multiple
            // lines in some distributions).
            if trimmed.range(of: "ebook", options: .caseInsensitive) != nil
                || trimmed.range(of: "filenumber", options: .caseInsensitive) != nil
                || trimmed.range(of: "characteristics", options: .caseInsensitive) != nil
                || trimmed.range(of: "preferred file", options: .caseInsensitive) != nil {
                lastCatalogLineEnd = cumulativeLen
                continue
            }

            // First substantial non-catalog line. Stop here.
            break
        }

        // No anchor found → no skip.
        guard anchorPassed else { return nil }
        // Cap at plainText length so the caller doesn't trip a bounds
        // check downstream.
        return min(lastCatalogLineEnd, textCount)
    }

    private static func isNumericOnly(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }
}

// ========== BLOCK 01: GUTENBERG CATALOG DETECTOR - END ==========
