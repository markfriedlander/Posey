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
    /// in a full parser.
    static func fromHTML(rawHTML: String) -> String? {
        // `<title>...</title>` is unique in well-formed HTML.
        if let m = rawHTML.range(of: #"<title[^>]*>([\s\S]*?)</title>"#,
                                 options: [.regularExpression, .caseInsensitive]) {
            let raw = String(rawHTML[m])
            // Strip the opening + closing tags.
            let inner = raw
                .replacingOccurrences(of: #"<title[^>]*>"#, with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "</title>", with: "",
                                      options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { return decodeHTMLEntities(inner) }
        }
        // First `<h1>` fallback.
        if let m = rawHTML.range(of: #"<h1[^>]*>([\s\S]*?)</h1>"#,
                                 options: [.regularExpression, .caseInsensitive]) {
            let raw = String(rawHTML[m])
            let inner = raw
                .replacingOccurrences(of: #"<[^>]+>"#, with: "",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { return decodeHTMLEntities(inner) }
        }
        return nil
    }

    /// TXT title — Gutenberg-style `Title: X` header line first, else
    /// the first non-empty line if it's "title-shaped" (≤ 120 chars,
    /// not terminal punctuation). Many text files start with metadata
    /// or boilerplate that isn't a title; we err on the conservative
    /// side and return nil rather than mistitle.
    static func fromTXT(plainText: String) -> String? {
        // Gutenberg header detection: scan first 200 lines for
        // `Title: <X>`. Case-insensitive prefix match; the value can
        // wrap onto subsequent lines indented with whitespace.
        let lines = plainText.components(separatedBy: .newlines).prefix(200)
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("title:") {
                var value = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                // Continuation lines (indented in the original).
                var j = i + 1
                while j < lines.count {
                    let next = lines[lines.index(lines.startIndex, offsetBy: j)]
                    if next.first == " " || next.first == "\t" {
                        let cont = next.trimmingCharacters(in: .whitespaces)
                        if cont.isEmpty { break }
                        value += " " + cont
                        j += 1
                    } else { break }
                }
                return value.isEmpty ? nil : value
            }
        }
        // Fall back to first non-empty line.
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.count > 120 { return nil }
            // Avoid mistaking a sentence for a title.
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
