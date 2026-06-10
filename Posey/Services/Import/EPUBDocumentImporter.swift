import Foundation

// ========== BLOCK 01: MODELS AND ERRORS - START ==========

/// One entry in the EPUB table of contents. Character offsets are into the
/// document's plainText and are used to jump to the right position in the reader.
struct EPUBTOCEntry {
    let title: String
    /// 0-based character offset into the combined plainText at which this
    /// section starts. -1 means the offset could not be determined.
    let plainTextOffset: Int
    /// Original play order from the nav/NCX document (1-based).
    let playOrder: Int
    /// Heading level inferred from nav/NCX nesting depth (1 = top-level
    /// chapter, 2+ = nested section). Defaults to 1 when no nesting
    /// signal is available (e.g. spine-fallback synthesized TOCs).
    let level: Int
}

/// One heading found in the body via a native `<h1>`–`<h6>` tag.
/// 2026-06-10 (fix-pass) — the body-`<hN>` heading source that replaces
/// fuzzy nav-title resolution for c4 heading promotion. `offset` is into
/// the combined plainText; `level` is the `<hN>` level; `title` is the
/// EXACT heading text (so `applyHeadingMarkers` promotes by title match).
struct EPUBBodyHeading {
    let offset: Int
    let level: Int
    let title: String
}

struct ParsedEPUBDocument {
    let title: String?
    /// **Bundle 2 follow-up (2026-05-26)** — edition-disambiguating
    /// metadata extracted from the OPF's Dublin Core elements.
    /// `creator` is the first `<dc:creator>`; `illustrator` is the
    /// first `<dc:contributor opf:role="ill">`. The library card
    /// surfaces these when two documents share the same title so
    /// the user can tell editions apart (two Alice editions where
    /// one is illustrated by Robinson, etc.).
    let creator: String?
    let illustrator: String?
    /// Normalized text with inline \x0c-delimited visual-image markers
    /// [[POSEY_VISUAL_PAGE:0:uuid]] at each <img> position.
    let displayText: String
    /// Plain text without any image markers — used for TTS segmentation.
    let plainText: String
    /// One record per inline image extracted from the EPUB content.
    let images: [PageImageRecord]
    /// Table of contents entries in reading order. Empty if no nav/NCX was found.
    let tocEntries: [EPUBTOCEntry]
    /// Headings found directly in the body via native `<h1>`–`<h6>` tags,
    /// in reading order. Drives c4 heading promotion (see `EPUBBodyHeading`).
    let bodyHeadings: [EPUBBodyHeading]
    /// Character offset in plainText past which the reader should
    /// auto-jump on first open. Set non-zero by `EPUBFrontMatterDetector`
    /// when the spine starts with auto-generator boilerplate (the
    /// Internet Archive `hocr-to-epub` pipeline being the canonical
    /// case). 0 means "no skip" — the document opens at offset 0.
    let playbackSkipUntilOffset: Int
}

struct EPUBDocumentImporter {
    enum ImportError: LocalizedError, Equatable {
        case unreadableDocument
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "Posey could not read that EPUB file."
            case .emptyDocument:
                return "The EPUB file is empty."
            }
        }
    }

    private let htmlImporter = HTMLDocumentImporter()
}

// ========== BLOCK 01: MODELS AND ERRORS - END ==========

// ========== BLOCK 02: PUBLIC ENTRY POINTS - START ==========

extension EPUBDocumentImporter {

    func loadDocument(from url: URL) throws -> ParsedEPUBDocument {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isDirectory {
            return try loadDocumentFromDirectory(url)
        } else {
            let data = try Data(contentsOf: url)
            return try loadDocument(fromData: data)
        }
    }

    func loadDocument(fromData data: Data) throws -> ParsedEPUBDocument {
        let archive: ZIPArchive
        do {
            archive = try ZIPArchive(data: data)
        } catch {
            throw ImportError.unreadableDocument
        }
        return try loadDocument(
            containerXMLLoader: {
                do { return try archive.entryData(named: "META-INF/container.xml") }
                catch { throw ImportError.unreadableDocument }
            },
            packageXMLLoader: { path in
                do { return try archive.entryData(named: path) }
                catch { throw ImportError.unreadableDocument }
            },
            entryLoader: { path in try? archive.entryData(named: path) }
        )
    }

    private func loadDocumentFromDirectory(_ baseURL: URL) throws -> ParsedEPUBDocument {
        func read(_ path: String) throws -> Data {
            try Data(contentsOf: baseURL.appendingPathComponent(path))
        }
        return try loadDocument(
            containerXMLLoader: {
                do { return try read("META-INF/container.xml") }
                catch { throw ImportError.unreadableDocument }
            },
            packageXMLLoader: { path in
                do { return try read(path) }
                catch { throw ImportError.unreadableDocument }
            },
            entryLoader: { path in try? read(path) }
        )
    }
}

// ========== BLOCK 02: PUBLIC ENTRY POINTS - END ==========

// ========== BLOCK 03: CORE DOCUMENT LOADING - START ==========

extension EPUBDocumentImporter {

