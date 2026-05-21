import Foundation

// ========== BLOCK 01: IN-PROSE TOC DETECTOR - START ==========

/// Detects an inline Table-of-Contents region in a document's `plainText`
/// and returns the offset at which the body content begins (i.e., past
/// the TOC). Format-agnostic — operates on the post-extraction string,
/// so the same pass works for EPUB, HTML, TXT, and any other format
/// whose source carries a Contents listing as readable prose.
///
/// ### Why this is a generic detector, not an EPUB-only fix
///
/// Multiple Gutenberg edition styles emit a "Contents" heading followed
/// by a list of chapter titles, and the markup varies:
///
/// - Millennium Fulcrum Alice uses an HTML `<table>` for its TOC
/// - Hugh Thomson Pride and Prejudice has no in-prose TOC (its nav is
///   structural-only via `nav.xhtml`)
/// - Plain Moby Dick `.txt` has a flat "CONTENTS" listing followed by
///   ETYMOLOGY / EXTRACTS / CHAPTER 1 / CHAPTER 2 / ... lines
/// - Frankenstein's EPUB has a "CONTENTS" listing as text
///
/// The EPUB importer already strips `<p class="toc">`, `<div class="toc">`,
/// and `<nav>` style TOCs at the HTML layer (`stripEmbeddedTOC` in
/// `EPUBDocumentImporter`). What slips through is the everything-else
/// case — `<table>`, plain `<p>` with no class, raw TXT — which lands in
/// plainText as readable prose and then gets spoken aloud as "Chapter
/// One. Down the Rabbit-Hole. Chapter Two. The Pool of Tears…"
///
/// This detector is the catch-all: any in-prose TOC, in any format, is
/// recognized by a single shape and skipped past.
///
/// ### The detection heuristic
///
/// 1. Look for a "Contents" or "Table of Contents" header in plainText,
///    starting at the supplied `after` offset (typically the Gutenberg
///    contentStart). The header is a line containing only that text
///    (case-insensitive, trimmed).
/// 2. The first non-blank line after the header is the TOC's first
///    entry — call this the "anchor entry."
/// 3. Find the SECOND occurrence of the anchor entry in plainText
///    (the first occurrence is the entry inside the TOC; the second is
///    where the body section by that name begins).
/// 4. If found, return the offset of the second occurrence — that's
///    where the body actually starts.
///
/// Examples (verified against the audit corpus):
///
/// - **Alice (EPUB, Millennium Fulcrum)**: Contents → first entry
///   "CHAPTER I." → second occurrence at body's chapter heading.
///   Reader opens at "CHAPTER I. / Down the Rabbit-Hole" body.
/// - **Moby Dick (any format)**: CONTENTS → first entry "ETYMOLOGY." →
///   second occurrence at the Etymology body section (which is real
///   content per Mark's 2026-05-21 direction). Reader opens at
///   "ETYMOLOGY. (Supplied by a Late Consumptive Usher…)" — Mark's
///   chosen content boundary.
/// - **Pride and Prejudice (Hugh Thomson)**: no in-prose Contents
///   header in plainText (nav-only). Detector returns nil; reader
///   opens at the Saintsbury Preface as Mark wants.
///
/// ### False positive defenses
///
/// - Anchor entry must be at least 4 characters long. Filters out
///   stray "I." / "1." / "A" lines that aren't really TOC entries.
/// - The second occurrence must be more than 50 characters past the
///   first. Prevents catastrophic over-skip on docs where the anchor
///   entry happens to appear immediately again (e.g., a doc that
///   structurally repeats a section name back-to-back).
/// - If no second occurrence is found, returns nil — leaves the
///   skip offset alone rather than risking a guess.
enum InProseTOCDetector {

