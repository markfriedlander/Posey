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
    func loadDocument(from url: URL) throws -> (displayText: String, plainText: String, images: [PageImageRecord]) {
        let data = try Data(contentsOf: url)
        let baseDirectory = url.deletingLastPathComponent()
        let (markedData, images) = extractInlineImages(from: data, baseDirectory: baseDirectory)
        let displayText = try loadText(fromData: markedData)
        let plainText = stripVisualPageMarkers(from: displayText)
        return (displayText, plainText, images)
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
        // U+E001 (Private Use Area) survives the HTML → plain-text conversion
        // as literal text content; after extraction it becomes \n, so each
        // block boundary yields (our \n)(NSAttributedString's own \n) = \n\n.
        let markedData = injectParagraphMarkers(data)

        let attributedString: NSAttributedString
        do {
            attributedString = try NSAttributedString(
                data: markedData,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            )
        } catch {
            throw ImportError.unreadableDocument
        }

        let rawText = attributedString.string
            .replacingOccurrences(of: "\u{E001}", with: "\n")
        let normalized = normalize(rawText)
        guard normalized.isEmpty == false else {
            throw ImportError.emptyDocument
        }

        return normalized
    }

    /// Inserts U+E001 before each closing block-level tag in the raw HTML so
    /// that paragraph boundaries produce \n\n in the final plain text rather
    /// than the single \n that NSAttributedString emits for each <p> end.
    private func injectParagraphMarkers(_ data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .isoLatin1) else {
            return data
        }
        let blockTags = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote"]
        for tag in blockTags {
            html = html.replacingOccurrences(
                of: "</\(tag)>",
                with: "\u{E001}</\(tag)>",
                options: .caseInsensitive
            )
        }
        return html.data(using: .utf8) ?? data
    }
// ========== BLOCK 2: IMPORT ENTRY POINTS - END ==========

// ========== BLOCK 3: TEXT NORMALIZATION - START ==========
    private func normalize(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space
        t = t.replacingOccurrences(of: "\u{00AD}", with: "")    // Unicode soft hyphen (invisible; strip entirely)
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
        let pattern = #"\u{000C}?\[\[POSEY_VISUAL_PAGE:[^\]]+\]\]\u{000C}?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
    }
}
// ========== BLOCK 4: INLINE IMAGE EXTRACTION - END ==========
