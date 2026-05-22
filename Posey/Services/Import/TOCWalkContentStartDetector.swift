import Foundation

// ========== BLOCK 01: TOC TITLE CLASSIFIER - START ==========

/// Detects the offset at which the actual book content begins, given a
/// stored TOC and the document's plainText. Walks TOC entries in play
/// order from a starting offset, classifies each entry's title, and
/// lands at the first entry that's a recognized BODY_SECTION.
///
/// This is the third layer of content-start detection (after the
/// Gutenberg `*** START` detector and the in-prose Contents listing
/// detector). It catches the case where the previous layers leave the
/// reader sitting at a title page + publisher imprint + transcriber's
/// notes block — content that's neither part of the license nor part
/// of the book proper.
///
/// ### Worked examples (verified against the audit corpus)
///
/// **Moby Dick EPUB** — `stripEmbeddedTOC` already removes its
/// `<p class="toc">` Contents block at the HTML layer, so the prior
/// in-prose detector finds no anchor. TOC entries past current skip:
///
///   1. "MOBY-DICK; or, THE WHALE."         → TITLE_BLOCK   (skip past)
///   2. "Original Transcriber's Notes:"     → PUBLISHING_INFO (skip past)
///   3. "ETYMOLOGY."                         → BODY_SECTION  ← land here
///   4. "(Supplied by a Late Consumptive…)"  → (never reached)
///
/// User lands at "ETYMOLOGY." — the content Mark explicitly said to
/// keep.
///
/// **Pride and Prejudice EPUB** — Hugh Thomson edition. Saintsbury
/// Preface exists in plainText but is NOT in the nav. TOC entries past
/// current skip:
///
///   1. "PRIDE. and PREJUDICE"  → TITLE_BLOCK  (skip past)
///   2. "Chapter I."             → BODY_SECTION
///
/// Walk found a body-section entry, BUT the gap between current skip
/// (~948) and "Chapter I." (~29,291) is ~28,000 chars AND we didn't
/// walk past any PUBLISHING_INFO entries. That's the signature of
/// untagged content — the EPUB editor structured the title but not
/// the Preface that follows. The detector triggers a prose-paragraph
/// fallback: walk lines from current skip, skip short/all-caps/imprint
/// lines, land at the first substantial prose paragraph. For Pride
/// that's "Walt Whitman has somewhere a fine and just distinction…"
/// — the Saintsbury Preface body.
enum TOCWalkContentStartDetector {

    /// One entry as the walker sees it. Decoupled from the importer's
    /// EPUBTOCEntry type so the detector can be unit-tested against
    /// any title/offset shape.
    struct TOCEntry {
        let title: String
        let plainTextOffset: Int
    }

    /// Classification of a TOC entry's title.
    enum Classification {
        /// The book's title block ("MOBY-DICK;", "PRIDE. and PREJUDICE"),
        /// edition statements ("THE MILLENNIUM FULCRUM EDITION 3.0"),
        /// or in-prose Contents-listing entry that survived to the TOC
        /// table. Skip past.
        case titleBlock
        /// Editorial / publishing metadata that isn't part of the book:
        /// Transcriber's Notes, Editor's Note, Edition note, etc. Skip
        /// past per Mark's 2026-05-21 rule (publishing info, not content).
        case publishingInfo
        /// A real section of the book: Preface, Chapter, Letter,
        /// Introduction, Foreword, Etymology, Extracts, Prologue,
        /// Epilogue, Book/Part headings. Land here.
        case bodySection
        /// Doesn't match any of the above. Treated conservatively — we
        /// don't skip past unknown entries (might be real content).
        case unknown
    }

    /// Result of running the detector against a document.
    struct Result {
        /// The new skip offset to use, or nil if the detector couldn't
        /// confidently advance past the current skip.
        let newSkipOffset: Int?
        /// True when the result was refined via the prose-paragraph
        /// fallback (used when the gap to the first body section is
        /// large and no PUBLISHING_INFO entries were walked past).
        let usedProseFallback: Bool
    }