    /// Shared loading logic for both zip and directory EPUBs.
    private func loadDocument(
        containerXMLLoader: () throws -> Data,
        packageXMLLoader: (String) throws -> Data,
        entryLoader: (String) -> Data?
    ) throws -> ParsedEPUBDocument {

        let containerXML  = try containerXMLLoader()
        let packagePath   = try EPUBContainerParser.packageDocumentPath(from: containerXML)
        let packageXML    = try packageXMLLoader(packagePath)
        let packageDoc    = try EPUBPackageParser.parse(packageXML)

        let baseDirectory = (packagePath as NSString).deletingLastPathComponent

        // Build list of (archivePath, originalHref) pairs for the spine.
        // originalHref is stored so we can match it against TOC entry hrefs later.
        let spineItems: [(path: String, href: String)] = packageDoc.spineItemReferences.compactMap { idref in
            guard let item = packageDoc.manifestItems[idref] else { return nil }
            let path = resolveArchivePath(baseDirectory: baseDirectory, relativePath: item.href)
            return (path, item.href)
        }

        // Task 4 #5 — front-matter is now STRIPPED from the
        // extracted text entirely (was: kept in text and skipped
        // via playbackSkipUntilOffset). Mark's Task 3 EPUB conv
        // showed the Internet Archive disclaimer
        // ("This book was produced in EPUB format by the Internet
        // Archive…") leaking into RAG chunks because the skip
        // offset only affected the reader/playback, not RAG. Now
        // detection runs FIRST against parsed candidates, then
        // chapter concatenation skips any spine item identified
        // as front matter — so plainText, displayText, RAG chunks,
        // search index, and audio export all just don't see it.
        struct ChapterRecord {
            let path: String
            let href: String
            let bareHref: String
            let html: String
            let chapterText: String
            let plainText: String
            let anchors: [EPUBAnchorExtractor.ExtractionResult.Anchor]
            /// Native `<hN>` headings with CHAPTER-LOCAL plainText offsets +
            /// exact title text. Promoted to global offsets in pass 2.
            let headings: [(level: Int, localOffset: Int, title: String)]
            let images: [PageImageRecord]
        }
        var allChapters: [ChapterRecord] = []
        var frontMatterCandidates: [EPUBFrontMatterDetector.SpineCandidate] = []

        // Pass 1 — load + parse every spine item. Cumulative-offset
        // accounting waits for pass 2 (after front-matter filtering)
        // so offsets reflect the FINAL plainText layout.
        for (path, href) in spineItems {
            guard let chapterData = entryLoader(path) else { continue }
            let chapterDir = (path as NSString).deletingLastPathComponent
            let bareHref = (href as NSString).lastPathComponent
                .components(separatedBy: "#").first ?? ""

            // Front-matter detection inspects only the first few
            // spine items (front matter is by definition at the
            // front). Memory cost capped by the candidate window.
            // We use offset 0 here as a placeholder — the detector
            // only cares about ORDER, not absolute offsets, when
            // deciding what's front matter.
            if frontMatterCandidates.count < 5,
               let html = String(data: chapterData, encoding: .utf8)
                       ?? String(data: chapterData, encoding: .isoLatin1) {
                frontMatterCandidates.append(EPUBFrontMatterDetector.SpineCandidate(
                    href: href,
                    plainTextStartOffset: 0,
                    html: html
                ))
            }

            // Task 8 #2 (2026-05-03): strip embedded TOC blocks from
            // spine HTML before text extraction. Project Gutenberg's
            // EPUB pipeline puts the rendered chapter list inside
            // `<p class="toc">` (sometimes `<div class="toc">`) in
            // the spine item right after the PG header. Without this
            // strip, TTS reads "Chapter: I., II., III., IV., V., …"
            // aloud — annoying. Also catches Calibre's `<nav id="toc">`
            // and ARIA `<nav epub:type="toc">` patterns.
            let tocStripped = Self.stripEmbeddedTOC(from: chapterData)
            // 2026-05-20 — strip Project Gutenberg's scene-break
            // <p class="asterism">…</p> blocks BEFORE NSAttributedString
            // parsing. The class attribute is lost during HTML→text
            // conversion, so without this pre-strip the literal
            // "*   *   *   *   *" rows leak into plainText (read aloud
            // by TTS as "star star star…") and into displayText
            // (rendered as a stack of asterisk rows in the reader).
            let asterismStripped = Self.stripAsterismBlocks(from: tocStripped)
            // 2026-05-21 — strip dropcap span wrappers BEFORE
            // NSAttributedString conversion. Gutenberg's illustrated-
            // edition ebookmaker and many publisher EPUBs wrap the
            // chapter's opening letter in a floated/styled `<span>`
            // to render an illuminated initial. NSAttributedString
            // treats `float:left` (and class-tagged dropcaps) as a
            // block-level break, so plainText ends up with the dropcap
            // letter on its own line: e.g. "A\nlice was beginning…"
            // for Sam'l Gabriel Sons' 1916 Alice (Gutenberg #19033).
            // TTS reads that as "A" pause "lice." Fix is generic:
            // unwrap the span and keep the inner letter inline with
            // the following text. See `stripDropcapSpans` for the
            // class/style patterns matched.
            let dropcapStripped = Self.stripDropcapSpans(from: asterismStripped)
            // 2026-06-10 — insert native `<hN>` heading sentinels (then anchor
            // sentinels) so heading positions survive the HTML→plainText
            // conversion. Both land before their tag's text; extraction below
            // recovers them together.
            let headingMarked = EPUBAnchorExtractor.insertHeadingSentinels(from: dropcapStripped)
            let anchorMarked = EPUBAnchorExtractor.insertAnchorSentinels(from: headingMarked)

            let (processedData, chapterImages) = extractInlineImages(
                from: anchorMarked,
                chapterBasePath: chapterDir,
                entryLoader: entryLoader
            )

            guard let chapterText = try? htmlImporter.loadText(fromData: processedData)
            else { continue }
            // `chapterText` still carries the anchor sentinels. Strip
            // them and record per-anchor offsets relative to the
            // chapter's final plainText.
            let plainWithAnchors = buildPlainText(from: chapterText)
            let extraction = EPUBAnchorExtractor.extractAnchors(from: plainWithAnchors)
            // 2026-06-10 — resolve each `<hN>` sentinel's title from the
            // chapter's final plainText (the heading text runs from the
            // sentinel position to the next line break). Drop empty headings
            // (decorative `<hN></hN>`).
            let chapterHeadings: [(level: Int, localOffset: Int, title: String)] =
                extraction.headings.compactMap { hit in
                    let title = Self.headingTitle(in: extraction.plainText, at: hit.offset)
                    guard !title.isEmpty else { return nil }
                    return (hit.level, hit.offset, title)
                }
            allChapters.append(ChapterRecord(
                path: path,
                href: href,
                bareHref: bareHref,
                html: String(data: chapterData, encoding: .utf8) ?? "",
                chapterText: chapterText,
                plainText: extraction.plainText,
                anchors: extraction.anchors,
                headings: chapterHeadings,
                images: chapterImages
            ))
        }

        // Detect front matter. Strip those spine items from the
        // chapter list entirely. Whatever remains is the document
        // the user reads / Posey indexes / playback narrates.
        let frontMatterResult = EPUBFrontMatterDetector.detect(
            spineItems: frontMatterCandidates
        )
        let strippedChapters = allChapters.filter { record in
            !frontMatterResult.frontMatterHrefs.contains(record.bareHref)
        }
        if !frontMatterResult.frontMatterHrefs.isEmpty {
            dbgLog("EPUB import: stripped %d front-matter spine items: %@",
                  allChapters.count - strippedChapters.count,
                  Array(frontMatterResult.frontMatterHrefs).joined(separator: ", ") as NSString)
        }
        guard !strippedChapters.isEmpty else { throw ImportError.emptyDocument }

        // Pass 2 — build the final cumulative-offset map from
        // the post-strip chapter list so TOC entries land at the
        // right place in the now-shorter plainText.
        var chapterTexts: [String] = []
        var chapterPlainLengths: [Int] = []
        var imageRecords: [PageImageRecord] = []
        var pathToPlainOffset: [String: Int] = [:]
        var bodyHeadings: [EPUBBodyHeading] = []
        for record in strippedChapters {
            let cumulativeOffset = chapterPlainLengths.reduce(0, +)
                + max(0, chapterPlainLengths.count - 1) * 2
            // 2026-06-10 — promote this chapter's native `<hN>` headings to
            // global plainText offsets (same cumulative accounting as anchors).
            // Offsets are approximate (post-normalization drift) but the EXACT
            // title makes applyHeadingMarkers promote the right unit anyway.
            for h in record.headings {
                bodyHeadings.append(EPUBBodyHeading(
                    offset: cumulativeOffset + h.localOffset,
                    level: h.level,
                    title: h.title
                ))
            }
            if !record.bareHref.isEmpty && pathToPlainOffset[record.bareHref] == nil {
                pathToPlainOffset[record.bareHref] = cumulativeOffset
            }
            // 2026-05-21 — record per-fragment offsets so TOC entries
            // pointing at `file.xhtml#fragment` can resolve to a
            // position INSIDE the spine file, not just its start.
            // Each anchor's chapter-local offset is promoted to a
            // global offset by adding the chapter's cumulative start.
            // Conflicts ("first wins") preserve the earliest anchor
            // when a fragment id happens to appear in more than one
            // spine item (rare; defensive).
            if !record.bareHref.isEmpty {
                for anchor in record.anchors {
                    let key = "\(record.bareHref)#\(anchor.fragmentID)"
                    if pathToPlainOffset[key] == nil {
                        pathToPlainOffset[key] = cumulativeOffset + anchor.offset
                    }
                }
            }
            chapterTexts.append(record.chapterText)
            chapterPlainLengths.append(record.plainText.count)
            imageRecords.append(contentsOf: record.images)
        }

        guard !chapterTexts.isEmpty else { throw ImportError.emptyDocument }

        // 2026-05-06 (parity #2) — displayText KEEPS the visual-page
        // markers; EPUBDisplayParser converts them to .visualPlaceholder
        // blocks at render time (the user sees the image, not the
        // marker text). plainText is the marker-stripped form used for
        // TTS / search / RAG / character count.
        var displayText = normalizeDisplay(chapterTexts.joined(separator: "\n\n"))

        // 2026-05-28 — EPUB cover image preservation (#72). When the
        // OPF declares a cover image (via EPUB 3 `properties="cover-image"`
        // or EPUB 2 `<meta name="cover">`), load its bytes and inject
        // a POSEY_VISUAL_PAGE marker at the very start of displayText
        // so the renderer emits an image unit at sequence 0 — the cover
        // appears above all spine content when the reader scrolls to
        // the top of the document. The cover is excluded from the spine
        // walker because EPUB 3 covers are typically referenced only via
        // OPF properties, not by an `<item>` in the spine, so the existing
        // inline-`<img>` extraction never sees them.
        //
        // No effect on plainText (markers strip on the way to plainText
        // via buildPlainText below) → TOC offsets, smart-skip, note
        // anchors, RAG chunks all unchanged. The cover image bytes ride
        // alongside inline images in the same `imageRecords` array.
        // ContentUnitBuilder maps the resulting visualPlaceholder block
        // to a `.image` ContentUnit at sequence 0.
        var imageRecordsWithCover = imageRecords
        if let coverItemID = packageDoc.coverItemID,
           let coverItem = packageDoc.manifestItems[coverItemID],
           coverItem.mediaType.lowercased().hasPrefix("image/") {
            let archivePath = resolveArchivePath(
                baseDirectory: baseDirectory,
                relativePath: coverItem.href
            )
            if let coverData = entryLoader(archivePath), !coverData.isEmpty {
                let coverImageID = UUID().uuidString
                let coverRecord = PageImageRecord(imageID: coverImageID, data: coverData)
                imageRecordsWithCover = [coverRecord] + imageRecordsWithCover
                let coverMarker = "\u{000C}[[POSEY_VISUAL_PAGE:0:\(coverImageID)]]\u{000C}\n\n"
                displayText = coverMarker + displayText
            }
        }

        let plainText   = buildPlainText(from: displayText)

        // Build TOC entries from nav (EPUB 3) or skip if neither is available.
        var tocEntries = buildTOCEntries(
            packageDoc: packageDoc,
            baseDirectory: baseDirectory,
            entryLoader: entryLoader,
            pathToPlainOffset: pathToPlainOffset
        )
        // Fallback: many auto-generated EPUBs (Internet Archive's
        // hocr-to-epub, some Calibre exports) ship without a usable
        // nav/NCX document. When that happens we synthesize entries
        // from the spine + chapter HTML headings so the user still
        // sees a TOC button. Better than nothing — the eye learns the
        // visible button position regardless of how rich the entries
        // turn out to be.
        if tocEntries.isEmpty {
            // Task 4 #5 (2026-05-03): filter front-matter spine items
            // OUT before synthesis so the resulting TOC doesn't surface
            // "Notice" — the offset-based filter below can't catch
            // synthesized entries when frontMatterCandidates were
            // passed at offset 0 (which is the importer's design).
            let filteredSpineItems = spineItems.filter { spine in
                let bare = (spine.href as NSString).lastPathComponent
                    .components(separatedBy: "#").first ?? ""
                return !frontMatterResult.frontMatterHrefs.contains(bare)
            }
            tocEntries = synthesizeTOCFromSpine(
                spineItems: filteredSpineItems,
                entryLoader: entryLoader,
                pathToPlainOffset: pathToPlainOffset
            )
        }
        // Filter out entries that point at front-matter spine items
        // — there's no value in surfacing "Notice" in a navigation
        // surface the reader can't reach by playback. This applies
        // equally to populated nav/NCX entries that happen to point
        // at a front-matter spine item (rare but possible) and to
        // synthesized entries.
        if !frontMatterResult.frontMatterHrefs.isEmpty {
            tocEntries = tocEntries.filter { entry in
                // Synthesized entries set offsets from pathToPlainOffset;
                // their offset matches the front-matter offset only when
                // we want to drop them. For populated nav entries with
                // an offset of -1 (unmatched href) we keep the entry —
                // we have no way to know whether it's front matter.
                let offset = entry.plainTextOffset
                if offset < 0 { return true }
                return offset >= frontMatterResult.skipUntilOffset
            }
        }

        return ParsedEPUBDocument(
            title: packageDoc.title,
            creator: packageDoc.creator,
            illustrator: packageDoc.illustrator,
            displayText: displayText,
            plainText: plainText,
            images: imageRecordsWithCover,
            tocEntries: tocEntries,
            bodyHeadings: bodyHeadings,
            playbackSkipUntilOffset: frontMatterResult.skipUntilOffset
        )
    }

