import Foundation

// ========== BLOCK 01: GUTENBERG BOUNDARY DETECTOR - START ==========

/// Detects Project Gutenberg's universal start/end boundary markers in an
/// already-extracted `plainText` string. Used by EPUB, HTML, and TXT
/// importers (and any future format whose source might be Gutenberg-derived)
/// to identify the offset range that contains the actual book content,
/// separate from Gutenberg's legal preamble at the head and license trailer
/// at the foot.
///
/// ### What this detects, what it doesn't
///
/// **Skips** (offsets BEFORE `contentStart` are not read aloud):
///
/// - The Project Gutenberg license preamble
/// - The eBook of header (`The Project Gutenberg eBook of [Title]`)
/// - The Title / Author / Release date metadata block
/// - The `Credits:` line
/// - The `*** START OF THE PROJECT GUTENBERG EBOOK [TITLE] ***` marker
///   itself
///
/// **Reads aloud** (everything between `contentStart` and `contentEnd`):
///
/// - Title pages with the book's own typography (e.g. "MOBY-DICK; / or, THE
///   WHALE. / By Herman Melville")
/// - Author prefaces (Saintsbury's Preface in Pride and Prejudice)
/// - Front-matter that is part of the work itself (Moby Dick's Etymology
///   and Extracts, Frankenstein's Letters I-IV)
/// - The actual book body — chapters, prose, poetry, plays, etc.
///
/// **Skips** (offsets AT/AFTER `contentEnd` are not read aloud):
///
/// - The `*** END OF THE PROJECT GUTENBERG EBOOK [TITLE] ***` marker
/// - The Gutenberg license trailer (donations, newsletter, FAQ, etc.)
///
/// Per Mark's 2026-05-21 direction: skip copyright notices, publishing
/// information, and tables of contents (handled separately by TOC stripping
/// in the EPUB importer); read everything else, including prefaces,
/// introductions, author's notes, etymologies, forewords.
///
/// ### Why a single shared detector for three formats
///
/// Project Gutenberg's distribution toolchain emits the SAME boundary
/// markers in every format it produces — `.epub`, `.html`, `.txt`. Sample
/// from Moby Dick #2701:
///
///   EPUB plainText: `*** START OF THE PROJECT GUTENBERG EBOOK MOBY DICK; OR, THE WHALE ***`
///   HTML plainText: `*** START OF THE PROJECT GUTENBERG EBOOK MOBY DICK; OR, THE WHALE ***`
///   TXT  plainText: `*** START OF THE PROJECT GUTENBERG EBOOK 2701 ***`
///
/// One detector. One regex. Applied to the post-extraction string by every
/// importer that might receive Gutenberg content. The detector is unaware
/// of format.
///
/// ### Tolerance for corpus drift
///
/// The exact wording has drifted across two decades of Gutenberg history:
/// older texts use `THIS PROJECT GUTENBERG`, even older ones use `ETEXT`
/// instead of `EBOOK`, sometimes with hyphens (`E-BOOK`), sometimes with
/// trademark symbols. The patterns below match all observed historical
/// variants but stay narrow enough that real prose can't accidentally
/// match — the literal string `*** START OF THE PROJECT GUTENBERG` is
/// stylistically forbidden inside any actual book content.
enum GutenbergBoundaryDetector {

    /// Result of a successful detection. Either offset can independently
    /// be `nil` if only one marker was found in the text — the importer
    /// should still apply whichever side matched.
    struct Result: Equatable {
        /// Character offset in plainText at which actual book content
        /// begins. Equal to the position of the first non-whitespace
        /// character after the closing `***` of the START marker.
        let contentStartOffset: Int?
        /// Character offset in plainText at which content ends — i.e.,
        /// the offset of the opening `***` of the END marker. Reader
        /// playback should pause when reaching this offset.
        let contentEndOffset: Int?
    }

