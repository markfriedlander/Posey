import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// ========== BLOCK 1: ERROR TYPES - START ==========
struct HTMLDocumentImporter {
    enum ImportError: LocalizedError, Equatable {
        case unreadableDocument
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "Posey could not read that HTML file."
            case .emptyDocument:
                return "The HTML file is empty."
            }
        }
    }

    /// One `<h1>`..`<h6>` element extracted from the raw HTML.
    /// 2026-05-06 (parity #3): HTML headings flow into the TOC for
    /// styling parity with MD/DOCX/RTF/EPUB/PDF. The library importer
    /// resolves each title to a plainText offset by sequential search.
    struct HTMLHeadingEntry {
        let level: Int
        let title: String
    }
// ========== BLOCK 1: ERROR TYPES - END ==========

// ========== BLOCK 2: IMPORT ENTRY POINTS - START ==========

    /// Task 8 #4 (2026-05-03): rich import that extracts inline
    /// images alongside text. Used by `HTMLLibraryImporter` for
    /// URL-based imports where we can resolve relative `<img src=...>`
    /// paths against the file's containing directory.
    ///
    /// Returns:
    ///   - `displayText` — the rendered text with embedded
    ///     `[[POSEY_VISUAL_PAGE:0:<uuid>]]` markers at each successfully-
    ///     extracted `<img>` position. Reader UI parses these markers
    ///     and shows the inline image.
    ///   - `plainText` — `displayText` with the markers stripped.
    ///     This is what TTS reads aloud and what the embedding index
    ///     ingests.
    ///   - `images` — collected `PageImageRecord` values, one per
    ///     successfully-extracted image, ready for `databaseManager.insertImage`.
    func loadDocument(from url: URL) throws -> (displayText: String, plainText: String, images: [PageImageRecord], headings: [HTMLHeadingEntry]) {
        let data = try Data(contentsOf: url)
        let baseDirectory = url.deletingLastPathComponent()
        let (markedData, images) = extractInlineImages(from: data, baseDirectory: baseDirectory)
        let displayText = try loadText(fromData: markedData)
        // 2026-05-06 (parity #2) — displayText KEEPS markers;
        // HTMLDisplayParser converts them to .visualPlaceholder
        // blocks. plainText is the marker-stripped form for TTS.
        let plainText = stripVisualPageMarkers(from: displayText)
        let headings = extractHeadings(fromRawData: data)
        return (displayText, plainText, images, headings)
    }

    /// Pull `<h1>`..`<h6>` elements out of raw HTML for TOC + heading
    /// styling. Strips inner tags, decodes the small set of entities
    /// most likely to appear in heading text, trims whitespace. The
    /// library importer maps each title to a plainText offset by
    /// sequential search since the post-NSAttributedString plainText
    /// has no remaining tag boundaries to anchor against.
    func extractHeadings(fromRawData data: Data) -> [HTMLHeadingEntry] {
        guard let html = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .isoLatin1) else {
            return []
        }
        // Capture the level digit and the inner content. `(?s)` makes
        // `.` cross newlines so headings spanning multiple source
        // lines still match. `?` keeps the inner match non-greedy
        // so consecutive headings don't merge.
        let pattern = #"(?si)<h([1-6])\b[^>]*>(.*?)</h\1\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var out: [HTMLHeadingEntry] = []
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges == 3,
                  let lvlR = Range(match.range(at: 1), in: html),
                  let txtR = Range(match.range(at: 2), in: html),
                  let level = Int(String(html[lvlR])) else { continue }
            let raw = String(html[txtR])
            let stripped = stripHeadingInnerTags(raw)
            let decoded = decodeMinimalEntities(stripped)
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(HTMLHeadingEntry(level: level, title: trimmed))
        }
        return out
    }

    private func stripHeadingInnerTags(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    private func decodeMinimalEntities(_ s: String) -> String {
        var t = s
        // Just the entities most likely to appear in heading text.
        // Full HTML entity decoding would require a real HTML parser,
        // and the loaded plainText has already had everything decoded
        // by NSAttributedString — these match the most common cases
        // to keep the sequential search succeeding.
        t = t.replacingOccurrences(of: "&nbsp;", with: " ")
        t = t.replacingOccurrences(of: "&amp;", with: "&")
        t = t.replacingOccurrences(of: "&lt;", with: "<")
        t = t.replacingOccurrences(of: "&gt;", with: ">")
        t = t.replacingOccurrences(of: "&quot;", with: "\"")
        t = t.replacingOccurrences(of: "&#39;", with: "'")
        t = t.replacingOccurrences(of: "&apos;", with: "'")
        t = t.replacingOccurrences(of: "&mdash;", with: "—")
        t = t.replacingOccurrences(of: "&ndash;", with: "–")
        t = t.replacingOccurrences(of: "&hellip;", with: "…")
        // Collapse any internal whitespace runs into one space so the
        // search target matches NSAttributedString's whitespace
        // collapsing.
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t
    }

    func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return try loadText(fromData: data)
    }

    /// NSAttributedString HTML parsing uses WebKit internally under UIKit and
    /// must be called on the main thread. This method asserts that requirement
    /// so violations surface immediately rather than as subtle threading bugs.
    func loadText(fromData data: Data) throws -> String {
        #if canImport(UIKit)
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        // Pre-inject paragraph markers before closing block-level tags.
        // NSAttributedString collapses <p>…</p> boundaries to a single \n,
        // merging consecutive paragraphs into one undifferentiated block.
        //
        // 2026-05-05 — Switched from U+E001 (Private Use Area) sentinel
        // to an ASCII-only sentinel because on iOS 18+ NSAttributedString's
        // HTML parser interprets the U+E001 UTF-8 bytes (EE 80 81) as
        // separate Latin-1 / Windows-1252 characters (î, €, U+0081),
        // leaving mojibake in the extracted text. The Estuaries article
        // in our test corpus showed this mojibake AFTER every section
        // header and tripped the language detector into flagging the
        // doc as non-English. ASCII sentinels round-trip through any
        // encoding pipeline intact.
        let markedData = injectParagraphMarkers(data)

        let attributedString: NSAttributedString
        do {
            // 2026-05-06 — Explicit UTF-8 character encoding. Without
            // this, NSAttributedString HTML parsing defaults to
            // Windows-1252 when the HTML has no `<meta charset>`
            // declaration, causing UTF-8 multi-byte sequences (e.g.
            // em-dash 0xE2 0x80 0x94) to be misread as Latin-1 and
            // surface as mojibake like "â€"" in the rendered text.
            // The Field Notes on Estuaries article exhibited this:
            // "the surface â€" the sailboats" instead of "the surface
            // — the sailboats". Forcing UTF-8 fixes it because every
            // path that loads HTML data above goes through
            // String(data:encoding: .utf8) first.
            attributedString = try NSAttributedString(
                data: markedData,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: NSNumber(value: String.Encoding.utf8.rawValue)
                ],
                documentAttributes: nil
            )
        } catch {
            throw ImportError.unreadableDocument
        }

        let rawText = attributedString.string
            .replacingOccurrences(of: paragraphSentinel, with: "\n")
            // Defensive: also catch the mojibake pattern observed on
            // iOS 18+ where the original PUA sentinel got UTF-8-bytes-
            // interpreted-as-Latin-1, leaving "î€" + optional U+0081.
            // Kept for backward-compat with older imports that may
            // have round-tripped through the broken sentinel.
            .replacingOccurrences(of: "\u{00EE}\u{20AC}\u{0081}", with: "\n")
            .replacingOccurrences(of: "\u{00EE}\u{20AC}", with: "\n")
            .replacingOccurrences(of: "\u{E001}", with: "\n")
        let normalized = normalize(rawText)
        guard normalized.isEmpty == false else {
            throw ImportError.emptyDocument
        }

        return normalized
    }

    /// ASCII paragraph sentinel. Distinctive enough to never appear
    /// in real document text, ASCII-clean so it survives any
    /// encoding pipeline NSAttributedString runs the HTML through.
    private let paragraphSentinel = "POSEYBLOCKBREAK"

    /// Inserts the ASCII paragraph sentinel before each closing
    /// block-level tag in the raw HTML so that paragraph boundaries
    /// produce \n\n in the final plain text rather than the single
    /// \n that NSAttributedString emits for each <p> end.
    private func injectParagraphMarkers(_ data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .isoLatin1) else {
            return data
        }
        let blockTags = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote"]
        for tag in blockTags {
            html = html.replacingOccurrences(
                of: "</\(tag)>",
                with: "\(paragraphSentinel)</\(tag)>",
                options: .caseInsensitive
            )
        }
        return html.data(using: .utf8) ?? data
    }
