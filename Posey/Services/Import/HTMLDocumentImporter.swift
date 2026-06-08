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
    func loadDocument(from url: URL) async throws -> (displayText: String, plainText: String, images: [PageImageRecord], headings: [HTMLHeadingEntry]) {
        let data = try Data(contentsOf: url)
        let baseDirectory = url.deletingLastPathComponent()

        // 2026-05-22 — Readability pre-pass. Strip site chrome
        // (nav / sidebar / footer / related-articles) before the
        // existing NSAttributedString → text pipeline runs. The
        // cleaned HTML keeps headings + figure-embedded images,
        // so downstream extractHeadings + extractInlineImages
        // operate on the article body only. If Readability declines
        // (page isn't article-shaped), fall back to the raw HTML so
        // non-article HTML imports (rendered READMEs, EPUB internal
        // chapters, recipe pages) still work — same code path as
        // before this commit.
        let rawHTML = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        // 2026-05-27 — Strip Wikipedia infobox / navbox / hatnote
        // chrome BEFORE Readability runs. Readability keeps these
        // because they sit inside <article>; stripping them at the
        // raw-HTML stage lets the reader open at the article body
        // instead of "Pride and Prejudice / Title page / Author /
        // Jane Austen / Working title / First Impressions / …".
        let preCleanedHTML = Self.stripWikipediaChrome(rawHTML: rawHTML)
        // 2026-05-31 (ingestion audit, Bug D) — BYPASS Readability for Project
        // Gutenberg HTML books. Readability is for web articles (it strips
        // nav/sidebar/infobox chrome — essential for Wikipedia). But it treats
        // Gutenberg's `<section class="pg-boilerplate pgheader">` as chrome and
        // strips it, taking the `*** START OF THE PROJECT GUTENBERG EBOOK ***`
        // marker with it. GutenbergBoundaryDetector (run later) then finds no
        // marker -> no gutenberg skip -> the reader opens Moby HTML in the
        // transcriber's notes instead of Chapter 1. A Gutenberg HTML file is
        // already a single clean article (no chrome to strip), so bypassing
        // Readability is safe and makes it flow like the EPUB/TXT path (keep
        // the boilerplate in plainText; the gutenberg skip chain hides it).
        // Detect on the STRUCTURAL class `pg-boilerplate` ONLY — it appears
        // exclusively in real Project Gutenberg book HTML. NOT the text
        // "PROJECT GUTENBERG": any page that merely links to or mentions
        // Gutenberg (e.g. the Wikipedia "Pride and Prejudice" article, which
        // cites the Gutenberg etext) contains that string, and matching it
        // wrongly bypassed Readability for Wikipedia -> nav/sidebar chrome
        // leaked into the reader. (Caught in verification — `pg-boilerplate`
        // is in Moby's HTML, absent from Wikipedia's.)
        let isGutenbergHTML = rawHTML.range(of: "pg-boilerplate") != nil
        let cleanedHTML: String? = isGutenbergHTML
            ? nil
            : await ReadabilityExtractor.extractArticleHTML(
                rawHTML: preCleanedHTML, baseURL: url
            )
        let workingData: Data
        if let cleanedHTML, let cleanedData = cleanedHTML.data(using: .utf8) {
            workingData = cleanedData
        } else {
            workingData = data
        }

        let (markedData, images) = extractInlineImages(from: workingData, baseDirectory: baseDirectory)
        let displayTextRaw = try loadText(fromData: markedData)
        // 2026-06-05 — re-establish headings Readability dropped. Source every
        // article heading from preCleanedHTML (all present there) and inject any
        // whose title the Readability output lost back into displayText at its
        // body anchor. The returned `headings` is the full ordered list for the
        // downstream title-based TOC + styling resolution.
        let (displayText, headings) = reinjectArticleHeadings(
            into: displayTextRaw,
            specs: extractHeadingSpecs(fromHTML: preCleanedHTML)
        )
        // 2026-05-06 (parity #2) — displayText KEEPS markers;
        // HTMLDisplayParser converts them to .visualPlaceholder
        // blocks. plainText is the marker-stripped form for TTS.
        let plainText = stripVisualPageMarkers(from: displayText)
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
        // 2026-06-05 — Numeric entities (&#160; nbsp, &#8217; quote, &#93; ]…)
        // so body-anchor text matches NSAttributedString's decoded plaintext.
        if let regex = try? NSRegularExpression(pattern: #"&#(\d{1,7});"#) {
            let ns = t as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let code = Int(ns.substring(with: m.range(at: 1))) ?? 0
                if code == 160 { result += " " }                               // nbsp → space
                else if let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            t = result
        }
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
        // 2026-06-05 — drop the space a stripped inline tag leaves BEFORE
        // punctuation ("Prejudice , like" → "Prejudice, like"); NSAttributedString
        // emits no such space, so this lets a body anchor match the plaintext.
        t = t.replacingOccurrences(of: #"\s+([,;:.!?)\]])"#, with: "$1", options: .regularExpression)
        return t
    }

    // 2026-06-05 — Re-establish article headings that Readability drops.
    // On structured web articles (Wikipedia/MDN/blogs) Readability keeps each
    // section's CONTENT but inconsistently strips the section heading text — on
    // the P&P article it dropped 18 of 24 headings, leaving the body unheaded
    // (empty TOC, no section breaks). `extractHeadings(fromRawData: workingData)`
    // ran on the Readability OUTPUT, so it only saw the survivors. The fix:
    // source EVERY real article heading from `preCleanedHTML` (post-chrome-strip,
    // pre-Readability — where they all still exist), and for any whose title the
    // Readability output dropped, INJECT the title back into `displayText` at the
    // section's body-anchor position. Then the existing title-based
    // resolveHeadingOffsets (TOC) + applyHeadingMarkers (styling) work unchanged.
    // Forward-only/monotonic; a heading whose anchor is ambiguous/missing is
    // SKIPPED + logged, never guessed (a missing heading is recoverable; a
    // misplaced one is a silent lie). Chrome section headings are denylisted.

    /// Section-heading titles that are site chrome, not article content.
    private static let chromeHeadingDenylist: Set<String> = [
        "references", "external links", "see also", "notes", "citations",
        "bibliography", "further reading", "sources", "footnotes", "contents",
        "navigation menu", "navigation", "tools", "languages", "in this article",
        "related topics", "related articles", "explanation", "site map",
    ]

    private struct HeadingSpec { let level: Int; let title: String; let bodyAnchor: String }

    /// Length-preserving punctuation fold (curly quotes / dashes → ASCII) so a
    /// raw-HTML-derived anchor still matches NSAttributedString's smart-quoted
    /// plaintext. 1 grapheme → 1 grapheme, so offsets stay valid across the fold.
    private func foldPunctuation(_ s: String) -> String {
        var t = s
        for (a, b) in [("\u{2018}", "'"), ("\u{2019}", "'"),
                       ("\u{201C}", "\""), ("\u{201D}", "\""),
                       ("\u{2013}", "-"), ("\u{2014}", "-")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    private func stripTagsToSpaces(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return s }
        return regex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    /// Hatnote / cross-reference lead-ins that aren't section prose.
    private static let hatnotePattern = try? NSRegularExpression(
        pattern: #"^(?:main article|see also|further information|part of a series|this article|from wikipedia)\b"#,
        options: [.caseInsensitive])

    /// First substantial PROSE element (<p>/<li>/<blockquote>/<dd>) text in a
    /// section's HTML, cleaned to match NSAttributedString's plaintext; nil if
    /// none ≥24 chars. Skips hatnotes ("Main article: …") and — by only
    /// considering prose elements — the image <figcaption>s, genealogy <table>s
    /// and quotebox <style> CSS that Readability strips or renders differently
    /// (anchoring on those was the source of false anchor misses).
    private func firstProseAnchor(inSectionHTML html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?si)<(p|li|blockquote|dd)\b[^>]*>(.*?)</\1\s*>"#) else { return nil }
        let ns = html as NSString
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let text = decodeMinimalEntities(stripTagsToSpaces(ns.substring(with: m.range(at: 2))))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 24 else { continue }
            if let hp = Self.hatnotePattern,
               hp.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { continue }
            return String(text.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Pull `(level, title, bodyAnchor)` for every real article heading in `html`
    /// (expects `preCleanedHTML`). `bodyAnchor` is the section's first prose
    /// element text (see `firstProseAnchor`); chrome-titled headings are dropped.
    private func extractHeadingSpecs(fromHTML html: String) -> [HeadingSpec] {
        let pattern = #"(?si)<h([1-6])\b[^>]*>(.*?)</h\1\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        var specs: [HeadingSpec] = []
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges == 3,
                  let level = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let title = decodeMinimalEntities(stripHeadingInnerTags(ns.substring(with: m.range(at: 2))))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  !Self.chromeHeadingDenylist.contains(title.lowercased()) else { continue }
            let after = m.range.location + m.range.length
            guard after < ns.length else { continue }
            var tail = ns.substring(from: after)
            // Cut at the next heading so the anchor is THIS section's own content
            // (a parent heading with no intro prose finds no anchor and is
            // skipped, not mis-anchored onto its first subsection).
            if let nextH = tail.range(of: #"(?i)<h[1-6]\b"#, options: .regularExpression) {
                tail = String(tail[..<nextH.lowerBound])
            }
            guard let anchor = firstProseAnchor(inSectionHTML: tail) else { continue }
            specs.append(HeadingSpec(level: level, title: title, bodyAnchor: anchor))
        }
        return specs
    }

    /// Inject each dropped heading's title back into `displayText` at its
    /// body-anchor position; return the augmented text + the full ordered
    /// heading list for TOC/styling resolution.
    private func reinjectArticleHeadings(
        into displayText: String, specs: [HeadingSpec]
    ) -> (String, [HTMLHeadingEntry]) {
        guard !specs.isEmpty else { return (displayText, []) }
        let folded = foldPunctuation(displayText)
        let fStart = folded.startIndex
        var injections: [(offset: Int, text: String)] = []
        var headings: [HTMLHeadingEntry] = []
        var cursorOffset = 0
        for spec in specs {
            let foldedAnchor = foldPunctuation(spec.bodyAnchor)
            let searchStart = folded.index(fStart, offsetBy: cursorOffset,
                                           limitedBy: folded.endIndex) ?? folded.endIndex
            guard let aRange = folded.range(of: foldedAnchor,
                                            range: searchStart..<folded.endIndex) else {
                print("PoseyHTML: heading skipped — body anchor not found: \(spec.title)")
                continue
            }
            let anchorOffset = folded.distance(from: fStart, to: aRange.lowerBound)
            // Survivor? title text already present in this section's lead-in.
            let backSpan = min(300, anchorOffset - cursorOffset)
            let preStart = folded.index(aRange.lowerBound, offsetBy: -backSpan,
                                        limitedBy: fStart) ?? fStart
            let isSurvivor = String(folded[preStart..<aRange.lowerBound])
                .contains(foldPunctuation(spec.title))
            if !isSurvivor {
                injections.append((anchorOffset, spec.title + "\n\n"))
            }
            headings.append(HTMLHeadingEntry(level: spec.level, title: spec.title))
            cursorOffset = folded.distance(from: fStart, to: aRange.upperBound)
        }
        // Apply high-offset-first so earlier offsets stay valid.
        var result = displayText
        for inj in injections.sorted(by: { $0.offset > $1.offset }) {
            let idx = result.index(result.startIndex, offsetBy: inj.offset)
            result.insert(contentsOf: inj.text, at: idx)
        }
        return (result, headings)
    }

    func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return try loadText(fromData: data)
    }

    /// 2026-05-22 — Async data-based entry point that runs the
    /// Readability pre-pass before delegating to `loadText(fromData:)`.
    /// Mirrors `loadDocument(from:)` for the rawData path that
    /// `HTMLLibraryImporter.importDocument(rawData:)` uses.
    ///
    /// Returns `(plainText, headings)`. No inline-image extraction
    /// for the data path (per the pre-existing pipeline — data
    /// imports lack a containing directory for resolving relative
    /// `<img src=...>` paths).
    func loadTextAsync(fromData data: Data) async throws -> (text: String, headings: [HTMLHeadingEntry]) {
        let rawHTML = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        // 2026-05-27 — Wikipedia chrome strip (same rationale as the
        // url-based loadDocument path above).
        let preCleanedHTML = Self.stripWikipediaChrome(rawHTML: rawHTML)
        let cleanedHTML = await ReadabilityExtractor.extractArticleHTML(
            rawHTML: preCleanedHTML, baseURL: nil
        )
        let workingData: Data
        if let cleanedHTML, let cleanedData = cleanedHTML.data(using: .utf8) {
            workingData = cleanedData
        } else {
            workingData = data
        }
        let text = try loadText(fromData: workingData)
        let headings = extractHeadings(fromRawData: workingData)
        return (text, headings)
    }

    /// NSAttributedString HTML parsing uses WebKit internally under UIKit and
    /// must be called on the main thread. This method asserts that requirement
    /// so violations surface immediately rather than as subtle threading bugs.
    func loadText(fromData data: Data) throws -> String {
        #if canImport(UIKit)
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        // 2026-05-20 — Strip Project Gutenberg's `<p class="asterism">`
        // scene-break blocks BEFORE list-marker / paragraph-marker /
        // NSAttributedString passes. Same rationale as the parallel
        // strip in EPUBDocumentImporter — NSAttributedString.html
        // discards the class attribute and keeps the literal "*  *
        // *" text, contaminating plainText and the reader display.
        // Standalone HTML imports (.html files outside EPUB) also use
        // this importer, so this fix covers both code paths.
        let asterismStripped = Self.stripAsterismBlocks(from: data)

        // 2026-05-06 (parity #4) — Inject list markers BEFORE the
        // paragraph-marker pass so each <li> shows its bullet/number
        // glyph in the rendered text. NSAttributedString strips the
        // <ul>/<ol>/<li> structure entirely, so the marker injection
        // is the only way to preserve list semantics through to
        // displayText. Per DECISIONS.md "List markers", these
        // prefixes get stripped at the speech boundary so AVSpeech-
        // Synthesizer never pronounces them.
        let listMarkedData = injectListMarkers(asterismStripped)

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
        let markedData = injectParagraphMarkers(listMarkedData)

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
    /// Walk the HTML token stream tracking `<ul>`/`<ol>` nesting and
    /// inject a visible marker (`• ` or `N. `) immediately after each
    /// opening `<li>` tag. Nested lists restart numbering / continue
    /// to use bullets per their own surrounding tag. Marker characters
    /// land in both `displayText` and `plainText`; the speech path
    /// strips them at the AVSpeechSynthesizer boundary so they're
    /// never pronounced.
    private func injectListMarkers(_ data: Data) -> Data {
        guard let html = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .isoLatin1) else {
            return data
        }
        let pattern = #"<(/?)(ul|ol|li)\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return data
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)
        guard !matches.isEmpty else { return data }

        var result = ""
        result.reserveCapacity(html.count + matches.count * 4)
        var stack: [(kind: String, counter: Int)] = []
        var cursor = html.startIndex

        for match in matches {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let isClose: Bool = {
                guard let r = Range(match.range(at: 1), in: html) else { return false }
                return !html[r].isEmpty
            }()
            guard let nameRange = Range(match.range(at: 2), in: html) else { continue }
            let tagName = html[nameRange].lowercased()

            // Append source text up to this tag unchanged.
            result.append(contentsOf: html[cursor..<tagRange.lowerBound])
            // Append the tag itself unchanged.
            result.append(contentsOf: html[tagRange])

            if tagName == "ul" || tagName == "ol" {
                if isClose {
                    if let top = stack.last, top.kind == tagName {
                        stack.removeLast()
                    }
                } else {
                    stack.append((kind: tagName, counter: 0))
                }
            } else if tagName == "li", !isClose, let top = stack.last {
                if top.kind == "ul" {
                    result.append("• ")
                } else { // ol
                    let n = top.counter + 1
                    stack[stack.count - 1] = (kind: "ol", counter: n)
                    result.append("\(n). ")
                }
            }

            cursor = tagRange.upperBound
        }
        if cursor < html.endIndex {
            result.append(contentsOf: html[cursor...])
        }
        return result.data(using: .utf8) ?? data
    }

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
        // 2026-06-08 (normalizer-parity pass): route through the single shared
        // entry point. This is the per-chapter/per-document text exit for BOTH
        // standalone HTML (loadDocument → loadText) AND EPUB (which calls
        // loadText per spine item), so one call brings both formats to full
        // parity — `stripGutenbergItalics` (`_Mem._` → `Mem.`), CP1252 mojibake
        // repair, BOM/invisible strip, tab/space normalize, line-break-hyphen
        // collapse — all previously absent here. The prior hand-rolled subset
        // (mojibake/control strip, PUA/C1 filter, nbsp/soft-hyphen, CRLF,
        // collapseLineBreakHyphens, blank-line collapse) is fully subsumed by
        // `normalizeUniversal` (stripMojibakeAndControlCharacters already covers
        // PUA + C1). hardWrapped:false — HTML/EPUB emit real paragraphs.
        // normalizeUniversal is idempotent, so EPUB's later normalizeDisplay
        // re-pass over the joined chapters causes no length drift and the
        // per-chapter offset map stays aligned.
        TextNormalizer.normalizeUniversal(text)
    }
    // (collapseLineBreakHyphens removed 2026-06-08 — subsumed by the shared
    //  TextNormalizer.stripLineBreakHyphens inside normalizeUniversal.)
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

    /// 2026-05-27 — Strip Wikipedia-style infobox tables before
    /// Readability runs. Wikipedia article imports were opening at the
    /// infobox content ("Pride and Prejudice / Title page of the first
    /// edition, 1813 / Author / Jane Austen / …") instead of the
    /// article body. Readability keeps infoboxes because they're
    /// inside the article element. Stripping them at the raw-HTML
    /// stage moves the reader directly to the prose.
    ///
    /// The class match is conservative: `class="infobox"` or
    /// `class="infobox <suffix>"` (Wikipedia uses `infobox biography`,
    /// `infobox book`, `infobox vcard`, etc.). Plus `vertical-navbox`
    /// and `navbox` which are chrome at article end. Non-Wikipedia HTML
    /// rarely uses these class names; safe to apply unconditionally.
    static func stripWikipediaChrome(rawHTML: String) -> String {
        let patterns: [String] = [
            // Infobox tables — match opening tag with class containing
            // "infobox" word-boundary, then everything up to closing
            // </table>. NSRegularExpression doesn't support nested
            // table matching, but Wikipedia infoboxes don't nest tables
            // inside themselves often enough for this to matter; if
            // they do, we trim conservatively rather than aggressively.
            #"(?si)<table[^>]*\bclass\s*=\s*["'][^"']*\binfobox\b[^"']*["'][^>]*>.*?</table\s*>"#,
            // Navboxes (article-end chrome).
            #"(?si)<table[^>]*\bclass\s*=\s*["'][^"']*\b(?:navbox|vertical-navbox)\b[^"']*["'][^>]*>.*?</table\s*>"#,
            // Side-bar / hat-note / disambiguation chrome.
            #"(?si)<(?:div|table)[^>]*\bclass\s*=\s*["'][^"']*\b(?:sidebar|hatnote|dablink)\b[^"']*["'][^>]*>.*?</(?:div|table)\s*>"#,
            // 2026-06-05 — "[edit]" section-edit links. Wikipedia wraps each
            // heading's edit affordance in <span class="mw-editsection">…[…edit…]…
            // </span> (nested bracket spans). It renders as a literal "[edit]"
            // that leaks into the heading line in plainText → spoken by TTS (c14)
            // and visible in the reader (c3). Match from the editsection span open
            // lazily to the closing "]"/&#93; + its two </span> closes.
            #"(?si)<span[^>]*\bclass\s*=\s*["'][^"']*\bmw-editsection\b[^"']*["'][^>]*>.*?(?:\]|&#93;)\s*</span>\s*</span>"#,
            // 2026-06-05 — LibriVox / audio <figure>. The article embeds a
            // "LibriVox recording by …" audio player whose <figcaption> leaks in
            // as the very first plainText line (chrome, not article prose).
            // Strip any <figure> that contains an <audio> element.
            #"(?si)<figure\b[^>]*>(?:(?!</figure>).)*?<audio\b(?:(?!</figure>).)*?</figure\s*>"#,
            // 2026-06-07 — Wikipedia CS1 citation error/maintenance messages.
            // Wikipedia wraps editor-facing citation diagnostics in
            // <span class="cs1-hidden-error citation-comment">, "cs1-visible-error
            // citation-comment", and "cs1-maint citation-comment". These render
            // (some hidden, some visible-red) as cruft like
            //   "{{cite news}}: CS1 maint: url-status (link)"
            //   "{{cite book}}: ISBN / Date incompatibility (help)"
            // and leak into References → plainText (c1/c3 junk; spoken by TTS, c14).
            // The shared, stable marker across all variants is the
            // `citation-comment` class. Each such span is self-contained (no nested
            // <span>), so a lazy match to the first </span> is safe. This strips the
            // WHOLE category of CS1/CS2 citation-comment diagnostics, not just the
            // two seen in Pride-and-Prejudice (Rule 10 generalization).
            #"(?si)<span[^>]*\bclass\s*=\s*["'][^"']*\bcitation-comment\b[^"']*["'][^>]*>.*?</span\s*>"#,
        ]
        var html = rawHTML
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            html = regex.stringByReplacingMatches(
                in: html,
                range: NSRange(html.startIndex..., in: html),
                withTemplate: " "
            )
        }
        return html
    }

    /// 2026-05-20 — Strip Project Gutenberg's `<p class="asterism">`
    /// scene-break blocks. Mirror of `EPUBDocumentImporter.stripAsterismBlocks`
    /// — applied to standalone HTML imports so the same fix covers
    /// .html source files imported directly into Posey.
    /// See EPUBDocumentImporter for full rationale.
    static func stripAsterismBlocks(from data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return data
        }
        let patterns: [String] = [
            #"(?si)<p[^>]*\bclass\s*=\s*"[^"]*\basterism\b[^"]*"[^>]*>.*?</p\s*>"#,
            #"(?si)<p[^>]*\bclass\s*=\s*'[^']*\basterism\b[^']*'[^>]*>.*?</p\s*>"#,
            #"(?si)<div[^>]*\bclass\s*=\s*"[^"]*\basterism\b[^"]*"[^>]*>.*?</div\s*>"#,
            #"(?si)<div[^>]*\bclass\s*=\s*'[^']*\basterism\b[^']*'[^>]*>.*?</div\s*>"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            html = regex.stringByReplacingMatches(
                in: html,
                range: NSRange(html.startIndex..., in: html),
                withTemplate: " "
            )
        }
        return html.data(using: .utf8) ?? data
    }
}
// ========== BLOCK 4: INLINE IMAGE EXTRACTION - END ==========