    /// Find the offset at which the in-prose TOC region ends in
    /// `plainText`, starting the search from `after` (typically the
    /// Gutenberg-detector contentStart, or 0 if no Gutenberg signal).
    ///
    /// Returns nil if no TOC region is detected.
    static func endOfTOCRegion(in plainText: String, after: Int) -> Int? {
        guard after >= 0, after < plainText.count else { return nil }
        let searchStart = plainText.index(plainText.startIndex, offsetBy: after)
        let searchSlice = plainText[searchStart..<plainText.endIndex]

        // Step 1 — find a Contents header. The regex matches a line
        // (anchored to a line boundary in MULTI-LINE mode) consisting
        // ONLY of "Contents" or "Table of Contents" (case-insensitive,
        // optionally with trailing whitespace and a colon/period).
        let headerPattern = #"(?im)^\s*(?:contents|table\s+of\s+contents)[:.]?\s*$"#
        guard let headerRegex = try? NSRegularExpression(pattern: headerPattern),
              let headerMatch = headerRegex.firstMatch(
                in: String(searchSlice),
                options: [],
                range: NSRange(location: 0, length: (searchSlice as NSString).length)
              ),
              let headerRange = Range(headerMatch.range, in: searchSlice) else {
            return nil
        }

        // Position after the Contents header.
        let postHeaderIndex = headerRange.upperBound

        // Step 2 — find a USABLE anchor entry. Walk lines after the
        // Contents header; skip blank lines AND short numeral-only
        // lines (like "I." or "1." — common as TOC numeral prefixes
        // separated from the section title onto their own line). The
        // first line of sufficient length and content shape becomes
        // the anchor.
        //
        // Sherlock's TOC opens with `Contents\n\nI.\nA Scandal in
        // Bohemia\nII.\nThe Red-Headed League\n…` — the bare "I." is
        // a roman-numeral prefix, not a real anchor. "A Scandal in
        // Bohemia" is.
        //
        // Cap the walk at 8 short-line skips so we don't go arbitrarily
        // deep into the document if we wander past a malformed TOC.
        let afterHeader = String(searchSlice[postHeaderIndex..<searchSlice.endIndex])
        let lines = afterHeader.split(separator: "\n", maxSplits: 50, omittingEmptySubsequences: false)
        var anchorEntry: String? = nil
        var shortLineSkips = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.count < 4 || isNumeralOnly(trimmed) {
                shortLineSkips += 1
                if shortLineSkips > 8 { break }
                continue
            }
            anchorEntry = trimmed
            break
        }

        guard let entry = anchorEntry else { return nil }

        // Step 3 — find the SECOND occurrence of the anchor entry in
        // plainText, case-insensitively. The TOC may list "A Scandal
        // in Bohemia" while the body opens with "A SCANDAL IN BOHEMIA"
        // (Sherlock); case-insensitive comparison covers both.
        //
        // Search the whole plainText (not just the slice) so the offset
        // we return is plainText-relative.
        guard let firstOccurrence = plainText.range(of: entry, options: .caseInsensitive, range: searchStart..<plainText.endIndex) else {
            return nil
        }
        let secondSearchStart = firstOccurrence.upperBound
        guard secondSearchStart < plainText.endIndex,
              let secondOccurrence = plainText.range(of: entry, options: .caseInsensitive, range: secondSearchStart..<plainText.endIndex) else {
            return nil
        }

        let firstOffset = plainText.distance(from: plainText.startIndex, to: firstOccurrence.lowerBound)
        let secondOffset = plainText.distance(from: plainText.startIndex, to: secondOccurrence.lowerBound)

        // Step 4 — sanity check: the second occurrence must be more
        // than 50 chars past the first. Defensive against degenerate
        // cases where the anchor entry appears twice immediately (a
        // doc that legitimately repeats a heading would have at least
        // a paragraph between repetitions).
        guard secondOffset - firstOffset > 50 else { return nil }

        return secondOffset
    }

    /// True when `s` consists only of digits, roman numerals (I/V/X/L/C/D/M),
    /// optional period, and whitespace. Used to skip TOC numeral prefixes
    /// that appear on their own line in some Gutenberg editions.
    private static func isNumeralOnly(_ s: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789IVXLCDMivxlcdm. \t")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// ========== BLOCK 01: IN-PROSE TOC DETECTOR - END ==========
