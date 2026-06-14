import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// ========== BLOCK 1: TYPES + ERRORS - START ==========
struct RTFDocumentImporter {
    enum ImportError: LocalizedError, Equatable {
        case unreadableDocument
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "Posey could not read that RTF file."
            case .emptyDocument:
                return "The RTF file is empty."
            }
        }
    }

    /// Heading-styled paragraph extracted from RTF font attributes.
    /// Level 1 is the most prominent (largest font tier).
    struct RTFHeadingEntry {
        let level: Int
        let title: String
        let plainTextOffset: Int
    }

    struct RTFParsedDocument {
        let plainText: String
        let headings: [RTFHeadingEntry]
        /// 2026-06-09 (#2 RTF images) — `plainText` with inline
        /// `[[POSEY_VISUAL_PAGE:0:<uuid>]]` markers spliced in at each
        /// embedded image's position (located via the extractor's
        /// preceding-text needle). Equals `plainText` when the RTF has no
        /// decodable images. The library importer runs this through
        /// `VisualPlaceholderSplitter` to interleave `.image` units, exactly
        /// like DOCX/EPUB/HTML.
        let displayText: String
        /// Decoded embedded images (`\pngblip` / `\jpegblip`), in document
        /// order, ready for `DatabaseManager.insertImage`. Empty when none.
        let images: [PageImageRecord]
    }
}
// ========== BLOCK 1: TYPES + ERRORS - END ==========

// ========== BLOCK 2: PUBLIC LOAD ENTRYPOINTS - START ==========
extension RTFDocumentImporter {
    func loadText(from url: URL) throws -> String {
        try loadDocument(from: url).plainText
    }

    func loadText(fromData data: Data) throws -> String {
        try loadDocument(fromData: data).plainText
    }

    func loadDocument(from url: URL) throws -> RTFParsedDocument {
        let data = try Data(contentsOf: url)
        return try loadDocument(fromData: data)
    }

    /// Load the RTF and return both normalized plaintext and a list of
    /// heading-styled paragraphs detected from the raw `\fs`/`\b` markers.
    ///
    /// We use NSAttributedString to extract clean plaintext (it does this
    /// reliably on iOS) but parse the raw RTF directly for heading
    /// classification — iOS NSAttributedString does NOT preserve `.font`
    /// attribute spans from RTF the way macOS does (verified: iOS yields
    /// one no-font span; macOS yields per-style spans). The native font
    /// table thus can't be inspected on iOS, so we tokenize RTF directly.
    func loadDocument(fromData data: Data) throws -> RTFParsedDocument {
        // 2026-06-14 (RTF c3 fidelity fix) — sanitize raw UTF-8 bytes BEFORE
        // NSAttributedString. Apple's RTF reader silently DROPS a span of text
        // when an `\ansi` RTF embeds raw UTF-8 bytes instead of the spec's
        // `\uN`/`\'xx` escapes (the high bytes desync its byte/char counter).
        // No-op on well-formed RTF (no raw high bytes → returns input
        // unchanged). See `sanitizeRawUTF8Bytes`.
        let cleanData = Self.sanitizeRawUTF8Bytes(data)
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(
                data: cleanData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        } catch {
            throw ImportError.unreadableDocument
        }

        let normalized = normalize(attributed.string)
        guard !normalized.isEmpty else { throw ImportError.emptyDocument }

        let rawParagraphs = RTFRawTokenizer.parseParagraphs(data: data)
        let rawHeadings = detectHeadings(rawParagraphs: rawParagraphs)
        let headings = mapHeadingsToNormalizedOffsets(rawHeadings, in: normalized)

        // 2026-06-09 (#2 RTF images) — extract embedded `\pict` blips and
        // splice their markers into a displayText built from the SAME
        // normalized plainText, so the units coordinate stays consistent
        // (markers contribute 0 chars to plainText; image units are skipped
        // by applyHeadingMarkers' offset cursor — see buildDisplayText).
        let extractedImages = RTFImageExtractor.extract(from: data)
        let (displayText, usedImages) = Self.buildDisplayText(
            plainText: normalized,
            images: extractedImages
        )

        return RTFParsedDocument(
            plainText: normalized,
            headings: headings,
            displayText: displayText,
            images: usedImages
        )
    }
}
// ========== BLOCK 2: PUBLIC LOAD ENTRYPOINTS - END ==========