// ========== BLOCK 2: IMPORT ENTRY POINTS - END ==========

// ========== BLOCK 3: TEXT NORMALIZATION - START ==========
    private func normalize(_ text: String) -> String {
        var t = text
        // 2026-05-05 — Universal mojibake + control-character strip
        // (TextNormalizer.stripMojibakeAndControlCharacters covers
        // C0/C1 controls, PUA, replacement char, known iOS sentinel
        // mojibake, etc.). Format-parity policy.
        t = TextNormalizer.stripMojibakeAndControlCharacters(t)
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space
        t = t.replacingOccurrences(of: "\u{00AD}", with: "")    // Unicode soft hyphen (invisible; strip entirely)
        // 2026-05-05 — Strip ANY Unicode Private Use Area characters
        // (U+E000–U+F8FF), control characters (U+0080–U+009F), and
        // bare U+E001 paragraph-sentinel residue. The
        // injectParagraphMarkers pass uses U+E001 as a paragraph
        // sentinel and the post-extraction replace handles most cases,
        // but on iOS 18+ NSAttributedString sometimes leaves residue
        // — a multi-byte sequence shows up where the U+E001 was, with
        // U+0081 control chars adjacent. Real documents never contain
        // PUA or C1 control chars in normal text, so a blanket filter
        // is safe and prevents the language detector from seeing
        // these as non-Latin script content (which was tripping the
        // non-English banner on the Estuaries article).
        //
        // Using unicodeScalars filter rather than regex because ICU
        // regex character-class escaping inside Swift raw strings is
        // fragile (\u{XXXX} braces aren't standard ICU). The filter
        // is deterministic and easy to reason about.
        t = String(String.UnicodeScalarView(t.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            let v = scalar.value
            // Strip PUA range
            if v >= 0xE000 && v <= 0xF8FF { return nil }
            // Strip C1 control characters (the U+0081 leftover crowd)
            if v >= 0x0080 && v <= 0x009F { return nil }
            return scalar
        }))
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\r",   with: "\n")
        t = t.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        t = collapseLineBreakHyphens(t)                         // "word-\nword" → "wordword" (EPUB/HTML line-break hyphens)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses line-break hyphenation: "fas-\ncism" or "fas- cism" → "fascism".
    /// Only fires when a lowercase continuation follows "- " or "-\n",
    /// distinguishing line-break splits from intentional compound words like "anti-fascist".
    private func collapseLineBreakHyphens(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z]+)-[ \n]([a-z]+)"#) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1$2"
        )
    }