    /// Reads a heading's title from `text` starting at `offset`: skips leading
    /// whitespace/newlines, then takes characters up to the next newline.
    /// The `<hN>` content becomes a paragraph in the converted plainText, so
    /// this yields the heading line (e.g. "CHAPTER V"). For multi-line headings
    /// (`<h2>CHAPTER I.<br>The Period</h2>` → "CHAPTER I.\nThe Period") it
    /// returns the first line — a valid prefix that applyHeadingMarkers matches.
    static func headingTitle(in text: String, at offset: Int) -> String {
        let chars = Array(text)
        guard offset >= 0, offset < chars.count else { return "" }
        var i = offset
        while i < chars.count, chars[i] == "\n" || chars[i] == " " || chars[i] == "\t" { i += 1 }
        var out = ""
        while i < chars.count, chars[i] != "\n" { out.append(chars[i]); i += 1 }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

// ========== BLOCK 03: CORE DOCUMENT LOADING - END ==========

// ========== BLOCK 04: INLINE IMAGE EXTRACTION - START ==========

extension EPUBDocumentImporter {

    /// Scans raw chapter HTML for <img> tags, loads each image from the EPUB
    /// archive, generates a UUID per image, and replaces each <img> with a
    /// \x0c-delimited visual-page marker. Returns the modified HTML data and
    /// the collected image records.
    private func extractInlineImages(
        from data: Data,
        chapterBasePath: String,
        entryLoader: (String) -> Data?
    ) -> (processedData: Data, images: [PageImageRecord]) {
        guard var html = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .isoLatin1) else {
            return (data, [])
        }

        // Match <img> tags with either single or double-quoted src attributes.
        let pattern = #"<img[^>]+src=["']([^"']+)["'][^>]*\/?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return (data, [])
        }

        var images: [PageImageRecord] = []
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        // Collect replacements in reverse so earlier string indices stay valid.
        var replacements: [(range: Range<String.Index>, marker: String)] = []
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: html),
                  let srcRange  = Range(match.range(at: 1), in: html) else { continue }