// ========== BLOCK 3: HEADING DETECTION - START ==========
fileprivate struct RTFRawHeading {
    let title: String
    let pointSize: Int      // half-points (RTF native unit)
    let isBold: Bool
}

extension RTFDocumentImporter {
    /// Classify each paragraph against a body-text baseline (modal font
    /// size). Headings = font size at least 15% above body.
    fileprivate func detectHeadings(rawParagraphs: [RTFRawTokenizer.Paragraph]) -> [RTFRawHeading] {
        guard !rawParagraphs.isEmpty else { return [] }

        var sizeCounts: [Int: Int] = [:]
        for p in rawParagraphs {
            sizeCounts[p.fontSize, default: 0] += p.text.count
        }
        let bodySize = sizeCounts.max(by: { $0.value < $1.value })?.key ?? 24

        var candidates: [RTFRawHeading] = []
        for p in rawParagraphs {
            let trimmed = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 200 else { continue }

            // Headings are reliably tagged by font size in Word RTFs.
            // We avoid a bold-only fallback because Word frequently marks
            // body text as bold via style references our tokenizer
            // doesn't resolve, which floods candidates.
            let ratio = Double(p.fontSize) / Double(bodySize)
            guard ratio >= 1.15 else { continue }
            candidates.append(RTFRawHeading(title: trimmed, pointSize: p.fontSize, isBold: p.bold))
        }

        // Floods of "headings" mean the document isn't structurally styled.
        let cap = max(50, rawParagraphs.count / 4)
        if candidates.count > cap { return [] }
        return candidates
    }
}
// ========== BLOCK 3: HEADING DETECTION - END ==========

