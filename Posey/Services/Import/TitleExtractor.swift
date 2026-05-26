import Foundation

// ========== BLOCK 01: TITLE EXTRACTOR - START ==========

/// **2026-05-26 — Mark-requested.** Library cards were showing
/// filename-shaped titles full of underscores, hyphens, and Project
/// Gutenberg ID prefixes (e.g. `pg2701-images_3` or `10-mark-twain`).
/// This helper extracts a clean, human-readable title from document
/// content when available, falling back to a cleaned-up filename
/// otherwise.
///
/// Per-format strategy:
/// - **MD** — first `# H1` (or `## H2` if no H1).
/// - **HTML** — `<title>` tag content, then first `<h1>`.
/// - **TXT** — first non-empty line if it looks "title-like" (short,
///   no terminal punctuation). Project Gutenberg's "Title:" header
///   line is recognized and preferred over the raw first line.
/// - **DOCX** — handled at the document-importer level via the
///   `<dc:title>` core property; this helper provides only the
///   filename fallback when that's missing.
/// - **PDF / EPUB** — already extract from metadata at the document
///   importer; no helper needed here.
///
/// Filename fallback: strip extension, strip Gutenberg ID prefix
/// (e.g. `pg2701-images_3`, `10-mark-twain`), replace remaining
/// underscores + hyphens with spaces, collapse multiple spaces,
/// trim, title-case.
enum TitleExtractor {