            let src = String(html[srcRange])

            // Skip data URIs, absolute URLs, and SVGs (UIImage cannot render SVG).
            let srcLower = src.lowercased()
            guard !srcLower.hasPrefix("data:"),
                  !srcLower.hasPrefix("http"),
                  !srcLower.hasPrefix("//"),
                  !srcLower.hasSuffix(".svg") else { continue }

            let archivePath = resolveArchivePath(baseDirectory: chapterBasePath, relativePath: src)
            guard let imageData = entryLoader(archivePath), !imageData.isEmpty else { continue }

            let imageID = UUID().uuidString
            images.append(PageImageRecord(imageID: imageID, data: imageData))

            // Wrap the marker in \x0c separators so EPUBDisplayParser can split on
            // form-feed to distinguish image blocks from text blocks.
            let marker = "\u{000C}[[POSEY_VISUAL_PAGE:0:\(imageID)]]\u{000C}"
            replacements.append((fullRange, marker))
        }

        for (range, marker) in replacements {
            html.replaceSubrange(range, with: marker)
        }

        // Images were collected in reverse order — restore original order.
        images.reverse()
        return (html.data(using: .utf8) ?? data, images)
    }
}

// ========== BLOCK 04: INLINE IMAGE EXTRACTION - END ==========

// ========== BLOCK 05: NORMALIZATION AND PATH HELPERS - START ==========

extension EPUBDocumentImporter {