    /// Walk `tocEntries` (in play order — caller passes them sorted) past
    /// `currentSkip` and find the first BODY_SECTION entry.
    ///
    /// If the gap between the current skip and the first body section
    /// is large (> 5000 chars) AND no PUBLISHING_INFO entries were
    /// walked past, the gap likely contains untagged content (e.g.,
    /// Pride's Saintsbury Preface, which isn't in the TOC). Trigger
    /// the prose-paragraph fallback to find a more conservative skip
    /// inside the gap.
    static func detect(
        tocEntries: [TOCEntry],
        plainText: String,
        currentSkip: Int
    ) -> Result {
        var firstBodySectionOffset: Int? = nil
        var walkedPastPublishingInfo: Bool = false

        for entry in tocEntries {
            guard entry.plainTextOffset > currentSkip else { continue }
            switch classify(entry.title) {
            case .titleBlock:
                continue
            case .publishingInfo:
                walkedPastPublishingInfo = true
                continue
            case .bodySection:
                firstBodySectionOffset = entry.plainTextOffset
            case .unknown:
                continue
            }
            if firstBodySectionOffset != nil { break }
        }

        // Case 1: no body-section entry found — leave skip alone.
        guard let bodyOffset = firstBodySectionOffset else {
            return Result(newSkipOffset: nil, usedProseFallback: false)
        }

        // Case 2: TOC structurally classified intermediate front-matter
        // (e.g., Moby's "Original Transcriber's Notes:" entry sits
        // between the title and Etymology). Trust the TOC. Land at the
        // body-section offset.
        if walkedPastPublishingInfo {
            return Result(newSkipOffset: bodyOffset, usedProseFallback: false)
        }

        // Case 3: large gap, no intermediate PUBLISHING_INFO entries —
        // the EPUB's editor likely didn't structurally annotate
        // additional content that exists in the gap (Pride's
        // Saintsbury Preface is the canonical case). Refine via
        // prose-paragraph fallback within the gap.
        let gap = bodyOffset - currentSkip
        if gap > 5000 {
            if let proseOffset = firstProseParagraph(
                in: plainText,
                from: currentSkip,
                upTo: bodyOffset
            ) {
                // Use whichever is EARLIER — the prose start (which
                // captures untagged content like Pride's Preface) or
                // the body section. The body section is the safe
                // floor; the prose start is the preserve-content
                // optimization.
                return Result(
                    newSkipOffset: min(proseOffset, bodyOffset),
                    usedProseFallback: true
                )
            }
        }

        // Case 4: gap is reasonable; trust the TOC.
        return Result(newSkipOffset: bodyOffset, usedProseFallback: false)
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - Classification
    // ──────────────────────────────────────────────────────────────────────

    /// Classify a TOC entry's title text. Conservative: defaults to
    /// `.unknown` rather than aggressively skipping past anything that
    /// might be real content.
    static func classify(_ title: String) -> Classification {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }
        let lower = trimmed.lowercased()

        // BODY_SECTION first — these patterns are unambiguous markers
        // of real content per Mark's 2026-05-21 direction. They take
        // precedence over titleBlock detection (a chapter title in
        // all-caps still classifies as body-section, not title-block).
        let bodySectionPatterns: [String] = [
            #"^chapter\s+[ivxlcdm0-9]+"#,
            #"^letter\s+[ivxlcdm0-9]+"#,
            #"^book\s+[ivxlcdm0-9]+"#,
            #"^part\s+[ivxlcdm0-9]+"#,
            #"^volume\s+[ivxlcdm0-9]+"#,
            #"^canto\s+[ivxlcdm0-9]+"#,
            #"^act\s+[ivxlcdm0-9]+"#,
            #"^scene\s+[ivxlcdm0-9]+"#,
            // Standalone roman/arabic numerals optionally with period
            // and trailing title — e.g. "I.", "I. A SCANDAL IN BOHEMIA".
            #"^[ivxlcdm]+\.?(\s|$)"#,
            #"^\d+\.?(\s|$)"#,
            // Section-name words (case-insensitive).
            #"^(preface|foreword|introduction|prologue|epilogue|etymology|extracts|afterword|interlude|postscript)\b"#,
        ]
        for pattern in bodySectionPatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return .bodySection
            }
        }

        // PUBLISHING_INFO — narrow, distinctive phrases the importer
        // can be sure are editorial/publishing metadata.
        // 2026-05-22 — additions for PDF outline entries: PDFs ship
        // structural outlines that label cover / TOC / back-matter
        // sections explicitly. Without recognizing these, the walker
        // sees a large gap to "Introduction" and triggers prose
        // fallback that can land inside the back-cover blurb. The
        // patterns are deliberately narrow — `\bcover\b` alone would
        // overmatch (e.g., a chapter titled "Under Cover"), so we
        // require "back cover" / "front cover" / "the cover".
        let publishingInfoPatterns: [String] = [
            #"\btranscriber'?s?\s+note"#,
            #"\beditor'?s?\s+note"#,
            #"\bnote\s+(on|about)\s+the\s+text"#,
            #"\babout\s+(this|the)\s+(edition|text)"#,
            #"\bcolophon\b"#,
            #"\bimprint\b"#,
            #"\bpublisher'?s?\s+note"#,
            #"\bproject\s+gutenberg\s+(license|trademark)"#,
            #"^(back\s*cover|front\s*cover|the\s+cover)$"#,
            #"^(about\s+the\s+author|about\s+the\s+publisher)$"#,
            #"^(acknowledg(e)?ments?|dedication|copyright|colophon)$"#,
            #"^(index|glossary|bibliography|works\s+cited|references)$"#,
            #"^table\s+of\s+contents$"#,
            #"^list\s+of\s+(figures|tables|illustrations|sidebars|abbreviations)$"#,
        ]
        for pattern in publishingInfoPatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return .publishingInfo
            }
        }

        // TITLE_BLOCK — heuristic: short, predominantly uppercase or
        // entirely uppercase. Catches "MOBY-DICK; or, THE WHALE.",
        // "PRIDE. and PREJUDICE", "THE MILLENNIUM FULCRUM EDITION 3.0".
        if isTitleBlockShape(trimmed) {
            return .titleBlock
        }

        // Plain "Contents" / "Table of Contents" as a TOC entry —
        // treat as titleBlock so it's skipped past.
        if lower == "contents" || lower == "table of contents" {
            return .titleBlock
        }

        return .unknown
    }

    /// True when `s` looks like a title-page block heading. A short
    /// line predominantly in uppercase letters, with allowed
    /// punctuation. Catches "MOBY-DICK; or, THE WHALE." (mostly upper,
    /// 23 chars) and "THE MILLENNIUM FULCRUM EDITION 3.0" (38 chars)
    /// while NOT catching "Chapter I." (mixed case, has body-section
    /// keyword) or "A Mad Tea-Party" (mixed case, > 4 chars of
    /// lowercase).
    private static func isTitleBlockShape(_ s: String) -> Bool {
        let length = s.count
        guard length <= 80 else { return false }
        var upperCount = 0
        var lowerCount = 0
        for c in s {
            if c.isUppercase { upperCount += 1 }
            else if c.isLowercase { lowerCount += 1 }
        }
        let letterCount = upperCount + lowerCount
        guard letterCount > 0 else { return false }
        // At least 70% of letters must be uppercase, AND at most 4
        // lowercase letters total — enough to allow "or" / "and" /
        // "the" in title blocks like "PRIDE. and PREJUDICE" or
        // "MOBY-DICK; or, THE WHALE.", but not enough to let real
        // chapter titles like "Down the Rabbit-Hole" pass.
        let upperRatio = Double(upperCount) / Double(letterCount)
        return upperRatio >= 0.7 && lowerCount <= 4
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - Prose-paragraph fallback (Pride Saintsbury Preface case)
    // ──────────────────────────────────────────────────────────────────────

    /// Walk lines in `plainText[from..<upTo]` and return the offset of
    /// the first line that looks like a substantive prose paragraph.
    /// Skips:
    ///   - Empty lines
    ///   - Lines shorter than 60 chars
    ///   - All-uppercase lines (publisher imprint style)
    ///   - Lines that look like postal addresses (contains comma + ALL
    ///     CAPS city/country name at the end)
    /// Lands at the first line that's:
    ///   - At least 60 characters
    ///   - Contains at least 5 lowercase letters
    ///   - Contains at least one sentence-ending punctuation mark
    private static func firstProseParagraph(
        in plainText: String,
        from start: Int,
        upTo end: Int
    ) -> Int? {
        guard start >= 0, start < end, end <= plainText.count else { return nil }
        let startIdx = plainText.index(plainText.startIndex, offsetBy: start)
        let endIdx   = plainText.index(plainText.startIndex, offsetBy: end)

        var cursor = startIdx
        while cursor < endIdx {
            // Find next newline (or end).
            let lineEnd: String.Index
            if let nl = plainText.range(of: "\n", range: cursor..<endIdx)?.lowerBound {
                lineEnd = nl
            } else {
                lineEnd = endIdx
            }
            let line = plainText[cursor..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if isProseParagraph(trimmed) {
                return plainText.distance(from: plainText.startIndex, to: cursor)
            }

            // Advance past this line + the newline.
            cursor = lineEnd < endIdx ? plainText.index(after: lineEnd) : endIdx
        }
        return nil
    }

    /// True when `line` is shaped like a real prose paragraph rather
    /// than a publishing-imprint line.
    private static func isProseParagraph(_ line: String) -> Bool {
        guard line.count >= 60 else { return false }
        var lowercaseLetters = 0
        var hasSentenceEnd = false
        for c in line {
            if c.isLowercase { lowercaseLetters += 1 }
            if c == "." || c == "!" || c == "?" { hasSentenceEnd = true }
        }
        guard lowercaseLetters >= 5 else { return false }
        guard hasSentenceEnd else { return false }
        // Reject lines that look like address blocks — comma followed
        // by all-caps city/country name at the end.
        // e.g. "TOOKS COURT, CHANCERY LANE, LONDON." has length 35 so
        // already filtered. But longer imprint lines might slip
        // through; reject if the line is predominantly uppercase.
        var upper = 0, lower = 0
        for c in line {
            if c.isUppercase { upper += 1 }
            else if c.isLowercase { lower += 1 }
        }
        let totalLetters = upper + lower
        guard totalLetters > 0 else { return false }
        let upperRatio = Double(upper) / Double(totalLetters)
        // Reject if 50%+ of letters are uppercase (typical imprint).
        guard upperRatio < 0.5 else { return false }
        return true
    }
}

// ========== BLOCK 01: TOC TITLE CLASSIFIER - END ==========