    /// Strip extension, normalize separators, drop common library
    /// prefixes. Used as the fallback when no content title can be
    /// extracted. Always returns a non-empty string (uses
    /// `"Untitled"` as a last resort).
    static func cleanedFilename(_ rawFilename: String) -> String {
        // 1. Drop the extension.
        var s = (rawFilename as NSString).deletingPathExtension
        // 2. Strip leading "pg<digits>" / "pg<digits>-" / "<digits>-"
        //    Gutenberg-style ID prefixes.
        if let pgMatch = s.range(of: #"^pg\d+[-_]?"#, options: .regularExpression) {
            s = String(s[pgMatch.upperBound...])
        } else if let leadingDigits = s.range(of: #"^\d+[-_]"#, options: .regularExpression) {
            s = String(s[leadingDigits.upperBound...])
        }
        // 3. Drop trailing "_<digits>" or "-<digits>" run suffixes
        //    (e.g. `_3`, `-images`, `-images_3`).
        s = s.replacingOccurrences(
            of: #"([-_](images|cleaned|raw))*([-_]\d+)*$"#,
            with: "",
            options: .regularExpression
        )
        // 4. Replace remaining separators with spaces.
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: "-", with: " ")
        // 5. Collapse multiple spaces, trim.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 6. Title-case (capitalize each word) but preserve acronym-style
        //    runs that are already all-caps (e.g. NASA, RFC).
        if !s.isEmpty {
            let words = s.split(separator: " ")
            s = words.map { w -> String in
                let str = String(w)
                if str == str.uppercased() && str.count > 1 { return str }
                return str.prefix(1).uppercased() + str.dropFirst().lowercased()
            }.joined(separator: " ")
        }
        return s.isEmpty ? "Untitled" : s
    }

    /// Combine content-extracted title with filename fallback.
    /// Returns the cleaned content title when non-empty + reasonable
    /// (≤ 200 chars), otherwise the cleaned filename.
    static func resolve(contentTitle: String?, filename: String) -> String {
        if let raw = contentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           raw.count <= 200 {
            return cleanLine(raw)
        }
        return cleanedFilename(filename)
    }

    /// MD title — first `# H1` (else first `## H2`). Operates on the
    /// raw markdown source. Stops the first time it sees a heading
    /// line. Returns nil if no heading exists in the first ~50 lines.
    static func fromMarkdown(plainText: String) -> String? {
        let lines = plainText.components(separatedBy: .newlines).prefix(50)
        // Pass 1: H1
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        // Pass 2: H2 fallback
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// HTML title — `<title>` element, falling back to the first
    /// `<h1>` text. Tolerant of whitespace and case. Reads from
    /// raw HTML bytes so it can use a quick regex instead of pulling
    /// in a full parser. **Bundle 2 follow-up (2026-05-26)** — strips
    /// the trailing site-name suffix that's nearly universal in real
    /// HTML title tags ("Foo | Project Gutenberg", "Bar - Wikipedia",
    /// "Baz – The New York Times"). The strip is conservative —
    /// only fires when the trailing chunk looks site-name-shaped.
    static func fromHTML(rawHTML: String) -> String? {
        // `<title>...</title>` is unique in well-formed HTML.
        if let m = rawHTML.range(of: #"<title[^>]*>([\s\S]*?)</title>"#,
                                 options: [.regularExpression, .caseInsensitive]) {
            let raw = String(rawHTML[m])
            let inner = raw
                .replacingOccurrences(of: #"<title[^>]*>"#, with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "</title>", with: "",
                                      options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty {
                return stripSiteSuffix(decodeHTMLEntities(inner))
            }
        }
        // First `<h1>` fallback — h1 rarely carries site-name suffix,
        // but we run the same stripper for consistency.
        if let m = rawHTML.range(of: #"<h1[^>]*>([\s\S]*?)</h1>"#,
                                 options: [.regularExpression, .caseInsensitive]) {
            let raw = String(rawHTML[m])
            let inner = raw
                .replacingOccurrences(of: #"<[^>]+>"#, with: "",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty {
                return stripSiteSuffix(decodeHTMLEntities(inner))
            }
        }
        return nil
    }

    /// **Bundle 2 follow-up (2026-05-26).** Strip the trailing
    /// `<sep> <site>` suffix from an HTML title where `<sep>` is one
    /// of `|`, `-`, `–` (en-dash), `—` (em-dash) padded with spaces,
    /// and `<site>` is "site-name-shaped":
    ///
    /// - ≤ 30 chars after trim
    /// - No terminal sentence punctuation (`.!?`)
    /// - Mostly alphabetic / spaces (≥ 60% letters)
    /// - 1–5 words
    ///
    /// Examples:
    /// - "Moby Dick; or The Whale | Project Gutenberg" → "Moby Dick;
    ///   or The Whale"
    /// - "Pride and Prejudice - Wikipedia" → "Pride and Prejudice"
    /// - "Article Title – The New York Times" → "Article Title"
    /// - "My Note - 2026-05-26" → unchanged (trailing chunk is
    ///   date-shaped, not site-shaped)
    /// - "Foo: A Bar - Baz" → "Foo: A Bar" (Baz is site-shaped)
    ///
    /// Conservative: prefers to leave the title alone when the
    /// trailing chunk doesn't clearly look like a site name.
    fileprivate static func stripSiteSuffix(_ title: String) -> String {
        // Search for the last separator. Walk from the end so a
        // title like "Foo | Bar - Site" strips just "Site".
        let separators = [" | ", " - ", " – ", " — "]
        var best: (sepRange: Range<String.Index>, tail: Substring)?
        for sep in separators {
            if let r = title.range(of: sep, options: .backwards) {
                let candidateTail = title[r.upperBound...]
                if best == nil || r.lowerBound > best!.sepRange.lowerBound {
                    best = (r, candidateTail)
                }
            }
        }
        guard let (sepRange, tail) = best else { return title }
        let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSiteNameShaped(trimmedTail) else { return title }
        let head = title[..<sepRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? title : head
    }

    private static func isSiteNameShaped(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 30 else { return false }
        // No terminal sentence punctuation.
        if let last = s.last, ".!?".contains(last) { return false }
        // Word count 1–5.
        let words = s.split(separator: " ")
        guard words.count >= 1, words.count <= 5 else { return false }
        // Mostly letters / spaces (≥ 60%). Reject mostly-digit tails
        // (dates, version numbers).
        let total = s.count
        let letters = s.filter { $0.isLetter }.count
        guard total > 0 else { return false }
        let letterRatio = Double(letters) / Double(total)
        return letterRatio >= 0.6
    }

    /// TXT title — handles three real-world patterns, in priority order:
    ///
    /// 1. **Legacy Gutenberg `Title: X` header** (older PG format, often
    ///    with `Author:` / `Release Date:` / `Language:` siblings).
    ///    Value can wrap onto indented continuation lines.
    /// 2. **Modern Gutenberg `*** START ***` + title-as-content** (the
    ///    real `02701_moby-dick.txt` shape). After the START marker,
    ///    the first 1–2 non-empty lines are the title (`MOBY-DICK;` /
    ///    `or, THE WHALE.`), terminated by `By <Author>` or `CHAPTER N`.
    /// 3. **Plain TXT with no Gutenberg structure** — first short
    ///    non-empty line, if it doesn't end with sentence punctuation.
    ///
    /// Returns nil when nothing reasonable is found; caller falls back
    /// to the cleaned filename. 2026-05-26 — added cases 2 + 3 after
    /// real-corpus verification surfaced that case 1 alone couldn't
    /// title actual Moby Dick TXT.
    static func fromTXT(plainText: String) -> String? {
        let allLines = plainText.components(separatedBy: .newlines)
        let lines = Array(allLines.prefix(200))

        // ── Case 1: legacy `Title:` header ──────────────────────────
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("title:") {
                var value = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    if next.first == " " || next.first == "\t" {
                        let cont = next.trimmingCharacters(in: .whitespaces)
                        if cont.isEmpty { break }
                        value += " " + cont
                        j += 1
                    } else { break }
                }
                if !value.isEmpty { return value }
            }
        }

        // ── Case 2: modern Gutenberg `*** START ***` + content ────
        // Skip Gutenberg metadata + the START marker, then collect
        // the first 1–2 non-empty short lines as the title (Moby's
        // real shape: "MOBY-DICK;" / blank / "or, THE WHALE.").
        // Stop at `By <Author>` / `Author:` / `CHAPTER N` / next
        // `*** ` marker / a long prose line.
        func isGutenbergMetadata(_ trimmed: String, _ lower: String) -> Bool {
            return trimmed.hasPrefix("***")
                || lower.hasPrefix("the project gutenberg")
                || lower.hasPrefix("project gutenberg")
                || lower.hasPrefix("this ebook is")
                || lower.hasPrefix("release date:")
                || lower.hasPrefix("language:")
                || lower.hasPrefix("character set")
                || lower.hasPrefix("posting date:")
                || lower.hasPrefix("most recently updated:")
                || lower.hasPrefix("produced by")
                || lower.hasPrefix("credits:")
                || lower.hasPrefix("ebook designed and")
        }
        func isTitleStopMarker(_ lower: String) -> Bool {
            return lower.hasPrefix("by ")
                || lower.hasPrefix("author:")
                || lower.hasPrefix("chapter ")
                || lower.hasPrefix("contents")
                || lower.hasPrefix("etymology")
                || lower.hasPrefix("foreword")
                || lower.hasPrefix("preface")
                || lower.hasPrefix("introduction")
                || lower.hasPrefix("dedication")
        }

        var idx = 0
        // Skip leading Gutenberg metadata + blanks.
        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isGutenbergMetadata(trimmed, trimmed.lowercased()) {
                idx += 1
                continue
            }
            break
        }
        // Collect title pieces. Allow blank lines between pieces; stop
        // at stop-markers, secondary `***`, or a prose-shaped long line.
        var titleParts: [String] = []
        var nonBlankSeen = 0
        while idx < lines.count && nonBlankSeen < 4 {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            idx += 1
            if trimmed.isEmpty { continue }
            nonBlankSeen += 1
            let lower = trimmed.lowercased()
            if isTitleStopMarker(lower) || trimmed.hasPrefix("***") { break }
            if trimmed.count > 100 { break }
            titleParts.append(trimmed)
        }
        if !titleParts.isEmpty {
            // Join with " ", strip trailing `.` only — preserve
            // semicolons / commas internal to the title (Moby's
            // "MOBY-DICK; or, THE WHALE.").
            let joined = titleParts.joined(separator: " ")
            return joined
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }

        // ── Case 3: plain TXT — first short line as fallback ──────
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.count > 120 { return nil }
            if let last = trimmed.last, ".!?".contains(last) { return nil }
            return trimmed
        }
        return nil
    }

    // MARK: - Private helpers

    /// Single-line, single-space, trim. Doesn't touch case.
    private static func cleanLine(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Minimal HTML entity decode for the entities most commonly
    /// found in <title> / <h1> content. Full decode would require
    /// a real parser; this covers the high-value cases.
    private static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        let pairs: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&nbsp;", " ")
        ]
        for (entity, replacement) in pairs {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }
}

// ========== BLOCK 01: TITLE EXTRACTOR - END ==========