    /// Normalizes displayText — preserves \x0c image separators and collapses
    /// excess newlines.
    /// 2026-05-20 — also strips Project Gutenberg's scene-break asterisk
    /// rows (the format-agnostic fallback for content that slipped past
    /// the class-targeted HTML strip in `stripAsterismBlocks`, e.g.
    /// Moby Dick which uses bare `<p>` with no class attribute).
    /// Must run AFTER newline normalization so the line-anchored regex
    /// in `stripAsterismLines` matches consistently.
    private func normalizeDisplay(_ text: String) -> String {
        // 2026-05-21 — chapter texts are concatenated INTO displayText
        // with TOC anchor sentinels still in them. Strip those here so
        // the markers never reach the renderer or the user. plainText
        // is computed from displayText via buildPlainText, so doing the
        // strip here also keeps plainText clean.
        let sentinelStripped = EPUBAnchorExtractor.stripSentinels(from: text)
        let normalized = TextNormalizer.stripMojibakeAndControlCharacters(sentinelStripped)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r",   with: "\n")
        let asterismStripped = TextNormalizer.stripAsterismLines(normalized)
        return asterismStripped
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips visual-page markers from displayText to produce plainText for TTS.
    /// 2026-05-06 — Regex pattern fixed: ICU regex doesn't recognize
    /// `\u{HHHH}` (Swift raw-string syntax). Use `\x{HHHH}` instead.
    /// Previously this was silently failing (try? returned nil) and
    /// markers were leaking through unstripped.
    private func buildPlainText(from displayText: String) -> String {
        var t = displayText
        // Remove [[POSEY_VISUAL_PAGE:...]] (with optional surrounding
        // form-feed separators).
        t = t.replacingOccurrences(
            of: "\\x{000C}?\\[\\[POSEY_VISUAL_PAGE:[^\\]]*\\]\\]\\x{000C}?",
            with: "",
            options: .regularExpression
        )
        t = t.replacingOccurrences(of: "\u{000C}", with: "")  // any stray form-feeds
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveArchivePath(baseDirectory: String, relativePath: String) -> String {
        let baseURL     = URL(fileURLWithPath: baseDirectory, isDirectory: true)
        let resolvedURL = baseURL.appendingPathComponent(relativePath).standardizedFileURL
        var path = resolvedURL.path
        if path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    /// Parses the EPUB nav (EPUB 3) or NCX (EPUB 2) document to build structured
    /// TOC entries with resolved plainText character offsets. Returns empty array
    /// if neither is present or parsing fails.
    private func buildTOCEntries(
        packageDoc: EPUBPackageDocument,
        baseDirectory: String,
        entryLoader: (String) -> Data?,
        pathToPlainOffset: [String: Int]
    ) -> [EPUBTOCEntry] {
        let rawEntries: [RawTOCEntry]

        if let navID = packageDoc.navItemID,
           let navHref = packageDoc.allItemHrefs[navID],
           let navData = entryLoader(resolveArchivePath(baseDirectory: baseDirectory, relativePath: navHref)) {
            // EPUB 3: nav document (XHTML with epub:type="toc").
            rawEntries = EPUBNavTOCParser.parse(navData)
        } else if let ncxID = packageDoc.ncxItemID,
                  let ncxHref = packageDoc.allItemHrefs[ncxID],
                  let ncxData = entryLoader(resolveArchivePath(baseDirectory: baseDirectory, relativePath: ncxHref)) {
            // EPUB 2: NCX document.
            rawEntries = EPUBNCXParser.parse(ncxData)
        } else {
            return []
        }

        guard !rawEntries.isEmpty else { return [] }

        return rawEntries.map { raw in
            // 2026-05-21 — honor the fragment when present. The offset
            // map is now keyed both by file ("alice.xhtml") and by
            // file#fragment ("1342-h-0.htm.xhtml#pgepubid00022"). Try
            // the more specific key first, fall back to the file key
            // if the anchor isn't recorded (rare — happens when the
            // nav references an id that wasn't in the spine's HTML,
            // or when the spine item failed to extract).
            let parts = raw.href.components(separatedBy: "#")
            let filePart = parts.first ?? ""
            let bareHref = (filePart as NSString).lastPathComponent
            let fragment = parts.count > 1 ? parts[1] : ""
            let fragmentKey = fragment.isEmpty ? nil : "\(bareHref)#\(fragment)"
            let offset = (fragmentKey.flatMap { pathToPlainOffset[$0] })
                ?? pathToPlainOffset[bareHref]
                ?? -1
            // Strip Gutenberg's illustrated-edition caption prefix
            // ("Figure caption. CHAPTER N." → "CHAPTER N."). Conservative
            // regex; pass-through when no caption pattern is detected.
            let cleanedTitle = EPUBAnchorExtractor.cleanGutenbergCaptionPrefix(raw.title)
            return EPUBTOCEntry(
                title: cleanedTitle,
                plainTextOffset: offset,
                playOrder: raw.playOrder,
                level: raw.level
            )
        }
    }

    /// Build a TOC by walking the spine and pulling chapter titles from
    /// each spine item's HTML. Used as a fallback when the EPUB has no
    /// nav (EPUB 3) or NCX (EPUB 2) document, or has one that yields
    /// zero usable entries — common for auto-generated EPUBs from
    /// scanner pipelines like the Internet Archive's hocr-to-epub. The
    /// resulting TOC is intentionally lossy (one entry per spine file,
    /// not per heading-within-chapter) but it ensures the TOC button
    /// appears so the user can navigate by chapter.
    fileprivate func synthesizeTOCFromSpine(
        spineItems: [(path: String, href: String)],
        entryLoader: (String) -> Data?,
        pathToPlainOffset: [String: Int]
    ) -> [EPUBTOCEntry] {
        var entries: [EPUBTOCEntry] = []
        var playOrder = 0
        for (index, spine) in spineItems.enumerated() {
            let bareHref = (spine.href as NSString).lastPathComponent
                .components(separatedBy: "#").first ?? ""
            let offset = pathToPlainOffset[bareHref] ?? -1
            // Title preference: first <h1>/<h2>/<h3> in the chapter's HTML
            // → <title> element → file name without extension → "Chapter N".
            var title: String? = nil
            if let data = entryLoader(spine.path) {
                title = Self.extractFirstHeadingTitle(from: data)
            }
            if title == nil || title?.isEmpty == true {
                let stem = ((spine.href as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                if !stem.isEmpty && stem != "ch" && stem != "index" && !stem.allSatisfy({ $0.isNumber }) {
                    title = stem.replacingOccurrences(of: "_", with: " ")
                                 .replacingOccurrences(of: "-", with: " ")
                }
            }
            if title == nil || title?.isEmpty == true {
                title = "Chapter \(index + 1)"
            }
            playOrder += 1
            entries.append(EPUBTOCEntry(
                title: title!.trimmingCharacters(in: .whitespacesAndNewlines),
                plainTextOffset: offset,
                playOrder: playOrder,
                level: 1
            ))
        }
        return entries
    }

    /// Lightweight, parser-free heading extractor. Tries, in order:
    /// the first opening `<h1>`/`<h2>`/`<h3>` tag, then the document's
    /// `<title>` element. Returns the first non-empty match's text
    /// stripped of nested tags. Falls back to nil if nothing matches.
    /// The deliberate non-XMLParser approach keeps this resilient
    /// against the malformed HTML that hocr-to-epub-style scanned
    /// EPUBs commonly produce — and crucially, those pipelines
    /// typically populate `<title>` (e.g. "Page 1") even when no
    /// `<h*>` headings are present, so the title fallback is what
    /// makes the synthesized TOC useful for scanned books.
    /// Task 8 #2 (2026-05-03): strip embedded TOC blocks from spine
    /// HTML so TTS doesn't read the navigation list aloud.
    ///
    /// Catches three patterns:
    ///   - `<p class="…toc…">…</p>` — Project Gutenberg's
    ///     ebookmaker convention (P&P, Crime and Punishment, etc.).
    ///   - `<div class="…toc…">…</div>` — Calibre + ebookmaker
    ///     wrap variants. Includes the multi-paragraph "table of
    ///     contents" container.
    ///   - `<nav epub:type="toc">…</nav>` and `<nav id="toc">…</nav>`
    ///     — EPUB 3 ARIA convention occasionally embedded in spine
    ///     items (vs the separate nav document).
    ///
    /// Conservative on the `class` match: requires `toc` as a
    /// distinct token (not "stockton" → "toc" substring). Anchored
    /// to attribute-value boundaries via the regex.
    static func stripEmbeddedTOC(from data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return data
        }

        // Patterns are case-insensitive, allow whitespace/attrs in any
        // order, and use non-greedy bodies so the strip stays tight to
        // the matched tag rather than swallowing trailing content.
        let patterns: [String] = [
            // <p class="…toc…">…</p>  — class token "toc"
            #"(?si)<p[^>]*\bclass\s*=\s*"[^"]*\btoc\b[^"]*"[^>]*>.*?</p\s*>"#,
            #"(?si)<p[^>]*\bclass\s*=\s*'[^']*\btoc\b[^']*'[^>]*>.*?</p\s*>"#,
            // <div class="…toc…">…</div>
            #"(?si)<div[^>]*\bclass\s*=\s*"[^"]*\btoc\b[^"]*"[^>]*>.*?</div\s*>"#,
            #"(?si)<div[^>]*\bclass\s*=\s*'[^']*\btoc\b[^']*'[^>]*>.*?</div\s*>"#,
            // <nav epub:type="toc">…</nav>
            #"(?si)<nav[^>]*\bepub:type\s*=\s*"toc"[^>]*>.*?</nav\s*>"#,
            // <nav id="toc">…</nav>
            #"(?si)<nav[^>]*\bid\s*=\s*"toc"[^>]*>.*?</nav\s*>"#
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

    /// 2026-05-20 — Strip Project Gutenberg's `<p class="asterism">`
    /// scene-break blocks. These are typographic devices (rows of
    /// `*` glyphs separated by `<br/>`) that PG's ebookmaker uses to
    /// mark scene transitions. NSAttributedString.html parsing
    /// discards the class attribute and keeps the literal text, so
    /// without this pre-strip the asterisks leak into plainText
    /// (where AVSpeechSynthesizer would read them aloud as "star star
    /// star…") and into displayText (where they render as a stack of
    /// rows in the reader). Verified against Alice in Wonderland and
    /// confirmed downstream across plainText, displayText, RAG chunks,
    /// note anchoring, and audio export.
    ///
    /// The fallback for documents WITHOUT this class attribution
    /// (Moby Dick, A Tale of Two Cities, raw HTML, RTF/PDF imports
    /// that strip the class) lives in `TextNormalizer.stripAsterismLines`
    /// — a regex pass on the post-extraction plain text that catches
    /// any line consisting of whitespace-separated asterisks.
    ///
    /// Both layers run for EPUB: the class-targeted pre-strip removes
    /// the source markup so even the empty `<p>` shell disappears;
    /// the TextNormalizer pass catches anything that slipped through.
    static func stripAsterismBlocks(from data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return data
        }
        let patterns: [String] = [
            // <p class="…asterism…">…</p>
            #"(?si)<p[^>]*\bclass\s*=\s*"[^"]*\basterism\b[^"]*"[^>]*>.*?</p\s*>"#,
            #"(?si)<p[^>]*\bclass\s*=\s*'[^']*\basterism\b[^']*'[^>]*>.*?</p\s*>"#,
            // <div class="…asterism…">…</div> — Calibre variant
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

    /// 2026-05-21 — Strip typographic drop-cap span wrappers around
    /// chapter-opening letters. Many illustrated EPUBs (Project
    /// Gutenberg's ebookmaker for Sam'l Gabriel Sons / Heritage Press
    /// reprints, Calibre output from publisher tools, modern InDesign
    /// exports) wrap the opening letter of each chapter in a styled
    /// `<span>`:
    ///
    ///   `<span style="float:left;font-size:50px;…">A</span>lice was beginning…`
    ///   `<span class="dropcap">A</span>lice was beginning…`
    ///
    /// NSAttributedString.html parsing treats `float:left` and many
    /// dropcap class conventions as block-level breaks. The chapter's
    /// opening letter ends up on its own line in plainText, broken
    /// from the rest of the first word: `A\nlice was beginning…`.
    /// AVSpeechSynthesizer reads it as "A" pause "lice", and the
    /// reader visually shows the same break. The fix unwraps the
    /// span — drops the opening `<span …>` and closing `</span>` —
    /// while preserving the single letter inside. After unwrap,
    /// NSAttributedString sees a normal paragraph: `Alice was
    /// beginning…`. No newline injection, no synthesis voice
    /// stuttering, no visual break.
    ///
    /// Detected dropcap signatures (case-insensitive):
    ///
    /// - `<span style="…float:…">X</span>` — inline-CSS float (the
    ///   Sam'l Gabriel / Heritage / Folio style; verified against
    ///   Gutenberg #19033)
    /// - `<span class="…dropcap…">X</span>` — explicit semantic class
    /// - `<span class="…initial…">X</span>` — alternate convention
    /// - `<span class="…firstcharacter…">X</span>` / `first-letter`
    ///   — TPG ebookmaker variant
    /// - `<span class="…letra…">X</span>` — Project Gutenberg's
    ///   Spanish-class convention (used by the standard Gutenberg
    ///   illustrated Pride and Prejudice EPUB #01342, and others)
    /// - `<span class="…letra…"><img alt="X" …/></span>` — same
    ///   PG illustrated convention but the dropcap is a tiny PNG of
    ///   the styled letter rather than an actual character. The alt
    ///   attribute carries the real letter, so we substitute that.
    ///   2026-05-28 — Mark caught this on Pride EPUB Ch VII: every
    ///   chapter opened with the first letter MISSING ("R. BENNET'S"
    ///   instead of "MR. BENNET'S") because the prior regex only
    ///   matched plain-text inner content and silently dropped the
    ///   `<img>` substring under `[^<]{1,3}`.
    ///
    /// Inner content limited to 1–3 characters so the strip can't
    /// accidentally swallow non-dropcap spans that wrap larger
    /// inline fragments (e.g. footnote refs, citation chips).
    static func stripDropcapSpans(from data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return data
        }
        let textPatterns: [String] = [
            // Inline-CSS float — `style="…float:…"`. Either quote style.
            #"(?si)<span\s+[^>]*\bstyle\s*=\s*"[^"]*\bfloat\s*:[^"]*"[^>]*>([^<]{1,3})</span\s*>"#,
            #"(?si)<span\s+[^>]*\bstyle\s*=\s*'[^']*\bfloat\s*:[^']*'[^>]*>([^<]{1,3})</span\s*>"#,
            // Semantic class — dropcap / initial / first-character / first-letter / letra.
            #"(?si)<span\s+[^>]*\bclass\s*=\s*"[^"]*\b(?:dropcap|initial|first[\s-]?character|first[\s-]?letter|letra)\b[^"]*"[^>]*>([^<]{1,3})</span\s*>"#,
            #"(?si)<span\s+[^>]*\bclass\s*=\s*'[^']*\b(?:dropcap|initial|first[\s-]?character|first[\s-]?letter|letra)\b[^']*'[^>]*>([^<]{1,3})</span\s*>"#,
        ]
        for pattern in textPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            html = regex.stringByReplacingMatches(
                in: html,
                range: NSRange(html.startIndex..., in: html),
                withTemplate: "$1"
            )
        }
        // Image-based dropcap: `<span class="letra|…"><img alt="M" …/></span>`.
        // Substitute the alt attribute's letter for the entire span+img.
        // `(?s)` lets `\s*` cross the newline that Project Gutenberg
        // typically places between the `<span>` and `<img>` tags.
        let imagePatterns: [String] = [
            #"(?si)<span\s+[^>]*\bclass\s*=\s*"[^"]*\b(?:dropcap|initial|first[\s-]?character|first[\s-]?letter|letra|cap|raise)\b[^"]*"[^>]*>\s*<img\s+[^>]*\balt\s*=\s*"([^"]{1,3})"[^>]*/?>\s*</span\s*>"#,
            #"(?si)<span\s+[^>]*\bclass\s*=\s*'[^']*\b(?:dropcap|initial|first[\s-]?character|first[\s-]?letter|letra|cap|raise)\b[^']*'[^>]*>\s*<img\s+[^>]*\balt\s*=\s*'([^']{1,3})'[^>]*/?>\s*</span\s*>"#,
        ]
        for pattern in imagePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            html = regex.stringByReplacingMatches(
                in: html,
                range: NSRange(html.startIndex..., in: html),
                withTemplate: "$1"
            )
        }
        return html.data(using: .utf8) ?? data
    }

    fileprivate static func extractFirstHeadingTitle(from data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        // Try heading tags first — most informative when the chapter
        // file has them. h1/h2/h3 in priority order.
        if let title = firstTagInnerText(in: html, pattern: #"(?si)<h[1-3][^>]*>(.*?)</h[1-3]>"#),
           !title.isEmpty {
            return title
        }
        // Fall back to the <title> element. hocr-to-epub-style EPUBs
        // populate this with "Page N" or similar, which is at least
        // navigable.
        if let title = firstTagInnerText(in: html, pattern: #"(?si)<title[^>]*>(.*?)</title>"#),
           !title.isEmpty {
            return title
        }
        return nil
    }

    /// Inner-text helper for `extractFirstHeadingTitle`. Returns the
    /// trimmed, entity-decoded text inside the first match group of
    /// `pattern`, with nested tags stripped. Returns nil on no match.
    fileprivate static func firstTagInnerText(in html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(
                in: html,
                options: [],
                range: NSRange(html.startIndex..<html.endIndex, in: html)
              ),
              match.numberOfRanges >= 2,
              let inner = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let raw = String(html[inner])
        // Strip nested HTML tags from the heading content.
        let stripped = raw.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        // Decode the most common HTML entities — full HTMLDocumentImporter
        // decoding lives elsewhere; the headings we care about here only
        // contain a small set in practice.
        let decoded = stripped
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let collapsed = decoded.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// ========== BLOCK 05: NORMALIZATION AND PATH HELPERS - END ==========

// ========== BLOCK 06: XML PARSERS - START ==========

private struct EPUBPackageDocument {
    let title: String?
    /// First `<dc:creator>` in the OPF metadata block.
    let creator: String?
    /// First `<dc:contributor opf:role="ill">` in the OPF metadata
    /// block — the illustrator. Surfaces "Illustrated by X" on the
    /// library card when two cards share a title.
    let illustrator: String?
    let manifestItems: [String: EPUBManifestItem]
    let spineItemReferences: [String]
    let navItemID: String?
    let ncxItemID: String?
    let allItemHrefs: [String: String]
    /// Manifest id of the cover image, when present. EPUB 3 publishes
    /// this via `<item properties="cover-image">`; EPUB 2 via a
    /// `<meta name="cover" content="<itemID>"/>` element in the
    /// `<metadata>` block. Either form resolves to the manifest item
    /// holding the cover image bytes (jpg / png / etc.). Nil when the
    /// package declares no cover (and on packages where the cover is
    /// embedded inside a cover.xhtml spine item rather than as a
    /// standalone image manifest entry — those covers already render
    /// via the normal inline-`<img>` extraction path).
    let coverItemID: String?
}

private struct EPUBManifestItem {
    let href: String
    /// MIME type from the manifest `media-type` attribute.
    let mediaType: String
    /// Space-separated properties string (e.g. "nav", "cover-image").
    let properties: String
}

private final class EPUBContainerParser: NSObject, XMLParserDelegate {
    private var packageDocumentPath: String?

    static func packageDocumentPath(from data: Data) throws -> String {
        let delegate = EPUBContainerParser()
        let parser   = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let path = delegate.packageDocumentPath else {
            throw EPUBDocumentImporter.ImportError.unreadableDocument
        }
        return path
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?,
                attributes attributeDict: [String: String] = [:]) {
        if matches(elementName, suffix: "rootfile"), let fullPath = attributeDict["full-path"] {
            packageDocumentPath = fullPath
        }
    }

    private func matches(_ elementName: String, suffix: String) -> Bool {
        elementName == suffix || elementName.hasSuffix(":\(suffix)")
    }
}

private final class EPUBPackageParser: NSObject, XMLParserDelegate {
    private var title: String?
    private var creator: String?
    private var illustrator: String?
    private var manifestItems: [String: EPUBManifestItem] = [:]
    private var allItemHrefs: [String: String] = [:]
    private var navItemID: String?
    private var ncxItemID: String?
    private var spineItemReferences: [String] = []
    /// EPUB 3 cover: set when a manifest item carries
    /// `properties="cover-image"`. The item is the image itself.
    private var coverItemIDFromProperties: String?
    /// EPUB 2 legacy cover: set when the `<metadata>` block contains
    /// `<meta name="cover" content="<itemID>"/>`. The value points
    /// into the manifest. Resolved against `manifestItems` in `parse()`
    /// and used only when no EPUB 3 cover-image manifest item exists.
    private var coverItemIDFromMeta: String?
    private var collectingTitle = false
    private var currentTitle    = ""
    // Bundle 2 follow-up — capture first `<dc:creator>` and the
    // first `<dc:contributor opf:role="ill">`. Both fields are
    // gathered as text inside the element; we tag the current
    // contributor with `currentContributorIsIllustrator` so the
    // closing tag knows whether to keep the value.
    private var collectingCreator = false
    private var currentCreator = ""
    private var collectingContributor = false
    private var currentContributor = ""
    private var currentContributorIsIllustrator = false

    /// Media types and file suffixes that indicate a pure XML navigation structure
    /// (not readable XHTML content). The NCX is sometimes mislabelled as "text/xml"
    /// so we also detect by href extension.
    private static let nonReadableMediaTypes: Set<String> = [
        "application/x-dtbncx+xml",       // EPUB 2 NCX — standard media type
        "application/oebps-package+xml",   // OPF package document itself
    ]

    static func parse(_ data: Data) throws -> EPUBPackageDocument {
        let delegate = EPUBPackageParser()
        let parser   = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw EPUBDocumentImporter.ImportError.unreadableDocument
        }
        // Cover resolution: EPUB 3 properties wins; EPUB 2 meta-fallback
        // only counts when the referenced manifest item is actually an
        // image (some packages name an xhtml cover-page via the meta
        // form — those covers already render via the inline-img path
        // and shouldn't be double-injected here).
        let coverFromMetaIfImage: String? = {
            guard let metaID = delegate.coverItemIDFromMeta,
                  let item = delegate.manifestItems[metaID],
                  item.mediaType.lowercased().hasPrefix("image/") else {
                return nil
            }
            return metaID
        }()
        let coverItemID = delegate.coverItemIDFromProperties ?? coverFromMetaIfImage
        return EPUBPackageDocument(
            title: delegate.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            creator: delegate.creator?.trimmingCharacters(in: .whitespacesAndNewlines),
            illustrator: delegate.illustrator?.trimmingCharacters(in: .whitespacesAndNewlines),
            manifestItems: delegate.manifestItems,
            spineItemReferences: delegate.spineItemReferences,
            navItemID: delegate.navItemID,
            ncxItemID: delegate.ncxItemID,
            allItemHrefs: delegate.allItemHrefs,
            coverItemID: coverItemID
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?,
                attributes attributeDict: [String: String] = [:]) {
        if matches(elementName, suffix: "title") {
            collectingTitle = true; currentTitle = ""; return
        }
        // **Bundle 2 follow-up (2026-05-26)** — capture first
        // `<dc:creator>` and `<dc:contributor opf:role="ill">`.
        if matches(elementName, suffix: "creator") {
            // Only keep the first creator; subsequent ones ignored.
            if creator == nil {
                collectingCreator = true; currentCreator = ""
            }
            return
        }
        if matches(elementName, suffix: "contributor") {
            let role = (attributeDict["opf:role"] ?? attributeDict["role"] ?? "").lowercased()
            // "ill" is the OPF role code for illustrator. Some
            // packages also use "art" or "edt" — we only target
            // illustrator since that's the disambiguating signal
            // Mark's Alice example called out.
            if role == "ill", illustrator == nil {
                collectingContributor = true
                currentContributor = ""
                currentContributorIsIllustrator = true
            }
            return
        }
        // EPUB 2 cover-meta detection (in `<metadata>` block). Must come
        // before the `item` branch because `<meta>` and `<item>` are
        // different elements but both can have name/content attributes
        // in some XML serializations.
        if matches(elementName, suffix: "meta") {
            let name = (attributeDict["name"] ?? "").lowercased()
            if name == "cover", let content = attributeDict["content"], coverItemIDFromMeta == nil {
                coverItemIDFromMeta = content
            }
            return
        }
        if matches(elementName, suffix: "item"),
           let id   = attributeDict["id"],
           let href = attributeDict["href"] {
            let mediaType  = attributeDict["media-type"] ?? ""
            let properties = attributeDict["properties"] ?? ""
            // Always record href for all items so TOC parsers can find NCX/nav paths.
            allItemHrefs[id] = href
            // EPUB 3 cover-image detection. The first item carrying
            // `cover-image` in its space-separated properties wins.
            if coverItemIDFromProperties == nil,
               properties.lowercased().split(separator: " ").contains("cover-image"),
               mediaType.lowercased().hasPrefix("image/") {
                coverItemIDFromProperties = id
            }
            // NCX files are sometimes mislabelled as "text/xml" — also detect by extension.
            let hrefLower = href.lowercased()
            let isNCX = Self.nonReadableMediaTypes.contains(mediaType.lowercased())
                     || (mediaType.lowercased() == "text/xml" && hrefLower.hasSuffix(".ncx"))
            // Non-readable types (NCX, OPF) are tracked for TOC purposes only.
            if isNCX || mediaType.lowercased() == "application/oebps-package+xml" {
                if isNCX { ncxItemID = id }
                return
            }
            // Nav documents (properties="nav") are readable XHTML — include them
            // so TOC text appears inline instead of being silently dropped.
            if properties.lowercased().split(separator: " ").contains("nav") { navItemID = id }
            manifestItems[id] = EPUBManifestItem(href: href, mediaType: mediaType, properties: properties)
            return
        }
        if matches(elementName, suffix: "spine") {
            // EPUB 2: <spine toc="ncxId"> — fallback to identify NCX when media type
            // didn't already catch it (e.g. NCX mislabelled as text/xml without .ncx ext).
            if let tocID = attributeDict["toc"], ncxItemID == nil {
                ncxItemID = tocID
            }
            return
        }
        if matches(elementName, suffix: "itemref"),
           let idref = attributeDict["idref"] {
            // Include linear="no" items — they are supplemental (cover pages, nav
            // documents) but suppressing them silently drops TOC and cover content.
            // Cover images become visual stops; nav XHTML becomes readable TOC text.
            spineItemReferences.append(idref)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingTitle { currentTitle.append(string) }
        if collectingCreator { currentCreator.append(string) }
        if collectingContributor { currentContributor.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?) {
        if matches(elementName, suffix: "title") {
            collectingTitle = false; title = currentTitle
        }
        if matches(elementName, suffix: "creator"), collectingCreator {
            collectingCreator = false
            creator = currentCreator
        }
        if matches(elementName, suffix: "contributor"), collectingContributor {
            collectingContributor = false
            if currentContributorIsIllustrator {
                illustrator = currentContributor
            }
            currentContributorIsIllustrator = false
        }
    }

    private func matches(_ elementName: String, suffix: String) -> Bool {
        elementName == suffix || elementName.hasSuffix(":\(suffix)")
    }
}

// ========== BLOCK 06: XML PARSERS - END ==========

// ========== BLOCK 07: TOC PARSERS - START ==========

/// One raw entry from an EPUB nav or NCX document before offset resolution.
private struct RawTOCEntry {
    let title: String
    /// href from the nav/NCX (may include a fragment, e.g. "ch01.xhtml#s1").
    let href: String
    let playOrder: Int
    /// Nesting depth in the source nav/NCX document. 1 = top-level.
    let level: Int
}

/// Parses an EPUB 3 nav document (XHTML) for its `<nav epub:type="toc">` entries.
/// Returns entries in document order with synthetic 1-based playOrder values.
/// 2026-05-06 (parity #3): tracks `<ol>`/`<ul>` nesting depth inside the TOC nav
/// so each anchor's level reflects how deeply nested it is in the outline.
private final class EPUBNavTOCParser: NSObject, XMLParserDelegate {
    private var entries: [RawTOCEntry] = []
    private var insideTOCNav = false
    private var navDepth = 0
    private var listDepth = 0
    private var collectingAnchor = false
    private var currentHref = ""
    private var currentTitle = ""
    private var playOrder = 0

    static func parse(_ data: Data) -> [RawTOCEntry] {
        let delegate = EPUBNavTOCParser()
        let parser   = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName _: String?,
                attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        // Detect <nav epub:type="toc"> by the epub:type attribute.
        if localName == "nav" {
            let epubType = attributeDict["epub:type"] ?? attributeDict["type"] ?? ""
            if epubType.lowercased().contains("toc") {
                insideTOCNav = true
                navDepth = 0
                listDepth = 0
            }
            if insideTOCNav { navDepth += 1 }
            return
        }
        if insideTOCNav && (localName == "ol" || localName == "ul") {
            listDepth += 1
            return
        }
        if insideTOCNav && localName == "a", let href = attributeDict["href"] {
            collectingAnchor = true
            currentHref  = href
            currentTitle = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingAnchor { currentTitle.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "nav" && insideTOCNav {
            navDepth -= 1
            if navDepth <= 0 {
                insideTOCNav = false
                listDepth = 0
            }
            return
        }
        if insideTOCNav && (localName == "ol" || localName == "ul") {
            listDepth = max(0, listDepth - 1)
            return
        }
        if insideTOCNav && localName == "a" && collectingAnchor {
            collectingAnchor = false
            let t = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !currentHref.isEmpty {
                playOrder += 1
                let level = max(1, min(6, listDepth))
                entries.append(RawTOCEntry(title: t, href: currentHref, playOrder: playOrder, level: level))
            }
        }
    }
}

/// Parses an EPUB 2 NCX document for its navPoint entries.
/// Handles both standard `application/x-dtbncx+xml` and mislabelled `text/xml` NCX files.
/// 2026-05-06 (parity #3): tracks navPoint nesting depth so each entry's
/// level reflects how deeply it sits in the outline tree.
private final class EPUBNCXParser: NSObject, XMLParserDelegate {
    private var entries: [RawTOCEntry] = []
    private var collectingLabel = false
    private var currentLabel = ""
    private var currentSrc   = ""
    private var currentOrder = 0
    private var pendingOrder = 0
    /// Stack of (pendingOrder, currentSrc, currentLabel) snapshots so a
    /// child navPoint doesn't clobber its parent's in-progress state
    /// before the parent's didEnd fires. NCX nesting is allowed and
    /// commonly used for chapter→section hierarchies.
    private var stack: [(order: Int, src: String, label: String, level: Int)] = []
    private var depth = 0

    static func parse(_ data: Data) -> [RawTOCEntry] {
        let delegate = EPUBNCXParser()
        let parser   = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.entries
    }

    private func localName(_ elementName: String) -> String {
        elementName.components(separatedBy: ":").last ?? elementName
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "navPoint":
            // Push the parent's in-progress state so we can restore it
            // when this child closes.
            stack.append((pendingOrder, currentSrc, currentLabel, depth))
            depth += 1
            let orderStr = attributeDict["playOrder"] ?? ""
            pendingOrder = Int(orderStr) ?? (entries.count + 1)
            currentLabel = ""
            currentSrc   = ""
        case "text":
            collectingLabel = true
        case "content":
            currentSrc = attributeDict["src"] ?? ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingLabel { currentLabel.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?) {
        switch localName(elementName) {
        case "text":
            collectingLabel = false
        case "navPoint":
            let t = currentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !currentSrc.isEmpty {
                let level = max(1, min(6, depth))
                entries.append(RawTOCEntry(title: t, href: currentSrc, playOrder: pendingOrder, level: level))
            }
            // Pop the parent's state back so its label/src/order isn't lost.
            if let parent = stack.popLast() {
                pendingOrder = parent.order
                currentSrc   = parent.src
                currentLabel = parent.label
                depth        = parent.level
            } else {
                depth = max(0, depth - 1)
            }
        default: break
        }
    }
}

// ========== BLOCK 07: TOC PARSERS - END ==========
