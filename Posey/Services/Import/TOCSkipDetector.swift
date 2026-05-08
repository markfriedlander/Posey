import Foundation

// ========== BLOCK 01: TOC SKIP DETECTOR - START ==========

/// 2026-05-07 (parity #6 closure): shared helper for DOCX and RTF
/// importers to compute `playbackSkipUntilOffset`. PDF and EPUB use
/// their own format-specific detectors (PDF's text-pattern dot-leader
/// detector, EPUB's front-matter detector); DOCX and RTF don't have
/// equivalent text patterns, but they DO have heading-styled
/// paragraphs which the new heading-detection work surfaces.
///
/// The signal: a heading whose title is "Contents" or "Table of
/// Contents" (case-insensitive, trimmed of trailing punctuation) is
/// almost always the TOC section header. Skip past it (and any
/// dot-leader-style entries between it and the next real heading) by
/// setting the skip offset to the next heading's offset.
///
/// Returns 0 if no TOC heading is found, or if the TOC heading is the
/// last heading in the doc (skipping past everything would leave
/// nothing to play).
enum TOCSkipDetector {
    /// `headings` is a list of (title, plainTextOffset) tuples in
    /// document order — same shape both `DOCXHeadingEntry` and
    /// `RTFHeadingEntry` reduce to.
    ///
    /// `plainText` is the document's normalized plainText. Used to
    /// detect a dot-leader-style TOC region (paragraphs like
    /// `"Chapter 1 ............ 5"`) and skip past the whole region,
    /// not just the "Contents" heading. Without this, a doc with
    /// hard-typed dot-leader TOC entries would have those entries
    /// read aloud during playback.
    static func skipOffset(
        for headings: [(title: String, plainTextOffset: Int)],
        in plainText: String
    ) -> Int {
        // Path 1: a "Contents" heading exists. Skip past it and
        // any contiguous dot-leader region after it.
        if headings.count >= 2 {
            for (i, entry) in headings.enumerated() {
                guard isTOCTitle(entry.title) else { continue }
                for j in (i + 1)..<headings.count {
                    if isTOCTitle(headings[j].title) { continue }
                    let candidateOffset = headings[j].plainTextOffset
                    return endOfDotLeaderRegion(startingAt: candidateOffset, in: plainText)
                }
                return 0
            }
        }
        // Path 2: no "Contents" heading, but the doc may still
        // have a hand-typed dot-leader TOC right after the title /
        // abstract. Scan plainText for the first contiguous run of
        // >= 3 dot-leader lines and skip past it.
        return findOrphanDotLeaderRegionEnd(in: plainText)
    }

    /// Scan `plainText` line-by-line for the first contiguous run of
    /// >= 3 dot-leader lines (which a hand-typed TOC almost always is).
    /// Returns the offset of the first non-dot-leader line after the
    /// run, or 0 if no such run exists. Defends against very short
    /// false matches (a single "Chapter 5" line).
    private static func findOrphanDotLeaderRegionEnd(in plainText: String) -> Int {
        guard !plainText.isEmpty,
              let dotLeader = try? NSRegularExpression(pattern: #"^.+?(?:\t+|[ .]{3,})\d+\s*$"#)
        else { return 0 }

        var cursor = plainText.startIndex
        var runStart: String.Index? = nil
        var runCount = 0
        var runEnd: String.Index = cursor

        while cursor < plainText.endIndex {
            let lineEnd = plainText.range(of: "\n", range: cursor..<plainText.endIndex)?.lowerBound
                ?? plainText.endIndex
            let line = String(plainText[cursor..<lineEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nextCursor = lineEnd < plainText.endIndex
                ? plainText.index(after: lineEnd) : lineEnd

            if line.isEmpty {
                cursor = nextCursor
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            if dotLeader.firstMatch(in: line, range: range) != nil {
                if runStart == nil { runStart = cursor }
                runCount += 1
                runEnd = nextCursor
            } else if runStart != nil {
                if runCount >= 3 {
                    // Run ended at a real content line — return the
                    // offset of THIS line (the first non-TOC content).
                    return plainText.distance(from: plainText.startIndex, to: cursor)
                }
                // Short run, reset.
                runStart = nil
                runCount = 0
            }
            cursor = nextCursor
        }
        // End of doc reached. If we accumulated a run, return its end.
        if let _ = runStart, runCount >= 3 {
            return plainText.distance(from: plainText.startIndex, to: runEnd)
        }
        return 0
    }

    /// Backward-compatible overload for callers that don't have
    /// plainText handy. Falls back to the simple "next non-TOC
    /// heading offset" approach without dot-leader scanning.
    static func skipOffset(for headings: [(title: String, plainTextOffset: Int)]) -> Int {
        skipOffset(for: headings, in: "")
    }

    /// Walks forward from `offset` through lines (separated by `\n`)
    /// and returns the offset of the first line that is NOT a dot-
    /// leader entry. If `offset` doesn't point at a dot-leader line,
    /// returns `offset` unchanged. If `plainText` is empty (legacy
    /// caller), returns `offset` unchanged.
    ///
    /// Walks line-by-line (single `\n`) rather than paragraph-by-
    /// paragraph (`\n\n`) because RTF/DOCX TOC dot-leader entries
    /// often appear as consecutive lines within a single paragraph.
    private static func endOfDotLeaderRegion(startingAt offset: Int, in plainText: String) -> Int {
        guard !plainText.isEmpty,
              offset >= 0, offset < plainText.count else { return offset }
        // Match a TOC line: title text, followed by either a tab
        // (Word's most common rendering of "leader" between title
        // and page number) OR 3+ leader chars (period/space), then
        // digits at end of line.
        // Examples: "Chapter 1 ........ 5", "Introduction\t5",
        // "Embracing Collaboration\t6".
        guard let dotLeader = try? NSRegularExpression(
            pattern: #"^.+?(?:\t+|[ .]{3,})\d+\s*$"#
        ) else { return offset }

        var cursor = offset
        while cursor < plainText.count {
            let cursorIdx = plainText.index(plainText.startIndex, offsetBy: cursor, limitedBy: plainText.endIndex) ?? plainText.endIndex
            let remainder = plainText[cursorIdx...]
            // Find the next line boundary (\n).
            let lineEndIdx: String.Index
            if let r = remainder.range(of: "\n") {
                lineEndIdx = r.lowerBound
            } else {
                lineEndIdx = remainder.endIndex
            }
            let line = String(remainder[..<lineEndIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty lines (paragraph breaks) — keep walking.
            if line.isEmpty {
                cursor += plainText.distance(from: cursorIdx, to: lineEndIdx) + 1
                continue
            }

            let range = NSRange(line.startIndex..., in: line)
            if dotLeader.firstMatch(in: line, range: range) == nil {
                // First non-dot-leader, non-empty line — TOC ends.
                return cursor
            }
            // Advance past this line (and the \n separator).
            cursor += plainText.distance(from: cursorIdx, to: lineEndIdx)
            if cursor < plainText.count {
                cursor += 1   // skip the \n
            }
        }
        return cursor
    }

    /// Match common TOC section titles. Case-insensitive, tolerant of
    /// trailing punctuation and whitespace. Examples that match:
    /// "Contents", "CONTENTS", "Table of Contents", "Table of
    /// Contents.", "  contents  ".
    static func isTOCTitle(_ title: String) -> Bool {
        var t = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Strip trailing periods and colons that some Word templates add.
        while let last = t.last, last == "." || last == ":" {
            t.removeLast()
        }
        return t == "contents"
            || t == "table of contents"
    }
}

// ========== BLOCK 01: TOC SKIP DETECTOR - END ==========
