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
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(
                data: data,
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

        return RTFParsedDocument(plainText: normalized, headings: headings)
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

            guard let range = normalized.range(of: needle, range: searchFrom..<normalized.endIndex) else { continue }
            let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
            let level = (topThree.firstIndex(of: h.pointSize) ?? 2) + 1
            out.append(RTFHeadingEntry(level: level, title: needleFull, plainTextOffset: offset))
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
        guard let dotLeader = try? NSRegularExpression(pattern: #"^.+?(?:\t+|[ .]{3,})\d+\s*$"#) else {
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
        TextNormalizer.stripMojibakeAndControlCharacters(text)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{000C}", with: "")   // form feed (#12)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
// ========== BLOCK 4: OFFSET MAPPING + NORMALIZATION - END ==========

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