// ========== BLOCK 3: TEXT NORMALIZATION - END ==========


// ========== BLOCK 4: INLINE IMAGE EXTRACTION (Task 8 #4) - START ==========

    /// Replace `<img src="...">` tags with `[[POSEY_VISUAL_PAGE:0:<uuid>]]`
    /// markers and return the loaded image bytes alongside the rewritten
    /// HTML. Resolves three source forms:
    ///
    /// 1. `data:image/...;base64,...` — decoded inline.
    /// 2. Relative paths (`figure.png`, `images/photo.jpg`) — resolved
    ///    against `baseDirectory` and read from disk.
    /// 3. Absolute file URLs (`file:///...`) — read directly.
    ///
    /// Skips:
    /// - `http://` / `https://` / `//` URLs (we don't fetch over the
    ///   network during import — Posey is offline-first per
    ///   CLAUDE.md "the app must work fully offline").
    /// - SVG (UIImage cannot render SVG without WebKit; the user is
    ///   better served seeing the alt text).
    private func extractInlineImages(
        from data: Data,
        baseDirectory: URL
    ) -> (Data, [PageImageRecord]) {
        guard var html = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .isoLatin1) else {
            return (data, [])
        }
        let pattern = #"<img[^>]+src=["']([^"']+)["'][^>]*\/?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return (data, [])
        }

        var images: [PageImageRecord] = []
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var replacements: [(range: Range<String.Index>, marker: String)] = []
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: html),
                  let srcRange = Range(match.range(at: 1), in: html) else { continue }
            let src = String(html[srcRange])
            let lower = src.lowercased()
            // Skip network refs and SVG.
            if lower.hasPrefix("http") || lower.hasPrefix("//") || lower.hasSuffix(".svg") { continue }

            let imageData: Data?
            if lower.hasPrefix("data:") {
                imageData = decodeDataURI(src)
            } else if lower.hasPrefix("file:") {
                imageData = URL(string: src).flatMap { try? Data(contentsOf: $0) }
            } else {
                let resolved = baseDirectory.appendingPathComponent(src).standardizedFileURL
                imageData = try? Data(contentsOf: resolved)
            }
            guard let bytes = imageData, !bytes.isEmpty else { continue }

            let imageID = UUID().uuidString
            images.append(PageImageRecord(imageID: imageID, data: bytes))
            // Wrap in form-feed separators so downstream block-splitters
            // see a clean break around the marker.
            let marker = "\u{000C}[[POSEY_VISUAL_PAGE:0:\(imageID)]]\u{000C}"
            replacements.append((fullRange, marker))
        }

        for (range, marker) in replacements {
            html.replaceSubrange(range, with: marker)
        }
        images.reverse()
        return (html.data(using: .utf8) ?? data, images)
    }

    /// Decode a `data:image/...;base64,xxx` URI into raw bytes.
    /// Returns nil for malformed URIs or non-base64 payloads.
    private func decodeDataURI(_ src: String) -> Data? {
        guard let commaIdx = src.firstIndex(of: ",") else { return nil }
        let header = src[..<commaIdx]
        let payload = src[src.index(after: commaIdx)...]
        if header.contains(";base64") {
            return Data(base64Encoded: String(payload))
        }
        // URL-encoded text payload — decode percent-escapes.
        return String(payload).removingPercentEncoding?.data(using: .utf8)
    }

    /// Strip `[[POSEY_VISUAL_PAGE:0:<uuid>]]` markers (and any
    /// surrounding form-feed separators) from extracted text so
    /// `plainText` is suitable for TTS + embeddings.
    private func stripVisualPageMarkers(from text: String) -> String {
        // ICU-style `\x{HHHH}` for U+000C (Swift raw-string `\u{HHHH}`
        // is not ICU regex syntax — was failing silently via try?.)
        let pattern = "\\x{000C}?\\[\\[POSEY_VISUAL_PAGE:[^\\]]+\\]\\]\\x{000C}?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
    }
}
// ========== BLOCK 4: INLINE IMAGE EXTRACTION - END ==========
