import Foundation

// ========== BLOCK 01: FIRST CHAPTER ADVANCE - START ==========

/// **2026-05-27** — After Gutenberg legal preamble + CONTENTS catalog
/// have been skipped, a book like Moby Dick still has substantial
/// in-work front matter (ETYMOLOGY, EXTRACTS) before Chapter 1's
/// "Call me Ishmael." A reader opening the book wants to start at the
/// novel, not at the etymology curiosity.
///
/// This detector scans forward from a given offset for the first
/// chapter-style heading and returns that offset if found within a
/// reasonable distance. The caller is expected to use it as a refinement
/// on the smart-skip target: if a chapter heading is found, prefer it;
/// otherwise leave the smart-skip offset unchanged.
///
/// Pattern matched (line-anchored, case-insensitive on the word
/// "chapter" only — the number must be ASCII digits or upper-case
/// Roman numerals):
///
/// - `CHAPTER 1.` / `Chapter 1.` / `CHAPTER 1` / `Chapter 1`
/// - `CHAPTER I.` / `Chapter I.` / `CHAPTER I` (Roman through XL)
/// - `CHAPTER ONE.` (spelled-out — first ten)
///
/// Not matched (intentionally narrow — false positives are worse than
/// missing matches; the latter just keeps the prior offset):
/// - `chapter 1` lowercase mid-line (likely a sentence reference)
/// - `CHAPTER` without a following enumerator
/// - Generic `1.` standalone (could be a list item)
///
/// Returns: offset (in plainText) of the start of the matched chapter
/// heading, or `nil` if no chapter heading is found within
/// `maxDistance` characters of `startOffset`.
enum FirstChapterAdvance {

    /// Scan plainText forward from startOffset, looking for the first
    /// chapter-style heading line. Returns that offset on hit, nil
    /// otherwise.
    ///
    /// `maxDistance` bounds the search — if a chapter heading is more
    /// than this many characters past the start, we treat the document
    /// as "doesn't have chapter-numbered structure" and don't advance.
    /// 80,000 chars is generous: Moby Dick's Etymology + Extracts run
    /// ~22,000 chars; Frankenstein's Letters I-IV run ~16,000 chars.
    static func detect(in plainText: String, after startOffset: Int, maxDistance: Int = 80_000) -> Int? {
        guard !plainText.isEmpty else { return nil }
        let totalCount = plainText.count
        guard startOffset >= 0, startOffset <= totalCount else { return nil }
        let upperBound = min(totalCount, startOffset + maxDistance)

        // 2026-05-28 — Don't advance if `startOffset` is already just
        // past a recent CHAPTER heading. Caught on phone: Alice EPUB.
        // The TOC walker correctly landed at "Alice was beginning…"
        // (Ch I body, offset ~1483). Without this guard, the forward
        // scan from 1483 skipped past Ch I (already consumed) and
        // matched "CHAPTER II.\n" at 12626 — landing the reader at
        // "Curiouser and curiouser!" (Ch II opening) instead of Ch I.
        //
        // Lookback window of 400 chars covers the typical case where
        // the walker landed at a paragraph 50–200 chars past the
        // chapter heading. Same patterns as the forward scan; just
        // checking if a chapter heading exists in the immediate
        // upstream context.
        let lookbackStart = max(0, startOffset - 400)
        let lookbackStartIdx = plainText.index(plainText.startIndex, offsetBy: lookbackStart)
        let lookbackEndIdx = plainText.index(plainText.startIndex, offsetBy: startOffset)
        let lookback = plainText[lookbackStartIdx..<lookbackEndIdx]
        let lookbackPatterns: [String] = [
            #"(?im)^\s*CHAPTER\s+\d{1,3}[.\s:—-]"#,
            #"(?im)^\s*CHAPTER\s+[IVXL]{1,5}[.\s:—-]"#,
            #"(?im)^\s*CHAPTER\s+(ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN)[.\s:—-]"#,
            // Letter/Book/Part headings — same self-guard for the
            // EPUB importer's broader use of FirstChapterAdvance.
            #"(?im)^\s*LETTER\s+[IVXL]{1,5}[.\s:—-]"#,
            #"(?im)^\s*(BOOK|PART|VOLUME)\s+[IVXL]{1,5}[.\s:—-]"#,
        ]
        for pattern in lookbackPatterns {
            if lookback.range(of: pattern, options: .regularExpression) != nil {
                // We're already inside a chapter body — don't advance.
                return nil
            }
        }

        // Slice the search region as a substring; do the regex against it.
        let startIdx = plainText.index(plainText.startIndex, offsetBy: startOffset)
        let endIdx = plainText.index(plainText.startIndex, offsetBy: upperBound)
        let region = plainText[startIdx..<endIdx]

        // Patterns. Each is line-anchored (^…$ with .anchorsMatchLines)
        // and starts with the word "chapter" (case-insensitive on the
        // word only — the number is required to be uppercase or digits
        // so "chapter one of my journey" doesn't false-match).
        //
        // Matched enumerators:
        //   ASCII digits: 1, 12, 123
        //   Roman numerals (I-XL covers Moby's 135 chapters? No — XL = 40.
        //     For long books like Moby that go to 135, the number form
        //     is ASCII digits, so Roman only needs to cover up to ~40
        //     which is the upper bound where books still use Roman).
        //   Spelled-out (first ten): ONE..TEN
        let patterns: [String] = [
            // CHAPTER 1.  /  CHAPTER 12  /  CHAPTER 12:  /  CHAPTER 1 - Title
            #"(?im)^\s*CHAPTER\s+\d{1,3}[.\s:—-]"#,
            // CHAPTER I.  /  CHAPTER XII   /  Chapter I:
            #"(?im)^\s*CHAPTER\s+[IVXL]{1,5}[.\s:—-]"#,
            // CHAPTER ONE.  /  Chapter TWO
            #"(?im)^\s*CHAPTER\s+(ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN)[.\s:—-]"#,
        ]

        var bestRange: Range<Substring.Index>? = nil
        for pattern in patterns {
            if let r = region.range(of: pattern, options: [.regularExpression]) {
                if bestRange == nil || r.lowerBound < bestRange!.lowerBound {
                    bestRange = r
                }
            }
        }

        guard let matchRange = bestRange else { return nil }

        // Translate substring index back to absolute offset in plainText.
        let relativeOffset = region.distance(from: region.startIndex, to: matchRange.lowerBound)
        return startOffset + relativeOffset
    }
}

// ========== BLOCK 01: FIRST CHAPTER ADVANCE - END ==========
