import Foundation

struct ParsedMarkdownDocument {
    let displayText: String
    let plainText: String
    let blocks: [DisplayBlock]
}

struct MarkdownParser {
    private enum LineKind {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case numbered(marker: String, text: String)
        case quote(text: String)
        case paragraph(text: String)
        case blank
        /// 2026-05-22 — A markdown horizontal-rule line. Matches a
        /// standalone line of three-or-more `-`, `*`, or `_` characters
        /// (commonmark §4.1). Rendered as a thin centered separator and
        /// excluded from plainText / TTS.
        case horizontalRule
    }

    func parse(markdown source: String) -> ParsedMarkdownDocument {
        let normalizedSource = normalizeSource(source)
        guard normalizedSource.isEmpty == false else {
            return ParsedMarkdownDocument(displayText: "", plainText: "", blocks: [])
        }

        let lines = normalizedSource.components(separatedBy: "\n")
        var blocks: [DisplayBlock] = []
        var plainTextParts: [String] = []
        var offset = 0
        var paragraphBuffer: [String] = []
        var quoteBuffer: [String] = []

        func flushParagraphBuffer() {
            guard paragraphBuffer.isEmpty == false else { return }
            let text = paragraphBuffer.joined(separator: " ")
            appendBlock(kind: .paragraph, text: text)
            paragraphBuffer.removeAll()
        }

        func flushQuoteBuffer() {
            guard quoteBuffer.isEmpty == false else { return }
            let text = quoteBuffer.joined(separator: " ")
            appendBlock(kind: .quote, text: text)
            quoteBuffer.removeAll()
        }

        /// 2026-05-22 — Append a horizontal-rule block. Holds an empty
        /// text and contributes nothing to `plainText` / `plainTextParts`
        /// so TTS passes through silently. Renderer special-cases
        /// `.horizontalRule` like it does `.visualPlaceholder`. The
        /// block's startOffset == endOffset == the current cumulative
        /// plainText length, so positions of subsequent blocks remain
        /// consistent with the un-ruled flow.
        func appendHorizontalRuleBlock() {
            blocks.append(
                DisplayBlock(
                    id: blocks.count,
                    kind: .horizontalRule,
                    text: "",
                    displayPrefix: nil,
                    startOffset: offset,
                    endOffset: offset
                )
            )
        }

        func appendBlock(kind: DisplayBlockKind, text: String, displayPrefix: String? = nil) {
            let cleaned = cleanInlineMarkdown(text)
            guard cleaned.isEmpty == false else { return }

            let separatorLength = plainTextParts.isEmpty ? 0 : 2
            if separatorLength > 0 {
                offset += separatorLength
            }

            let startOffset = offset
            let endOffset = startOffset + cleaned.count
            blocks.append(
                DisplayBlock(
                    id: blocks.count,
                    kind: kind,
                    text: cleaned,
                    displayPrefix: displayPrefix,
                    startOffset: startOffset,
                    endOffset: endOffset
                )
            )
            plainTextParts.append(cleaned)
            offset = endOffset
        }

        for line in lines {
            // 2026-06-04 — Setext heading support (CommonMark §4.3).
            // A line of only `=` (→ H1) or only `-` (→ H2) that immediately
            // follows an OPEN paragraph buffer is a setext underline: the
            // buffered text IS the heading. We intercept here, BEFORE
            // classify(), because otherwise:
            //   • a `===` run falls through to .paragraph and leaks into the
            //     body text (the exact bug md_setext-headings.md caught), and
            //   • a `---`/`***`/`___` run classifies as .horizontalRule,
            //     leaving the title line above it as plain prose (no heading,
            //     so no TOC entry).
            // Disambiguation — the `---` ambiguity: a dash run is a setext H2
            // underline ONLY when it underlines a non-empty text line
            // (paragraphBuffer non-empty). A dash run surrounded by blanks
            // (paragraphBuffer empty) falls through to classify() and stays a
            // thematic break / horizontal rule. `=` has no thematic-break
            // meaning, so a bare `===` with no open paragraph is just text.
            // Category (Rule 10): all .md/.markdown — Gutenberg- and
            // pandoc-derived files routinely use setext. Multi-line heading
            // text is joined like a paragraph. ATX (`#…`) is unaffected
            // (matched first in classify); standalone HRs and the Dracula TXT
            // path (TXTLibraryImporter, not this parser) are unaffected.
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if let level = setextUnderlineLevel(trimmedLine),
               paragraphBuffer.isEmpty == false {
                let headingText = paragraphBuffer.joined(separator: " ")
                paragraphBuffer.removeAll()
                flushQuoteBuffer()
                appendBlock(kind: .heading(level: level), text: headingText)
                continue
            }
            switch classify(line: line) {
            case .blank:
                flushParagraphBuffer()
                flushQuoteBuffer()
            case .heading(let level, let text):
                flushParagraphBuffer()
                flushQuoteBuffer()
                appendBlock(kind: .heading(level: level), text: text)
            case .bullet(let text):
                flushParagraphBuffer()
                flushQuoteBuffer()
                appendBlock(kind: .bullet, text: text, displayPrefix: "•")
            case .numbered(let marker, let text):
                flushParagraphBuffer()
                flushQuoteBuffer()
                appendBlock(kind: .numbered, text: text, displayPrefix: marker)
            case .quote(let text):
                flushParagraphBuffer()
                quoteBuffer.append(text)
            case .paragraph(let text):
                flushQuoteBuffer()
                paragraphBuffer.append(text)
            case .horizontalRule:
                flushParagraphBuffer()
                flushQuoteBuffer()
                appendHorizontalRuleBlock()
            }
        }

        flushParagraphBuffer()
        flushQuoteBuffer()

        return ParsedMarkdownDocument(
            displayText: normalizedSource,
            plainText: plainTextParts.joined(separator: "\n\n"),
            blocks: blocks
        )
    }