    /// Search `plainText` for Gutenberg boundary markers. Returns a
    /// `Result` with whichever boundaries were found. `nil` on either
    /// side means "no boundary detected" — the importer should leave
    /// the corresponding stored offset at 0 (the sentinel).
    ///
    /// Defensive on order: if the END marker appears BEFORE the START
    /// marker (impossible in real Gutenberg files but could happen in
    /// a doctored corpus or unusual concatenation), the result returns
    /// `nil` for both — better to leave the document alone than to
    /// silently truncate it.
    static func detect(in plainText: String) -> Result {
        guard !plainText.isEmpty else {
            return Result(contentStartOffset: nil, contentEndOffset: nil)
        }

        // Match patterns. We're case-insensitive across the whole
        // pattern and multi-line aware. Each pattern matches one line
        // (anchored to a line boundary via `^…$` in MULTI-LINE mode)
        // containing the `***` marker.
        //
        // Layout:
        //   leading ***
        //   optional space
        //   START|END OF
        //   optional "the"|"this"
        //   PROJECT GUTENBERG
        //   EBOOK|E-BOOK|ETEXT
        //   any title text (non-greedy, up to the trailing ***)
        //   trailing ***
        //
        // Whitespace tolerance: arbitrary horizontal whitespace between
        // tokens; `*\s*` allows `***   START` or similar oddities.
        //
        // The `(?im)` flags: case-insensitive + multi-line.
        let startPattern = #"(?im)^\s*\*\s*\*\s*\*\s*START\s+OF\s+(?:THE\s+|THIS\s+)?PROJECT\s+GUTENBERG\s+(?:E-?BOOK|ETEXT|EBOOK\s*™?).*?\*\s*\*\s*\*\s*$"#
        let endPattern   = #"(?im)^\s*\*\s*\*\s*\*\s*END\s+OF\s+(?:THE\s+|THIS\s+)?PROJECT\s+GUTENBERG\s+(?:E-?BOOK|ETEXT|EBOOK\s*™?).*?\*\s*\*\s*\*\s*$"#
        // 2026-06-13 — Older Gutenberg files (and some modern ones, e.g.
        // dickinson-poems_12242) print a BYLINE end-line WITHOUT asterisks —
        // `End of [the/this] Project Gutenberg['s/™] <title>, by <author>` — that
        // sits a few blank lines BEFORE the `*** END … ***` marker. The asterisk
        // pattern matches only the starred marker, so contentEnd lands just before
        // it and the byline (e.g. "End of Project Gutenberg's Poems…, by Emily
        // Dickinson") is left INSIDE the read-aloud flow (c3/c14 leak). Detect the
        // byline too and cut at whichever boundary comes FIRST. Distinctive,
        // line-anchored — does not match ordinary prose.
        let bylinePattern = #"(?im)^\s*End\s+of\s+(?:the\s+|this\s+)?Project\s+Gutenberg(?:['’]s|\s*™)?\b.*$"#

        let startMatchRange = firstMatchRange(of: startPattern, in: plainText)
        let asteriskEndRange = lastMatchRange(of: endPattern, in: plainText)
        let bylineEndRange   = lastMatchRange(of: bylinePattern, in: plainText)

        // Choose the effective end boundary. Default: the asterisk marker.
        // Prefer the byline when it precedes the asterisk marker within a small
        // window (the byline-then-marker layout); or, when there is NO asterisk
        // marker at all, accept the byline only if it sits in the last 15% of the
        // document (so a stray "End of … Project Gutenberg …" inside body prose
        // can't truncate a whole book).
        let endMatchRange: Range<String.Index>? = {
            guard let byline = bylineEndRange else { return asteriskEndRange }
            let total = plainText.count
            let bylineOff = plainText.distance(from: plainText.startIndex, to: byline.lowerBound)
            if let asterisk = asteriskEndRange {
                let asteriskOff = plainText.distance(from: plainText.startIndex, to: asterisk.lowerBound)
                if bylineOff < asteriskOff && (asteriskOff - bylineOff) <= 3000 {
                    return byline
                }
                return asterisk
            }
            return bylineOff * 100 > total * 85 ? byline : nil
        }()

        // Order check: if both found, the END marker must come AFTER
        // the START marker. Otherwise something is structurally wrong;
        // bail out with no detections rather than risk a bad slice.
        if let s = startMatchRange, let e = endMatchRange, e.lowerBound <= s.upperBound {
            return Result(contentStartOffset: nil, contentEndOffset: nil)
        }

        var contentStart: Int? = nil
        if let startRange = startMatchRange {
            // contentStart = offset of the first non-whitespace
            // character AFTER the END of the START marker line. Skips
            // the blank line that typically follows `*** START …***`
            // in Gutenberg files.
            let afterMarker = startRange.upperBound
            let scanRange = afterMarker..<plainText.endIndex
            if let firstNonWS = plainText.rangeOfCharacter(
                from: CharacterSet.whitespacesAndNewlines.inverted,
                options: [],
                range: scanRange
            ) {
                contentStart = plainText.utf16.distance(
                    from: plainText.utf16.startIndex,
                    to: firstNonWS.lowerBound.samePosition(in: plainText.utf16) ?? plainText.utf16.startIndex
                )
                // Recompute using Character distance for parity with
                // how other importers store offsets (plainText.count
                // is a Character count, not utf16). Importers use
                // `.count` on String everywhere else — match that.
                contentStart = plainText.distance(
                    from: plainText.startIndex,
                    to: firstNonWS.lowerBound
                )
            }
        }

        var contentEnd: Int? = nil
        if let endRange = endMatchRange {
            // contentEnd = offset of the LAST non-whitespace character
            // before the START of the END marker line, plus 1 (so the
            // offset is the position the reader would naturally stop
            // at — past the last content char, before any trailing
            // whitespace and the marker itself).
            let beforeMarker = endRange.lowerBound
            let scanRange = plainText.startIndex..<beforeMarker
            // Scan backward for last non-whitespace.
            if let lastNonWSChar = plainText[scanRange].reversed().firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) {
                // Translate reversed index back into the forward string.
                let revDistance = plainText[scanRange].reversed().distance(from: plainText[scanRange].reversed().startIndex, to: lastNonWSChar)
                let forwardIndex = plainText[scanRange].index(plainText[scanRange].endIndex, offsetBy: -(revDistance + 1))
                // contentEnd is the offset AFTER the last content char.
                let nextIndex = plainText.index(after: forwardIndex)
                contentEnd = plainText.distance(from: plainText.startIndex, to: nextIndex)
            } else {
                // No content before the END marker. Set contentEnd at
                // the marker start; the reader will treat the doc as
                // empty (defensive, shouldn't happen in practice).
                contentEnd = plainText.distance(from: plainText.startIndex, to: beforeMarker)
            }
        }

        return Result(contentStartOffset: contentStart, contentEndOffset: contentEnd)
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - Internals
    // ──────────────────────────────────────────────────────────────────────

    private static func firstMatchRange(of pattern: String, in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        return Range(match.range, in: text)
    }

    private static func lastMatchRange(of pattern: String, in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard let last = matches.last else { return nil }
        return Range(last.range, in: text)
    }
}

// ========== BLOCK 01: GUTENBERG BOUNDARY DETECTOR - END ==========
