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
        // 2026-06-11 (auditor ruling ii) — collect the labels of link reference
        // definitions we will CONSUME, so cleanInlineMarkdown can unwrap the
        // matching inline reference links ([label] / [text][label]) and NOT
        // leave dangling bracket junk. GUARD: only labels with a real consumed
        // def are unwrapped, so [1] / [sic] / [citation needed] / [^1] (no def)
        // stay untouched. Fence-aware so a def shown INSIDE a code example isn't
        // collected. Labels normalized per CommonMark (case-fold + ws-collapse).
        let consumedRefLabels = collectLinkRefLabels(lines)
        var blocks: [DisplayBlock] = []
        var plainTextParts: [String] = []
        var offset = 0
        var paragraphBuffer: [String] = []
        var quoteBuffer: [String] = []
        // 2026-06-11 — fenced-code-block state (CommonMark §4.5). When a fence
        // opens, every line until the matching close is buffered VERBATIM (no
        // classify(), no inline-markdown stripping) so code keeps its newlines,
        // indentation, and literal `#`/`-`/`>` characters instead of leaking as
        // headings/bullets/quotes. Tracks the fence char + run length so the
        // close must match (same char, length ≥ open).
        var inCodeBlock = false
        var codeBuffer: [String] = []
        var codeFenceChar: Character = "`"
        var codeFenceLen = 3

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
            // 2026-06-08 (normalizer-parity pass): after stripping inline
            // markdown syntax (which already removes `_Mem._` → `Mem.`), route
            // the block text through the single shared `normalizeUniversal` so
            // Markdown gets the SAME universal cleanup as every other format
            // (CP1252 mojibake repair, mojibake/control/PUA strip, BOM +
            // invisible-char strip) — previously absent for MD. Applied here,
            // BEFORE the offset computation below, so block offsets stay exact.
            // hardWrapped:false (cleanInlineMarkdown already collapsed the
            // block to a single line); stripGutenbergItalics is a safe no-op
            // (the parser removed the underscores already).
            let cleaned = TextNormalizer.normalizeUniversal(
                cleanInlineMarkdown(text, refLabels: consumedRefLabels))
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

        // 2026-06-11 — Emit the buffered fenced-code lines as ONE `.code` block,
        // VERBATIM: no cleanInlineMarkdown (that strips backticks + collapses all
        // whitespace to single spaces, destroying code) and no normalizeUniversal
        // line-collapse — newlines + indentation are preserved. The source was
        // already BOM/mojibake/control/line-ending normalized by normalizeSource,
        // so the buffered lines are safe to append as-is. Offset math mirrors
        // appendBlock (2-char "\n\n" join separator) so block offsets stay
        // consistent with the unit-join coordinate space the persister uses.
        func flushCodeBuffer() {
            inCodeBlock = false
            var codeLines = codeBuffer
            codeBuffer.removeAll()
            // Trim only fully-blank leading/trailing lines; keep internal blanks
            // and every line's indentation.
            while let first = codeLines.first,
                  first.trimmingCharacters(in: .whitespaces).isEmpty { codeLines.removeFirst() }
            while let last = codeLines.last,
                  last.trimmingCharacters(in: .whitespaces).isEmpty { codeLines.removeLast() }
            let code = codeLines.joined(separator: "\n")
            guard code.isEmpty == false else { return }
            let separatorLength = plainTextParts.isEmpty ? 0 : 2
            if separatorLength > 0 { offset += separatorLength }
            let startOffset = offset
            let endOffset = startOffset + code.count
            blocks.append(
                DisplayBlock(
                    id: blocks.count,
                    kind: .code,
                    text: code,
                    displayPrefix: nil,
                    startOffset: startOffset,
                    endOffset: endOffset
                )
            )
            plainTextParts.append(code)
            offset = endOffset
        }

        for line in lines {
            // 2026-06-11 — Fenced code blocks (CommonMark §4.5) take priority over
            // every other line rule: inside a fence every line is literal. The
            // opening fence + its language-info string and the closing fence are
            // dropped (not shown, not spoken); the body is buffered verbatim and
            // flushed as one `.code` block. An unterminated fence (no closing
            // line before EOF) is flushed after the loop — lenient, matching how
            // real-world docs sometimes omit the closing fence.
            if inCodeBlock {
                if isClosingFence(line, fenceChar: codeFenceChar, minLength: codeFenceLen) {
                    flushCodeBuffer()
                } else {
                    codeBuffer.append(line)   // RAW — preserve indentation
                }
                continue
            }
            if let (ch, len) = openingFence(line) {
                flushParagraphBuffer()
                flushQuoteBuffer()
                inCodeBlock = true
                codeFenceChar = ch
                codeFenceLen = len
                continue   // drop the opening fence + info string
            }
            // 2026-06-11 (auditor ruling) — CONSUME link reference definitions
            // (CommonMark §4.7): `[label]: <url> "title"`. These are invisible
            // link TARGETS referenced elsewhere by `[text][label]`; CommonMark
            // never renders them, so emitting them as body text is a fidelity
            // defect. Generalizes across the whole MD corpus (well-written
            // READMEs lean on reference links), not pandoc-only. Guarded by a
            // URL-ish RHS so it can't eat legitimate prose like "[note]: a
            // remark." DEFERRED [DECISION] (auditor): 4-space INDENTED code
            // blocks (CommonMark §4.4) are NOT handled here — disambiguating a
            // 4-space indent from nested-list continuation needs real list-
            // context tracking, and getting it wrong breaks nested lists (worse
            // than the leak). Modern docs use fenced code; indented code is
            // exercised mainly by pandoc-the-manual's syntax examples. Handle in
            // a dedicated later pass; until then a rare indented-code example may
            // reflow as prose (documented known-limitation).
            if isLinkReferenceDefinition(line) {
                flushParagraphBuffer()
                flushQuoteBuffer()
                continue
            }
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

        if inCodeBlock { flushCodeBuffer() }   // unterminated fence at EOF
        flushParagraphBuffer()
        flushQuoteBuffer()

        return ParsedMarkdownDocument(
            displayText: normalizedSource,
            plainText: plainTextParts.joined(separator: "\n\n"),
            blocks: blocks
        )
    }

    /// 2026-06-11 — Opening code fence (CommonMark §4.5): up to 3 leading
    /// spaces, then a run of ≥3 backticks OR ≥3 tildes, then an optional
    /// info string. Returns (fenceChar, runLength) or nil. A backtick info
    /// string may not contain a backtick (CommonMark) — but we drop the info
    /// string entirely either way, so we don't enforce that here.
    private func openingFence(_ line: String) -> (Character, Int)? {
        let trimmed = line.drop(while: { $0 == " " })
        // Reject >3 spaces of indent (that'd be an indented code block, a
        // different construct we don't open a fence for).
        guard line.count - trimmed.count <= 3 else { return nil }
        for fence: Character in ["`", "~"] {
            let run = trimmed.prefix(while: { $0 == fence }).count
            if run >= 3 {
                // For backtick fences the info string must not contain a
                // backtick; if it does, this isn't a code fence (it's inline).
                let rest = trimmed.dropFirst(run)
                if fence == "`" && rest.contains("`") { return nil }
                return (fence, run)
            }
        }
        return nil
    }

    /// 2026-06-11 — Link reference definition (CommonMark §4.7):
    /// `[label]: destination "optional title"`, up to 3 leading spaces. Returns
    /// the NORMALIZED label when the line is a definition with a URL-ish
    /// destination (scheme://, mailto:, angle-bracket `<…>`, root-relative
    /// `/path`, or `domain.tld`), else nil — so a prose line like
    /// `[note]: a quick remark.` is NOT mistaken for a definition.
    private func linkRefDefLabel(_ line: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^ {0,3}\[([^\]]+)\]:[ \t]+(\S+)"#) else { return nil }
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 3 else { return nil }
        let rhs = ns.substring(with: m.range(at: 2))
        let urlish = rhs.contains("://") || rhs.hasPrefix("mailto:") || rhs.hasPrefix("/")
            || rhs.hasPrefix("<")
            || rhs.range(of: #"^[\w.-]+\.[a-z]{2,}"#,
                         options: [.regularExpression, .caseInsensitive]) != nil
        guard urlish else { return nil }
        return normalizeLabel(ns.substring(with: m.range(at: 1)))
    }

    private func isLinkReferenceDefinition(_ line: String) -> Bool {
        return linkRefDefLabel(line) != nil
    }

    /// CommonMark label matching: case-fold + collapse internal whitespace + trim.
    private func normalizeLabel(_ s: String) -> String {
        return s.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 2026-06-11 (auditor ruling ii) — pre-pass: the set of labels whose link
    /// reference definition we consume. Fence-aware (a def shown inside a code
    /// example is literal content, not a real def, so it isn't collected).
    private func collectLinkRefLabels(_ lines: [String]) -> Set<String> {
        var labels: Set<String> = []
        var inFence = false
        var fenceChar: Character = "`"
        var fenceLen = 3
        for line in lines {
            if inFence {
                if isClosingFence(line, fenceChar: fenceChar, minLength: fenceLen) { inFence = false }
                continue
            }
            if let (ch, len) = openingFence(line) { inFence = true; fenceChar = ch; fenceLen = len; continue }
            if let label = linkRefDefLabel(line) { labels.insert(label) }
        }
        return labels
    }

    /// 2026-06-11 (auditor ruling ii) — unwrap inline reference links whose
    /// definition we consumed, leaving dangling bracket junk behind otherwise.
    /// Full/collapsed ref `[text][label]` / `[text][]` → `text`; shortcut ref
    /// `[label]` → `label`. GUARDED: only when the (normalized) label is in the
    /// consumed-def set, so `[1]` / `[sic]` / `[citation needed]` / `[^1]` —
    /// which have no def — are left intact. Inline links `[text](url)` and
    /// images `![alt](url)` are already unwrapped earlier in cleanInlineMarkdown,
    /// so the bracket patterns here only see reference-style links.
    private func unwrapConsumedRefLinks(_ text: String, labels: Set<String>) -> String {
        guard !labels.isEmpty, text.contains("[") else { return text }
        var s = text
        // Full / collapsed reference links FIRST (so the shortcut pass doesn't
        // mis-split `[text][label]`). Inner brackets disallowed to stay simple.
        s = replaceGuardedBrackets(s, pattern: #"\[([^\]\[]+)\]\[([^\]\[]*)\]"#) { groups in
            let textPart = groups[1]
            let label = groups[2].isEmpty ? textPart : groups[2]
            return labels.contains(normalizeLabel(label)) ? textPart : nil
        }
        // Shortcut reference links.
        s = replaceGuardedBrackets(s, pattern: #"\[([^\]\[]+)\]"#) { groups in
            let label = groups[1]
            return labels.contains(normalizeLabel(label)) ? label : nil
        }
        return s
    }

    /// Enumerate regex matches LAST-to-FIRST (so replacement ranges stay valid)
    /// and replace each only when `replacement` returns non-nil for its capture
    /// groups (group 0 = whole match, 1.. = captures).
    private func replaceGuardedBrackets(
        _ text: String, pattern: String,
        _ replacement: ([String]) -> String?
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = NSMutableString(string: text)
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            if let rep = replacement(groups) {
                ns.replaceCharacters(in: m.range, with: rep)
            }
        }
        return ns as String
    }

    /// Closing code fence: ≤3 leading spaces, then a run of the SAME fence
    /// char with length ≥ the opening run, then only whitespace.
    private func isClosingFence(_ line: String, fenceChar: Character, minLength: Int) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3 else { return false }
        let run = trimmed.prefix(while: { $0 == fenceChar }).count
        guard run >= minLength else { return false }
        return trimmed.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private func classify(line: String) -> LineKind {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false else {
            return .blank
        }

        if let heading = match(in: trimmed, pattern: #"^(#{1,6})\s+(.*)$"#) {
            // 2026-06-11 — strip the OPTIONAL closing hash sequence of an ATX
            // heading (CommonMark §4.2): "### Title ###" → "Title". The closing
            // #s must be preceded by a space and followed only by spaces, so a
            // trailing "#1" (e.g. "Heading #1") or a mid-text "C# basics" is left
            // intact. pandoc-the-manual uses the closed form ("Fenced code blocks ###").
            let title = heading.1.replacingOccurrences(
                of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            return .heading(level: heading.0.count, text: title)
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

    private func cleanInlineMarkdown(_ text: String, refLabels: Set<String> = []) -> String {
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

        // 2026-06-11 (auditor ruling ii) — unwrap inline reference links whose
        // definition was consumed (runs AFTER inline-link `[text](url)` removal
        // above, so it only sees reference-style brackets). Guarded by the
        // consumed-def set so `[1]`/`[sic]` are untouched.
        cleaned = unwrapConsumedRefLinks(cleaned, labels: refLabels)

        return cleaned
            .replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!>])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