    private func classify(line: String) -> LineKind {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false else {
            return .blank
        }

        if let heading = match(in: trimmed, pattern: #"^(#{1,6})\s+(.*)$"#) {
            return .heading(level: heading.0.count, text: heading.1)
        }

        // 2026-05-22 — Horizontal rule. CommonMark §4.1: a line of
        // three-or-more matching `-`, `*`, or `_` characters, with
        // optional spaces between (already trimmed away here). Must
        // be a homogeneous run — `--*` doesn't qualify.
        if let regex = try? NSRegularExpression(pattern: #"^(-{3,}|\*{3,}|_{3,})$"#),
           regex.firstMatch(in: trimmed,
                            range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return .horizontalRule
        }

        if let bullet = match(in: trimmed, pattern: #"^[-*+]\s+(.*)$"#) {
            return .bullet(text: bullet.1)
        }

        if let numbered = match(in: trimmed, pattern: #"^(\d+)[\.\)]\s+(.*)$"#) {
            return .numbered(marker: "\(numbered.0).", text: numbered.1)
        }

        if let quote = match(in: trimmed, pattern: #"^>\s?(.*)$"#) {
            return .quote(text: quote.1)
        }

        return .paragraph(text: trimmed)
    }

    /// 2026-06-04 — Setext underline shape-test (CommonMark §4.3).
    /// Returns the heading level when `trimmed` is a setext underline
    /// candidate — a line made up of one-or-more identical underline
    /// characters and nothing else: all `=` → level 1 (H1), all `-` →
    /// level 2 (H2). Returns nil otherwise. This is PURELY the shape
    /// test; the caller decides whether it actually promotes a heading
    /// (only when it underlines an open paragraph) vs. stays a thematic
    /// break / plain text. A single `-`/`=` qualifies — setext underlines
    /// have no minimum length, unlike the 3+-char thematic-rule test in
    /// classify(). `trimmed` is already whitespace-trimmed, so an
    /// underline with internal spaces (e.g. `- - -`) fails allSatisfy and
    /// is left to classify() (where it reads as a bullet, as before).
    private func setextUnderlineLevel(_ trimmed: String) -> Int? {
        guard trimmed.isEmpty == false else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private func match(in text: String, pattern: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        guard result.numberOfRanges >= 2 else {
            return nil
        }

        let first = Range(result.range(at: 1), in: text).map { String(text[$0]) } ?? ""
        let second = Range(result.range(at: min(2, result.numberOfRanges - 1)), in: text).map { String(text[$0]) } ?? ""
        return (first, second)
    }

    private func normalizeSource(_ source: String) -> String {
        // Strip BOM, soft hyphens, ZWSP, and convert NBSP to space before
        // parsing. The Markdown structure is preserved (newlines, headings,
        // lists) but invisible characters that have no place in spoken
        // text are removed up front. CRLF / CR normalization runs after
        // so the parser's line-based logic still works.
        var t = source
        t = TextNormalizer.stripBOM(t)
        t = TextNormalizer.stripMojibakeAndControlCharacters(t)
        t = TextNormalizer.stripInvisibleCharacters(t)
        t = TextNormalizer.normalizeLineEndings(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanInlineMarkdown(_ text: String) -> String {
        var cleaned = text
        let replacements: [(String, String)] = [
            (#"`([^`]*)`"#, "$1"),
            (#"\*\*([^*]+)\*\*"#, "$1"),
            (#"__([^_]+)__"#, "$1"),
            (#"\*([^*]+)\*"#, "$1"),
            (#"_([^_]+)_"#, "$1"),
            (#"!\[([^\]]*)\]\([^)]+\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            (#"<([^>]+)>"#, "$1")
        ]

        for (pattern, template) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: template)
            }
        }

        return cleaned
            .replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!>])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
