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
        // 2026-06-11 — strip code-block LANGUAGE-LABEL chrome. MDN (and other
        // doc sites) render fenced code as
        //   <div class="code-example"><div class="example-header">
        //     <span class="language-name">http</span></div><pre><code>…</code></pre></div>
        // The `example-header` is a UI label, not content; without stripping it
        // a bare "http" / "html" line leaks into the reading text right before
        // every code block (c3 fidelity defect). Remove the header div; keep the
        // <pre><code> body. Shared pre-clean, not an mdn special-case.
        let preCleanedHTML = Self.stripCodeExampleHeaders(
            from: Self.stripWikipediaChrome(rawHTML: rawHTML))
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
        let (displayTextHeadings, headings) = reinjectArticleHeadings(
            into: displayTextRaw,
            specs: extractHeadingSpecs(fromHTML: preCleanedHTML)
        )
        // 2026-06-11 — restore a lede Readability dropped (no-op if it survived).
        let displayTextLede = reinjectDroppedLede(
            into: displayTextHeadings, preCleanedHTML: preCleanedHTML)
        // 2026-06-11 (auditor product call) — reinject the author as PLAIN byline
        // text at the top (under the title), since isBylineHeading removed it from
        // headings (and Readability dropped it from the body). Not a heading, not
        // a TOC entry — a reader still gets attribution. No-op when there is no
        // byline (mdn/Wikipedia) or it's already present.
        let displayText = prependByline(
            extractByline(fromHTML: preCleanedHTML), to: displayTextLede)
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
        // Capture the level digit, the open-tag ATTRIBUTES, and the inner
        // content. `(?s)` makes `.` cross newlines so headings spanning multiple
        // source lines still match. `?` keeps the inner match non-greedy so
        // consecutive headings don't merge. The attributes (group 2) feed the
        // byline filter below.
        let pattern = #"(?si)<h([1-6])\b([^>]*)>(.*?)</h\1\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var out: [HTMLHeadingEntry] = []
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges == 4,
                  let lvlR = Range(match.range(at: 1), in: html),
                  let attrR = Range(match.range(at: 2), in: html),
                  let txtR = Range(match.range(at: 3), in: html),
                  let level = Int(String(html[lvlR])) else { continue }
            let raw = String(html[txtR])
            let stripped = stripHeadingInnerTags(raw)
            let decoded = decodeMinimalEntities(stripped)
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !Self.isBylineHeading(attrs: String(html[attrR]),
                                        innerHTML: raw, text: trimmed) else { continue }
            out.append(HTMLHeadingEntry(level: level, title: trimmed))
        }
        return out
    }

    /// 2026-06-11 (auditor ruling) — an author/byline node marked up as a heading
    /// is metadata, NOT a section heading: it must never enter heading detection
    /// or the TOC. A flat article's TOC should be its title or empty, never the
    /// author's name. CATEGORY (Rule 10): "byline/author element styled as <hN>."
    /// Seen on codinghorror (Ghost): `<h4 class="gh-article-author-name">
    /// <a href="/author/jeff-atwood/">Jeff Atwood</a></h4>` became the lone TOC
    /// entry while the title was dropped. Generalize across HTML by the common
    /// authorship signals — class/itemprop/rel containing "author", an
    /// `<a href="/author/…">` link, or a "Written by …" lead-in. Conservative:
    /// these signals appear in metadata, not in genuine section titles.
    private static func isBylineHeading(attrs: String, innerHTML: String, text: String) -> Bool {
        let a = attrs.lowercased()
        // class="…author…", itemprop="author", rel="author" (rel may also be on
        // the inner <a>, covered below).
        if a.contains("author") { return true }
        let inner = innerHTML.lowercased()
        if inner.contains("href=\"/author/") || inner.contains("rel=\"author\"")
            || inner.contains("itemprop=\"author\"") { return true }
        if text.range(of: #"(?i)^\s*written by\b"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// 2026-06-11 (auditor product call) — the author's NAME for plain-byline
    /// reinjection. Returns the first byline heading's text with a "Written by "
    /// lead-in stripped (so "<h4>Written by Jeff Atwood</h4>" → "Jeff Atwood"),
    /// or nil if the doc has no byline. Same detection as isBylineHeading; the
    /// FIRST match wins (the author-name node precedes the footer "Written by"
    /// bio in the markup we've seen).
    private func extractByline(fromHTML html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?si)<h([1-6])\b([^>]*)>(.*?)</h\1\s*>"#) else { return nil }
        let ns = html as NSString
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges == 4 else { continue }
            let attrs = ns.substring(with: m.range(at: 2))
            let inner = ns.substring(with: m.range(at: 3))
            let text = decodeMinimalEntities(stripHeadingInnerTags(inner))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  Self.isBylineHeading(attrs: attrs, innerHTML: inner, text: text) else { continue }
            let name = text.replacingOccurrences(
                of: #"(?i)^\s*written by\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Prepend the author byline as plain prose at the top of the body (under the
    /// title), in the natural spoken-attribution form "By <author>" (Mark's call,
    /// 2026-06-11 — it's the opener of the listening experience, so it should read
    /// as attribution, not a bare name). No-op when there is no byline or the name
    /// is already the leading text.
    private func prependByline(_ byline: String?, to text: String) -> String {
        guard let byline, !byline.isEmpty else { return text }
        let head = String(text.prefix(byline.count + 8))
        if head.contains(byline) { return text }   // already present at the top
        return "By " + byline + "\n\n" + text
    }

    private func stripHeadingInnerTags(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return s }
        let range = NSRange(s.startIndex..., in: s)
        // 2026-06-13 — Replace tags with a SPACE (not ""), then collapse runs.
        // A heading like `CHAPTER I.<br>The Period` (tale-of-two-cities — every
        // one of its 45 chapter headings) must become "CHAPTER I. The Period",
        // NOT "CHAPTER I.The Period": the empty replacement glued the tokens, and
        // the title then failed to match the body text (where <br> renders as a
        // newline), so the heading was dropped in resolveHeadingOffsets. Keeping
        // the boundary as a space lets the whitespace-flexible body search find
        // it. No effect on headings without inner tags.
        let spaced = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
        return spaced
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let pattern = #"(?si)<h([1-6])\b([^>]*)>(.*?)</h\1\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        var specs: [HeadingSpec] = []
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges == 4,
                  let level = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let attrs = ns.substring(with: m.range(at: 2))
            let innerHTML = ns.substring(with: m.range(at: 3))
            let title = decodeMinimalEntities(stripHeadingInnerTags(innerHTML))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  !Self.chromeHeadingDenylist.contains(title.lowercased()),
                  !Self.isBylineHeading(attrs: attrs, innerHTML: innerHTML, text: title) else { continue }
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

    // 2026-06-11 — Restore a dropped article LEDE.
    // CATEGORY (Rule 10): "leading article prose that Mozilla Readability scored
    // out." Readability keeps high-text-density containers; when a site wraps its
    // intro in a low-density wrapper, the whole wrapper is dropped. MDN's HTTP
    // pages put the lede in `<section>…</section>` BEFORE the first `<h2>` — that
    // section scores low and Readability drops it, so plainText starts at the
    // first heading ("Types of caches") and loses the 4 intro paragraphs.
    // reinjectArticleHeadings restores dropped *headings* but the lede has no
    // heading, so the prose was lost. EDGE CASES: Wikipedia/most articles put the
    // lede in plain `<p>` directly under the content root — Readability KEEPS it,
    // so this must be a NO-OP there. We guarantee that by prepending ONLY the
    // leading run of substantial pre-heading paragraphs that are ABSENT from the
    // Readability output; the moment a paragraph is found present, the lede is
    // judged to have survived and nothing is prepended. Verified MDN (lede
    // restored) + Wikipedia P&P / Dracula (untouched — first lede para present).
    private func reinjectDroppedLede(into displayText: String,
                                     preCleanedHTML: String) -> String {
        // Region = the prose between the article title (`</h1>`) and the first
        // section (`<h2>`). The lede is, by definition, body prose that precedes
        // any section heading. We deliberately do NOT match the first heading by
        // TITLE: real heading markup wraps the text in anchors/comments
        // (MDN: `<h2 id=…><!--lit-node--><a class="heading-anchor">Types of caches</a>`),
        // so a "title right after `>`" cut silently misses. Scoping by tag
        // structure (after </h1>, before first <h2>) is robust to that.
        // CONSERVATIVE: if there is no `<h1>` we can't safely separate lede from
        // site nav, so we bail (no-op) rather than risk prepending chrome.
        guard let h1 = preCleanedHTML.range(of: #"(?si)</h1\s*>"#, options: .regularExpression)
        else { return displayText }
        var region = String(preCleanedHTML[h1.upperBound...])
        if let h2 = region.range(of: #"(?si)<h2\b"#, options: .regularExpression) {
            region = String(region[..<h2.lowerBound])
        }
        // Substantial prose paragraphs, in order. The length + sentence-punctuation
        // gates exclude nav/breadcrumb/TOC <a> fragments; hatnote gate excludes
        // "Main article:" style lead-ins. Single pass with early break: collect the
        // LEADING run of paragraphs ABSENT from the Readability output; stop at the
        // first one that survived (proof the lede is already present → no-op, which
        // is what happens for Wikipedia/Dracula whose lede Readability keeps).
        guard let regex = try? NSRegularExpression(
            pattern: #"(?si)<(p|li|blockquote|dd)\b[^>]*>(.*?)</\1\s*>"#) else { return displayText }
        let rns = region as NSString
        let folded = foldPunctuation(displayText)
        var missing: [String] = []
        for m in regex.matches(in: region, range: NSRange(location: 0, length: rns.length)) {
            let text = decodeMinimalEntities(stripTagsToSpaces(rns.substring(with: m.range(at: 2))))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 60, text.contains(". ") || text.hasSuffix(".") else { continue }
            if let hp = Self.hatnotePattern,
               hp.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { continue }
            if folded.contains(foldPunctuation(String(text.prefix(60)))) { break }
            missing.append(text)
        }
        guard !missing.isEmpty else { return displayText }
        print("PoseyHTML: reinjected dropped lede — \(missing.count) paragraph(s)")
        return missing.joined(separator: "\n\n") + "\n\n" + displayText
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
        // 2026-06-11 — strip code-block LANGUAGE-LABEL chrome. MDN (and other
        // doc sites) render fenced code as
        //   <div class="code-example"><div class="example-header">
        //     <span class="language-name">http</span></div><pre><code>…</code></pre></div>
        // The `example-header` is a UI label, not content; without stripping it
        // a bare "http" / "html" line leaks into the reading text right before
        // every code block (c3 fidelity defect). Remove the header div; keep the
        // <pre><code> body. Shared pre-clean, not an mdn special-case.
        let preCleanedHTML = Self.stripCodeExampleHeaders(
            from: Self.stripWikipediaChrome(rawHTML: rawHTML))
        let cleanedHTML = await ReadabilityExtractor.extractArticleHTML(
            rawHTML: preCleanedHTML, baseURL: nil
        )
        let workingData: Data
        if let cleanedHTML, let cleanedData = cleanedHTML.data(using: .utf8) {
            workingData = cleanedData
        } else {
            workingData = data
        }
        let textRaw = try loadText(fromData: workingData)
        let headings = extractHeadings(fromRawData: workingData)
        // 2026-06-11 — restore a lede Readability dropped (no-op if it survived);
        // parity with the url-based loadDocument path.
        let textLede = reinjectDroppedLede(
            into: textRaw, preCleanedHTML: preCleanedHTML)
        // 2026-06-11 — reinject author as plain byline text (parity with loadDocument).
        let text = prependByline(extractByline(fromHTML: preCleanedHTML), to: textLede)
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

    /// Remove the code-block LANGUAGE-LABEL header that doc sites render above
    /// fenced code (MDN: `<div class="example-header"><span
    /// class="language-name">http</span></div>`). Left in, it leaks a bare
    /// "http" / "html" line into the reading text before each code block — a c3
    /// fidelity defect. Strips the whole `example-header` div (the label is the
    /// only thing inside it); the `<pre><code>` body that follows is untouched.
    /// Also strips a lone `<span class="language-name">…</span>` as a fallback
    /// for sites that don't wrap it in an `example-header` div.
    static func stripCodeExampleHeaders(from rawHTML: String) -> String {
        var html = rawHTML
        let patterns = [
            #"(?si)<div[^>]*\bclass\s*=\s*["'][^"']*\bexample-header\b[^"']*["'][^>]*>.*?</div\s*>"#,
            #"(?si)<span[^>]*\bclass\s*=\s*["'][^"']*\blanguage-name\b[^"']*["'][^>]*>.*?</span\s*>"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            html = regex.stringByReplacingMatches(
                in: html,
                range: NSRange(html.startIndex..., in: html),
                withTemplate: ""
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