// ========== BLOCK 4: OFFSET MAPPING + NORMALIZATION - START ==========
extension RTFDocumentImporter {
    /// Map raw heading paragraphs → normalized-text offsets.
    /// Forward-only search keeps duplicate titles in source order.
    /// Levels 1-3 assigned by font-size tier (largest → 1).
    ///
    /// 2026-05-07 (parity #6 closure): when a "Table of Contents" /
    /// "Contents" heading is detected, advance the search cursor PAST
    /// the contiguous dot-leader region after it before resuming the
    /// search. Without this, subsequent chapter-heading titles get
    /// matched to the dot-leader text inside the TOC ("Chapter One
    /// ........ 5") instead of the actual chapter heading later in
    /// the document, breaking both TOC navigation and playback skip.
    fileprivate func mapHeadingsToNormalizedOffsets(_ raw: [RTFRawHeading],
                                                    in normalized: String) -> [RTFHeadingEntry] {
        let sizes = Set(raw.map { $0.pointSize }).sorted(by: >)
        let topThree = Array(sizes.prefix(3))

        var out: [RTFHeadingEntry] = []
        var searchFrom = normalized.startIndex
        for h in raw {
            // Use a coarse needle: first ~40 chars of the trimmed title,
            // normalized the same way as the plaintext. The raw RTF
            // tokenizer is best-effort on unicode escapes, so titles may
            // differ slightly from NSAttributedString's clean output —
            // a prefix match tolerates this.
            let needleFull = normalize(h.title).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needleFull.isEmpty else { continue }
            let needle = String(needleFull.prefix(40))

            var foundRange = normalized.range(of: needle, range: searchFrom..<normalized.endIndex)
            if foundRange == nil {
                // 2026-06-04 — Fallback for titles with non-ASCII characters.
                // The raw RTF tokenizer reads via ISO-Latin1 while the plaintext
                // comes from NSAttributedString (Windows-1252) — and on an RTF
                // with raw-UTF-8 bytes those two decode a curly apostrophe /
                // accent DIFFERENTLY (needle "…Harkerâs" vs plaintext
                // "…Harker's"), so the exact needle never matches and the
                // heading is silently dropped from the TOC (its offset map
                // entry is missing). Retry with the title's ASCII-only PREFIX,
                // which is decode-independent. ≥8 chars keeps it unique enough.
                let asciiPrefix = String(needleFull.prefix(while: { $0.isASCII }))
                    .trimmingCharacters(in: .whitespaces)
                if asciiPrefix.count >= 8 {
                    foundRange = normalized.range(of: asciiPrefix, range: searchFrom..<normalized.endIndex)
                }
            }
            guard let range = foundRange else { continue }
            let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
            let level = (topThree.firstIndex(of: h.pointSize) ?? 2) + 1
            // 2026-06-04 — Title the TOC entry from the CLEAN normalized
            // plaintext line at the matched offset, not from `needleFull`: the
            // raw-tokenizer needle can carry residual mojibake ("Harkerâs") that
            // the NSAttributedString plaintext doesn't, so using it would show a
            // garbled TOC title. The plaintext line is the user-facing truth.
            let lineEnd = normalized.range(of: "\n", range: range.lowerBound..<normalized.endIndex)?.lowerBound
                ?? normalized.endIndex
            let cleanTitle = String(normalized[range.lowerBound..<lineEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(RTFHeadingEntry(level: level,
                                       title: cleanTitle.isEmpty ? needleFull : cleanTitle,
                                       plainTextOffset: offset))
            searchFrom = range.upperBound

            // 2026-05-07 (parity #6 closure): always advance past
            // any dot-leader-pattern lines that follow a heading
            // match. Real RTFs with a hand-typed TOC list often have
            // it appear right after the doc title (no separate
            // "Contents" heading) — the dot-leader entries would
            // otherwise shadow the actual chapter headings later in
            // the document. The advance only consumes lines that
            // ARE dot-leader pattern; non-dot-leader content stops
            // the walker, so this is safe for docs without TOCs.
            searchFrom = advancePastDotLeaderRegion(from: searchFrom, in: normalized)
        }
        return out
    }

    /// Walk forward through `normalized` from `cursor`, line-by-line
    /// (single `\n`), skipping any dot-leader-pattern lines. Returns
    /// the index of the first non-dot-leader, non-empty line.
    fileprivate func advancePastDotLeaderRegion(
        from cursor: String.Index,
        in normalized: String
    ) -> String.Index {
        // 2026-05-22 — Tightened from `[ .]{3,}` to `\.{4,}` for the
        // same false-positive class TOCSkipDetector hit (see that file
        // for the worked example with GEB's dialogue typography).
        // Dialogue ellipses like " . . . " no longer get treated as
        // dot leaders; real Word/Pages dot leaders have 4+ consecutive
        // period chars.
        guard let dotLeader = try? NSRegularExpression(pattern: #"^.+?(?:\t+|\.{4,})\s*\d+\s*$"#) else {
            return cursor
        }
        var idx = cursor
        while idx < normalized.endIndex {
            let lineEnd = normalized.range(of: "\n", range: idx..<normalized.endIndex)?.lowerBound
                ?? normalized.endIndex
            let line = String(normalized[idx..<lineEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                // Skip empty lines and keep walking.
                idx = lineEnd < normalized.endIndex
                    ? normalized.index(after: lineEnd) : lineEnd
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            if dotLeader.firstMatch(in: line, range: range) == nil {
                // First non-dot-leader, non-empty line — stop here.
                return idx
            }
            idx = lineEnd < normalized.endIndex
                ? normalized.index(after: lineEnd) : lineEnd
        }
        return idx
    }

    fileprivate func normalize(_ text: String) -> String {
        // 2026-06-08 (normalizer-parity pass): route through the single shared
        // entry point so RTF gets the SAME universal cleanup as every other
        // format — CP1252 mojibake repair (RTFs embedding raw UTF-8 under
        // `\ansi`), control/invisible strip, line-break hyphens, asterism
        // strip, AND `stripGutenbergItalics` (`_Mem._` → `Mem.`). This is
        // called on BOTH the body text (line 75) and the heading-search needle
        // (line 154), so the offset coordinate system stays self-consistent.
        // hardWrapped:false — RTF emits real paragraphs, not ~72-char wraps.
        TextNormalizer.normalizeUniversal(text)
            // 2026-06-01 (heading-promotion fix) — one paragraph per unit.
            // RTF (via NSAttributedString) emits a single `\n` at every `\par`
            // break, but `RTFLibraryImporter.buildUnits` splits paragraphs on
            // `\n\n`. The mismatch FUSED many `\par` paragraphs into one unit —
            // a chapter heading like "Chapter 1: What is AI?" ended up buried
            // mid-paragraph inside a 3000-char prose unit, so `applyHeadingMarkers`
            // (which promotes a unit only when the title HEADS it) never promoted
            // it: the title rendered as plain body and TOC nav landed past it.
            // Collapsing every newline run to exactly `\n\n` makes each `\par` its
            // own unit (heading paragraphs become standalone, promotable units) AND
            // keeps ONE coordinate end-to-end: this normalized text, `buildUnits`'
            // `\n\n` split, and the persister's `\n\n` join all agree, so heading +
            // TOC + skip offsets stay exact (no drift). The two line-walkers above
            // (`advancePastDotLeaderRegion`, the needle search) are `\n\n`-safe —
            // the former already skips empty lines; the latter matches title text.
            // RESIDUAL (category): an RTF that splits a single heading across lines
            // with `\line` (a soft break that also surfaces as `\n`) would over-split
            // that heading into two units; not present in the corpus RTF. Filed.
            .replacingOccurrences(of: #"\n[ \t\n]*"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
// ========== BLOCK 4: OFFSET MAPPING + NORMALIZATION - END ==========

// ========== BLOCK 6: IMAGE DISPLAYTEXT ASSEMBLY - START ==========
extension RTFDocumentImporter {
    /// Splice `[[POSEY_VISUAL_PAGE:0:<uuid>]]` markers into the normalized
    /// plainText to produce the displayText the units pipeline consumes.
    ///
    /// **Placement via needle.** `RTFImageExtractor` can't give a plainText
    /// offset directly — it walks the RAW RTF (ISO-Latin1) while plainText
    /// comes from `NSAttributedString`, two different renderings — so each
    /// image carries a `precedingTextTail`: up to 60 chars of best-effort
    /// rendered text immediately before its `\pict`. We locate that needle in
    /// the normalized plainText and insert the marker right after it (its own
    /// paragraph, `\n\n`-delimited). This mirrors the needle technique the
    /// importer already uses to anchor headings.
    ///
    /// **Tolerant match (category, Rule 10).** The raw-RTF needle and the
    /// NSAttributedString plainText can diverge on escapes the raw walker
    /// renders coarsely (a `舗` curly apostrophe surfaces as `?` in the
    /// needle but `’` in plainText). So we don't require an exact 60-char
    /// hit: we search for the LONGEST trailing slice of the needle that
    /// occurs in plainText (down to 10 chars), advancing a forward cursor so
    /// multiple images keep document order. If nothing matches (heavily
    /// diverged or empty needle → leading image), the marker is appended at
    /// the end rather than dropped — the image still reaches the reader.
    /// Markers contribute ZERO characters to plainText, so `plainText`
    /// remains the heading-offset coordinate untouched.
    static func buildDisplayText(
        plainText: String,
        images: [RTFImageExtractor.ExtractedImage]
    ) -> (displayText: String, used: [PageImageRecord]) {
        guard !images.isEmpty else { return (plainText, []) }

        // Resolve an insertion char-offset for each image (document order).
        var insertions: [(offset: Int, imageID: String)] = []
        var used: [PageImageRecord] = []
        var cursor = plainText.startIndex

        for img in images {
            used.append(img.record)
            if let matchEnd = longestSuffixMatchEnd(
                needle: img.precedingTextTail,
                in: plainText,
                from: cursor
            ) {
                let off = plainText.distance(from: plainText.startIndex, to: matchEnd)
                insertions.append((off, img.record.imageID))
                cursor = matchEnd
            } else {
                // Needle empty (leading image) or unmatched → append at end.
                insertions.append((plainText.count, img.record.imageID))
            }
        }

        // Splice markers in DESCENDING offset order so earlier offsets stay
        // valid as we mutate. Each marker becomes its own `\n\n` paragraph.
        var result = plainText
        for ins in insertions.sorted(by: { $0.offset > $1.offset }) {
            let marker = "\n\n[[POSEY_VISUAL_PAGE:0:\(ins.imageID)]]"
            let idx = result.index(result.startIndex,
                                   offsetBy: min(ins.offset, result.count))
            result.insert(contentsOf: marker, at: idx)
        }
        return (result, used)
    }

    /// Return the end `String.Index` of the longest trailing slice of
    /// `needle` (≥10 chars, trimmed) found in `text` at or after `from`.
    /// Nil when `needle` is empty/too short or nothing matches.
    private static func longestSuffixMatchEnd(
        needle: String,
        in text: String,
        from: String.Index
    ) -> String.Index? {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let chars = Array(trimmed)
        let minLen = 10
        var len = chars.count
        while len >= minLen {
            let slice = String(chars.suffix(len))
            if let r = text.range(of: slice, range: from..<text.endIndex) {
                return r.upperBound
            }
            len -= 1
        }
        return nil
    }
}
// ========== BLOCK 6: IMAGE DISPLAYTEXT ASSEMBLY - END ==========

// ========== BLOCK 5: RAW RTF TOKENIZER - START ==========
/// Minimal RTF tokenizer just for heading-detection purposes.
/// Tracks `\fs` (size in half-points) and `\b` (bold), emits per
/// paragraph (split on `\par`). Skips ignorable destinations like
/// `\fonttbl`, `\stylesheet`, `\colortbl`, `\info`, `\pict`, `\object`,
/// and any group beginning with `\*`. The text in each paragraph is
/// best-effort — fancy unicode escapes may degrade — but enough to
/// match against the cleanly-parsed plaintext.
fileprivate enum RTFRawTokenizer {
    struct Paragraph {
        let text: String
        let fontSize: Int   // half-points; 24 = 12pt
        let bold: Bool
    }

    fileprivate struct State {
        var fontSize: Int = 24
        var bold: Bool = false
    }

    static func parseParagraphs(data: Data) -> [Paragraph] {
        // RTF's spec is ASCII; high bytes appear via \'XX or \uNNNN.
        // ISO-Latin1 decoding is bijective with raw bytes so the index
        // stream is reliable.
        guard let raw = String(data: data, encoding: .isoLatin1) else { return [] }
        let chars = Array(raw)
        let n = chars.count

        var out: [Paragraph] = []
        var stateStack: [State] = [State()]
        var currentText = ""
        // Parallel array: per-character (fontSize, bold) so we can pick
        // the dominant style for each paragraph at `\par`.
        var currentStyles: [(size: Int, bold: Bool)] = []
        var skipGroupTargetDepth = -1
        var groupDepth = 0
        var i = 0

        @inline(__always) func current() -> State { stateStack.last ?? State() }

        @inline(__always) func appendChar(_ ch: Character) {
            currentText.append(ch)
            let s = current()
            currentStyles.append((s.fontSize, s.bold))
        }

        @inline(__always) func flushParagraph() {
            // Choose the dominant style across this paragraph's chars.
            var counts: [String: (size: Int, bold: Bool, count: Int)] = [:]
            for st in currentStyles {
                let key = "\(st.size)-\(st.bold)"
                let prev = counts[key] ?? (st.size, st.bold, 0)
                counts[key] = (prev.size, prev.bold, prev.count + 1)
            }
            let dominant = counts.values.max(by: { $0.count < $1.count })
            let size = dominant?.size ?? current().fontSize
            let bold = dominant?.bold ?? current().bold
            out.append(Paragraph(text: currentText, fontSize: size, bold: bold))
            currentText = ""
            currentStyles = []
        }

        while i < n {
            let c = chars[i]

            if skipGroupTargetDepth >= 0 {
                if c == "{" {
                    groupDepth += 1
                } else if c == "}" {
                    groupDepth -= 1
                    // Exit skip when we've closed the group that triggered
                    // the skip — i.e. when groupDepth drops to or below
                    // the parent depth we recorded.
                    if groupDepth <= skipGroupTargetDepth {
                        skipGroupTargetDepth = -1
                    }
                }
                i += 1
                continue
            }

            if c == "{" {
                groupDepth += 1
                stateStack.append(current())
                i += 1
                // Check if this group is a skippable destination: { \* ... }
                if i < n && chars[i] == "\\" && i + 1 < n && chars[i + 1] == "*" {
                    skipGroupTargetDepth = groupDepth - 1
                    i += 2
                }
                continue
            }
            if c == "}" {
                groupDepth -= 1
                if stateStack.count > 1 { stateStack.removeLast() }
                i += 1
                continue
            }

            if c == "\\" {
                i += 1
                if i >= n { break }
                let nc = chars[i]
                if nc == "\\" || nc == "{" || nc == "}" {
                    appendChar(nc)
                    i += 1
                    continue
                }
                if nc == "'" {
                    // \'XX hex byte (CP1252)
                    if i + 2 < n {
                        let hex = String(chars[(i + 1)...(i + 2)])
                        if let v = UInt8(hex, radix: 16),
                           let s = String(bytes: [v], encoding: .windowsCP1252) {
                            for ch in s { appendChar(ch) }
                        }
                        i += 3
                    } else { i += 1 }
                    continue
                }
                if nc.isLetter {
                    // Control word.
                    var wEnd = i
                    while wEnd < n && chars[wEnd].isLetter { wEnd += 1 }
                    let word = String(chars[i..<wEnd])

                    var param = ""
                    var pEnd = wEnd
                    if pEnd < n && (chars[pEnd] == "-" || chars[pEnd].isNumber) {
                        let pStart = pEnd
                        if chars[pEnd] == "-" { pEnd += 1 }
                        while pEnd < n && chars[pEnd].isNumber { pEnd += 1 }
                        param = String(chars[pStart..<pEnd])
                    }
                    // Single trailing space is consumed as control-word delimiter.
                    if pEnd < n && chars[pEnd] == " " { pEnd += 1 }
                    i = pEnd

                    switch word {
                    case "par", "sect":
                        flushParagraph()
                    case "pard":
                        // 2026-05-22 — `\pard` resets paragraph
                        // properties (per RTF spec). Well-formed
                        // RTFs (Word, pandoc) always emit `\par`
                        // immediately before `\pard` so the previous
                        // paragraph is already flushed by the time
                        // `\pard` arrives — in that case currentText
                        // is empty and this branch is a no-op.
                        //
                        // BUT some hand-written or generated RTFs
                        // emit `\pard\s<n>\fs<n>` directly after
                        // body text without an intervening `\par`,
                        // which would otherwise concatenate the
                        // following styled run onto the previous
                        // paragraph (e.g. a heading absorbed into
                        // its preceding body text, losing its
                        // distinct font-size and never being
                        // detected as a heading).
                        //
                        // Treat `\pard` as an implicit flush when
                        // there's accumulated text. Safe for
                        // well-formed RTFs (currentText empty, no-op).
                        // The character-properties reset (font size,
                        // bold, etc.) is NOT applied here — `\pard`
                        // is paragraph-properties-only per spec;
                        // character resets are `\plain`'s job, not
                        // ours. Subsequent `\fs<n>` / `\b` control
                        // words set the new paragraph's style.
                        if !currentText.isEmpty {
                            flushParagraph()
                        }
                    case "line":
                        appendChar("\n")
                    case "tab":
                        appendChar("\t")
                    case "fs":
                        if let v = Int(param) {
                            stateStack[stateStack.count - 1].fontSize = v
                        }
                    case "b":
                        stateStack[stateStack.count - 1].bold = (param != "0")
                    case "fonttbl", "stylesheet", "colortbl", "info", "pict", "object", "header", "footer", "footnote", "datafield", "themedata", "latentstyles":
                        // Skip the rest of the current group.
                        skipGroupTargetDepth = groupDepth - 1
                    case "u":
                        if let v = Int(param) {
                            let codepoint = v < 0 ? 0x10000 + v : v
                            if let scalar = Unicode.Scalar(codepoint) {
                                appendChar(Character(scalar))
                            }
                            // \uc default skip = 1; consume one fallback char.
                            if i < n {
                                if chars[i] == "\\" {
                                    // Escaped fallback like \'XX — skip the whole sequence
                                    i += 1
                                    if i < n && chars[i] == "'" {
                                        i += 3 < (n - i) ? 3 : (n - i)
                                    } else if i < n {
                                        i += 1
                                    }
                                } else {
                                    i += 1
                                }
                            }
                        }
                    default:
                        break
                    }
                    continue
                }
                // Other control symbol — skip the symbol char.
                i += 1
                continue
            }

            if c == "\n" || c == "\r" {
                // Literal newlines in RTF are ignored (whitespace-only).
                i += 1
                continue
            }

            appendChar(c)
            i += 1
        }

        if !currentText.isEmpty {
            flushParagraph()
        }
        return out
    }
}
// ========== BLOCK 5: RAW RTF TOKENIZER - END ==========

// ========== BLOCK 7: RAW-UTF8 SANITIZER (NSAttributedString pre-pass) - START ==========
extension RTFDocumentImporter {
    /// Rewrite every VALID UTF-8 multibyte sequence in the RTF bytes as an RTF
    /// `\uN?` Unicode escape, so Apple's `NSAttributedString` RTF reader parses
    /// the document completely.
    ///
    /// **Why (Rule 5/10, verified on `rtf_styled-headings.rtf`).** RTF is a
    /// 7-bit-ASCII format: non-ASCII must be escaped (`\'xx` for the declared
    /// codepage, `\uN` for Unicode). Some exporters (and re-encoded files)
    /// instead embed RAW UTF-8 bytes under `\ansi`. Apple's reader does not
    /// just mojibake those — it DROPS the surrounding run: the fixture's
    /// "…get recipe for Mina.) I asked the waiter…called “paprika hendl,”…I
    /// should be able to get it…" collapsed to the broken "…get recipe foe to
    /// get it…" (a whole sentence gone, "for"+"able"→"foe"). The downstream
    /// CP1252 mojibake repair can't recover it — the text is gone before it runs.
    ///
    /// **Conservative by design.** Only well-formed UTF-8 multibyte sequences
    /// (lead `0xC0…0xF4` + valid continuations, no overlong/surrogate/over-max)
    /// are rewritten. A high byte that is NOT valid UTF-8 (e.g. a lone CP1252
    /// `0x92` curly quote) is left UNTOUCHED, so genuine single-byte-codepage
    /// RTFs are unaffected. A well-formed RTF has no raw high bytes at all, so
    /// the function returns its input UNCHANGED (verified byte-identical on the
    /// corpus's well-formed RTFs: with-image, business-letter, AI Book Collab).
    ///
    /// **Category (Rule 10):** any RTF embedding raw UTF-8 — not just this
    /// fixture. The raw tokenizer (Block 5) and image extractor keep using the
    /// ORIGINAL bytes: they read via ISO-Latin1 (bijective, never drops) and
    /// already tolerate this divergence via their ASCII-prefix needle fallback.
    static func sanitizeRawUTF8Bytes(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        // Fast path: no raw high bytes → well-formed RTF, return unchanged.
        guard bytes.contains(where: { $0 >= 0x80 }) else { return data }

        let n = bytes.count
        var out = [UInt8]()
        out.reserveCapacity(n)
        var i = 0
        var rewroteAny = false
        while i < n {
            let b = bytes[i]
            if b >= 0x80 {
                let len = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : (b >= 0xC0 ? 2 : 1))
                if len >= 2, i + len <= n,
                   let scalar = Self.decodeUTF8Sequence(Array(bytes[i..<(i + len)])) {
                    Self.appendRTFUnicodeEscape(scalar, into: &out)
                    rewroteAny = true
                    i += len
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return rewroteAny ? Data(out) : data
    }

    /// Validate and decode a single 2–4 byte UTF-8 sequence to its scalar.
    /// Rejects overlong encodings, surrogate codepoints, and >U+10FFFF.
    private static func decodeUTF8Sequence(_ seq: [UInt8]) -> Unicode.Scalar? {
        @inline(__always) func cont(_ x: UInt8) -> Bool { x & 0xC0 == 0x80 }
        let first = seq[0]
        var cp: UInt32
        switch seq.count {
        case 2:
            guard first & 0xE0 == 0xC0, cont(seq[1]) else { return nil }
            cp = (UInt32(first & 0x1F) << 6) | UInt32(seq[1] & 0x3F)
            guard cp >= 0x80 else { return nil }
        case 3:
            guard first & 0xF0 == 0xE0, cont(seq[1]), cont(seq[2]) else { return nil }
            cp = (UInt32(first & 0x0F) << 12) | (UInt32(seq[1] & 0x3F) << 6) | UInt32(seq[2] & 0x3F)
            guard cp >= 0x800, !(0xD800...0xDFFF).contains(cp) else { return nil }
        case 4:
            guard first & 0xF8 == 0xF0, cont(seq[1]), cont(seq[2]), cont(seq[3]) else { return nil }
            cp = (UInt32(first & 0x07) << 18) | (UInt32(seq[1] & 0x3F) << 12)
                | (UInt32(seq[2] & 0x3F) << 6) | UInt32(seq[3] & 0x3F)
            guard cp >= 0x10000, cp <= 0x10FFFF else { return nil }
        default:
            return nil
        }
        return Unicode.Scalar(cp)
    }

    /// Emit an RTF `\uN?` escape (signed 16-bit per spec; values > 32767 are
    /// written negative). Astral scalars become a UTF-16 surrogate pair, each a
    /// separate `\uN`. The trailing `?` is the `\uc1` fallback char readers skip.
    private static func appendRTFUnicodeEscape(_ scalar: Unicode.Scalar, into out: inout [UInt8]) {
        @inline(__always) func emit(_ u16: UInt32) {
            let signed = u16 <= 0x7FFF ? Int(u16) : Int(u16) - 0x10000
            out.append(contentsOf: Array("\\u\(signed)?".utf8))
        }
        let cp = scalar.value
        if cp <= 0xFFFF {
            emit(cp)
        } else {
            let v = cp - 0x10000
            emit(0xD800 + (v >> 10))
            emit(0xDC00 + (v & 0x3FF))
        }
    }
}
// ========== BLOCK 7: RAW-UTF8 SANITIZER (NSAttributedString pre-pass) - END ==========
