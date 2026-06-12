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

    /// 2026-06-11 [DECISION] (Mark, supersedes 2026-05-27) — all prefaces are
    /// BOOK CONTENT: a gutenberg book opens at the FIRST REAL PROSE after the
    /// in-book Contents LISTING, never skipping a preface to Chapter I. This
    /// helper handles the case the `endOfTOCRegion` second-occurrence heuristic
    /// MISSES: the skip is still sitting ON a Contents listing (e.g. Dracula —
    /// the TOC entry "CHAPTER I. Jonathan Harker's Journal" never finds a second
    /// occurrence because the merged body heading is "CHAPTER I: JONATHAN
    /// HARKER'S JOURNAL" — period vs colon). It walks the contiguous run of
    /// chapter-entry lines and returns the offset of the first SUBSTANTIAL PROSE
    /// line after them (Dracula → Stoker's preface "How these papers…", NOT
    /// Chapter I). GUARDED to fire ONLY when `skipOffset` is on a Contents
    /// listing (a "Contents" header sits just before it), so it's a NO-OP for
    /// docs whose skip already advanced past their Contents (Moby/Alice/Sherlock)
    /// and for docs with no in-prose Contents (Pride & Prejudice → nav-only).
    ///
    /// `tocTitles` (the structural nav entries) widen entry-line recognition
    /// beyond the CHAPTER/LETTER/PART/BOOK shapes for listings that don't use
    /// those prefixes.
    static func firstProseAfterContentsListing(
        in plainText: String, at skipOffset: Int, tocTitles: [String]
    ) -> Int? {
        guard skipOffset >= 0, skipOffset < plainText.count else { return nil }
        let skipIdx = plainText.index(plainText.startIndex, offsetBy: skipOffset)

        // GUARD — find an in-book "Contents" header AHEAD of skipOffset, within a
        // bounded window (the title page + publishing front-matter before the
        // Contents is short; cap so we never match a "Contents" word deep in the
        // body). The skip may sit BEFORE the Contents (Dracula: skip at the title
        // page ~813, Contents header ~1103) or just on it — either way we search
        // forward from skipOffset. No header ahead → the skip already cleared any
        // Contents (Moby at ETYMOLOGY, P&P nav-only) → NO-OP.
        let windowEnd = plainText.index(skipIdx, offsetBy: min(6000, plainText.count - skipOffset))
        let window = plainText[skipIdx..<windowEnd]
        let headerRe = #"(?im)^\s*(?:contents|table\s+of\s+contents)[:.]?\s*$"#
        guard let headerRange = window.range(of: headerRe, options: .regularExpression) else { return nil }

        // Normalize the nav titles for fuzzy line matching.
        let normTitles = Set(tocTitles.map { normalizeForMatch($0) }.filter { $0.count >= 4 })

        // Walk lines forward from JUST AFTER the Contents header. Skip the
        // contiguous run of chapter-entry / listing lines; stop at the first
        // substantial PROSE line (≥60 chars, sentence-shaped, not a heading) —
        // Dracula → Stoker's preface "How these papers…", NOT Chapter I. Cap the
        // walk so a malformed listing can't run away.
        let walkStart = headerRange.upperBound
        let walkStartOffset = plainText.distance(from: plainText.startIndex, to: walkStart)
        let region = plainText[walkStart..<plainText.endIndex]
        let lines = region.split(separator: "\n", maxSplits: 300, omittingEmptySubsequences: false)
        var consumed = 0  // characters walked past the header (offset delta)
        var sawEntry = false
        for line in lines {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lineLen = raw.count + 1  // +1 for the split "\n"
            if trimmed.isEmpty { consumed += lineLen; continue }
            if isContentsEntryLine(trimmed, normTitles: normTitles) {
                sawEntry = true; consumed += lineLen; continue
            }
            // First non-entry, substantial-prose line → the body/preface start.
            if sawEntry, isSubstantialProse(trimmed) {
                let leadingWS = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
                let target = walkStartOffset + consumed + leadingWS
                return target > skipOffset ? target : nil
            }
            // A non-entry, non-prose line before we saw any entry → the header
            // wasn't followed by a listing; bail (no-op) rather than guess.
            if !sawEntry { return nil }
            consumed += lineLen
        }
        return nil
    }

    /// 2026-06-11 (auditor c6 ruling) — advance past a leading run of
    /// PUBLISHING-APPARATUS / title-page boilerplate to the first real content.
    /// Runs as the FINAL skip step (after the gutenberg + Contents-listing skip).
    /// FRAMING (auditor, to remove over-skip risk): "skip POSITIVELY-MATCHED
    /// boilerplate, STOP at the first non-boilerplate line." It only ACTIVATES if
    /// the landing line is itself apparatus/caption — otherwise NO-OP (returns
    /// nil), so a doc already sitting on real content (Moby → "ETYMOLOGY.",
    /// Dracula → its preface) is never touched. STOP conditions (checked before
    /// any skip): a recognized CONTENT-HEADING (PREFACE/INTRODUCTION/FOREWORD/
    /// PROLOGUE/ETYMOLOGY/EXTRACTS/ARGUMENT/LETTER/DEDICATION/CHAPTER/CONTENTS) or
    /// substantial sentence-shaped prose — so ETYMOLOGY and "Letter 1" are
    /// STOPPED AT, never past (no content loss). SKIP: publisher/press/printer
    /// names, addresses, bare years, copyright, dedication, the split title-page
    /// type, "List of Illustrations" + figure captions. Verified P&P → "PREFACE.",
    /// Moby → ETYMOLOGY (no-op), Dracula → preface (no-op). Bounded to the leading
    /// ~90 lines; SAFETY DEFAULT = STOP on any line that doesn't clearly match a
    /// skip pattern (under-skip = a little boilerplate ≪ over-skip = content loss).
    static func contentStartAfterPublishingApparatus(in plainText: String, at skipOffset: Int) -> Int? {
        guard skipOffset >= 0, skipOffset < plainText.count else { return nil }
        let startIdx = plainText.index(plainText.startIndex, offsetBy: skipOffset)
        let region = plainText[startIdx...]
        let lines = region.split(separator: "\n", maxSplits: 90, omittingEmptySubsequences: false)
        var consumed = 0          // characters walked (offset delta), incl. the "\n"
        var sawApparatus = false
        for line in lines {
            let raw = String(line)
            let lineLen = raw.count + 1
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { consumed += lineLen; continue }
            // STOP at a real content boundary (checked FIRST → never over-skips).
            if isContentHeadingLine(s) {
                return sawApparatus ? skipOffset + consumed : nil
            }
            // SKIP positively-matched publishing apparatus / title-page captions.
            if isPublishingApparatus(s) || isTitlePageCaption(s) {
                sawApparatus = true; consumed += lineLen; continue
            }
            if isApparatusSkipProse(s) {     // substantial prose = real content → STOP
                return sawApparatus ? skipOffset + consumed : nil
            }
            // Split title-page type ("PRIDE." / "and" / "PREJUDICE" / "by") — only
            // skipped once we're already inside the apparatus block.
            if sawApparatus && s.count < 40 { consumed += lineLen; continue }
            // Safety default: anything else → STOP (no-op if we never skipped).
            return sawApparatus ? skipOffset + consumed : nil
        }
        return nil
    }

    /// 2026-06-12 (finding #2 / dracula c3+c14 — the END-boundary mirror of
    /// `contentStartAfterPublishingApparatus`): some public-domain reprints —
    /// notably Grosset & Dunlap editions on Project Gutenberg (Dracula) — append
    /// a PUBLISHER'S CATALOG ADVERTISEMENT between the work's true ending and the
    /// `*** END OF THE PROJECT GUTENBERG EBOOK ***` marker. `GutenbergBoundaryDetector`
    /// sets `contentEndOffset` just before that PG marker, which correctly bounds
    /// out the license — but the ad ("There's More to Follow!", a list of other
    /// titles, "GROSSET & DUNLAP, Publishers, NEW YORK") falls INSIDE the readable /
    /// playback flow, so the reader hits a sales pitch right after the story ends.
    /// Pull `contentEnd` back to just after the book's true ending.
    ///
    /// CATEGORY (Rule 10): a trailing publisher advertisement / "Authors'
    /// Alphabetical List" appended to a reprint. The reliable, safe boundary is the
    /// standalone end-of-book marker line ("THE END" / "FINIS") that sits between
    /// the last prose and the ad. Signals tying the marker to a real ad: a
    /// distinctive imprint/marketing anchor in the tail window (GROSSET & DUNLAP,
    /// "There's More to Follow", "Ask for … free list", "wherever books are sold",
    /// "for a complete catalog", "Authors' Alphabetical List", "by the author of
    /// this one", "Look on the Other Side of the Wrapper").
    /// Edge cases: a book whose trailing ad has NO "THE END" marker → NO-OP (we do
    /// not guess where the prose ends); a book with no trailing ad at all → NO-OP
    /// (the overwhelming majority — the anchor never matches); a "THE END" that is
    /// NOT followed by an ad → NO-OP (the marker must precede the anchor).
    /// SAFETY DEFAULT: return nil (leave `contentEnd` untouched) unless a
    /// publisher-ad anchor is positively present AND an end-of-book marker precedes
    /// it. Truncating real ending prose is a far worse harm than a missed ad.
    static func contentEndBeforePublisherCatalog(in plainText: String, at contentEndOffset: Int) -> Int? {
        guard contentEndOffset > 0, contentEndOffset <= plainText.count else { return nil }
        // Tail window: the last ~6000 chars of readable content (an appended
        // publisher catalog is short and always butts against contentEnd).
        let windowLen = min(6000, contentEndOffset)
        let windowBase = contentEndOffset - windowLen
        let endIdx = plainText.index(plainText.startIndex, offsetBy: contentEndOffset)
        let startIdx = plainText.index(endIdx, offsetBy: -windowLen)
        let window = String(plainText[startIdx..<endIdx])
        // Require a distinctive trailing publisher-ad / catalog anchor in the tail.
        guard let anchorRange = window.range(
            of: #"(?i)(GROSSET ?& ?DUNLAP|There[’'`]s More to Follow|Ask for .{0,40}free list|wherever books are sold|for a complete catalog|Authors[’'`]? Alphabetical List|by the author of this one|Look on the Other Side of the Wrapper)"#,
            options: .regularExpression
        ) else { return nil }
        let anchorOff = window.distance(from: window.startIndex, to: anchorRange.lowerBound)
        // Find the LAST standalone end-of-book marker line ENDING at or before the
        // ad anchor — that marker is the book's true ending; the ad follows it.
        var offset = 0
        var cut: Int? = nil
        for line in window.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            let lineLen = raw.count + 1   // include the consumed "\n"
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty,
               s.range(of: #"(?i)^(THE END|FINIS)\.?$"#, options: .regularExpression) != nil,
               let r = raw.range(of: s) {
                let markerEnd = offset + raw.distance(from: raw.startIndex, to: r.upperBound)
                if markerEnd <= anchorOff { cut = markerEnd }
            }
            offset += lineLen
        }
        guard let cutOff = cut, cutOff > 0, cutOff < windowLen else { return nil }
        return windowBase + cutOff
    }

    private static func isContentHeadingLine(_ s: String) -> Bool {
        return s.range(of: #"(?i)^(PREFACE|INTRODUCTION|FOREWORD|PROLOGUE|ETYMOLOGY|EXTRACTS|ARGUMENT|LETTER|DEDICATION|CHAPTER|CONTENTS)\b"#,
                       options: .regularExpression) != nil
    }

    private static func isApparatusSkipProse(_ s: String) -> Bool {
        guard s.count >= 80 else { return false }
        if s.contains(". ") { return true }
        if let last = s.last, ".!?”\"".contains(last) { return true }
        return false
    }

    private static func isPublishingApparatus(_ s: String) -> Bool {
        if s.range(of: #"(?i)\b(PUBLISHER|PUBLISHERS|PRESS|PRINTED BY|& ?CO\.|GROSSET|DUNLAP|GEORGE ALLEN|CHISWICK|RUSKIN HOUSE)\b"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"(?i)(Illustrations? by|Hugh Thomson|by Jane Austen|by Bram Stoker|by Herman Melville)"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"(?i)^To .{0,160}(acknowledgment|inscribed|gratefully|dedicated)"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^\d{3,4}\.?$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"(?i)^(Copyright|©)"#, options: .regularExpression) != nil { return true }
        if s.count < 70, s.range(of: #"(?i)\b(ROAD|STREET|AVENUE|LANE|COURT|NEW YORK|LONDON|CHARING)\b"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"(?i)^List of Illustrations"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func isTitlePageCaption(_ s: String) -> Bool {
        guard s.count <= 80 else { return false }
        if s.range(of: #"(?i)(Chap\.?\s*\d|Page\s*\d|\(Page)"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[“"].{0,70}[”"]\.?$"#, options: .regularExpression) != nil { return true }   // quoted scene caption
        if s.count < 70, s.range(of: #"\s\d{1,3}$"#, options: .regularExpression) != nil { return true } // caption + page no.
        if s.hasPrefix("·") || s.hasSuffix("·") { return true }
        return false
    }

    /// A line that belongs to a Contents listing: a CHAPTER/LETTER/PART/BOOK/
    /// VOLUME heading line, OR a short title-ish line, OR a fuzzy match to a
    /// structural nav title. NOT substantial prose.
    private static func isContentsEntryLine(_ s: String, normTitles: Set<String>) -> Bool {
        if isNumeralOnly(s) { return true }
        if s.range(of: #"(?i)^\s*(CHAPTER|LETTER|PART|BOOK|VOLUME)\s+(\d{1,3}|[IVXLCDM]{1,7})\b"#,
                   options: .regularExpression) != nil { return true }
        if normTitles.contains(normalizeForMatch(s)) { return true }
        // Short title-case-ish line with no sentence punctuation → likely a
        // listing entry, not prose.
        if s.count <= 70 && !isSubstantialProse(s) { return true }
        return false
    }

    /// Substantial prose: long enough and sentence-shaped (contains ". " or ends
    /// with sentence punctuation). The preface "How these papers have been
    /// placed in sequence…" qualifies; a chapter title does not.
    private static func isSubstantialProse(_ s: String) -> Bool {
        guard s.count >= 60 else { return false }
        if s.contains(". ") || s.contains(", ") { return true }
        if let last = s.last, ".!?".contains(last) { return true }
        return false
    }

    private static func normalizeForMatch(_ s: String) -> String {
        return s.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
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
