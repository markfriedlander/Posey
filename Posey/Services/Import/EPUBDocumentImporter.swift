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
}

struct ParsedEPUBDocument {
    let title: String?
    /// Normalized text with inline \x0c-delimited visual-image markers
    /// [[POSEY_VISUAL_PAGE:0:uuid]] at each <img> position.
    let displayText: String
    /// Plain text without any image markers — used for TTS segmentation.
    let plainText: String
    /// One record per inline image extracted from the EPUB content.
    let images: [PageImageRecord]
    /// Table of contents entries in reading order. Empty if no nav/NCX was found.
    let tocEntries: [EPUBTOCEntry]
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

        var chapterTexts: [String] = []  // displayText per chapter (may contain markers)
        var chapterPlainLengths: [Int] = []  // plain-text char count per chapter (for TOC offsets)
        var imageRecords: [PageImageRecord] = []
        // Map from (normalized spine file path without fragment) → cumulative offset at start
        var pathToPlainOffset: [String: Int] = [:]

        for (path, href) in spineItems {
            guard let chapterData = entryLoader(path) else { continue }
            let chapterDir = (path as NSString).deletingLastPathComponent

            // Record the plain-text offset at the START of this chapter.
            // Offset = sum of all previous chapters' plain chars + separators (2 per join).
            let cumulativeOffset = chapterPlainLengths.reduce(0, +)
                + max(0, chapterPlainLengths.count - 1) * 2  // "\n\n" between chapters
            // Key by the bare href (path component without fragment).
            let bareHref = (href as NSString).lastPathComponent
                .components(separatedBy: "#").first ?? ""
            if !bareHref.isEmpty && pathToPlainOffset[bareHref] == nil {
                pathToPlainOffset[bareHref] = cumulativeOffset
            }

            // Extract inline images, replacing <img> tags with \x0c-delimited markers.
            let (processedData, chapterImages) = extractInlineImages(
                from: chapterData,
                chapterBasePath: chapterDir,
                entryLoader: entryLoader
            )
            imageRecords.append(contentsOf: chapterImages)

            if let chapterText = try? htmlImporter.loadText(fromData: processedData) {
                let plainChapter = buildPlainText(from: chapterText)
                chapterTexts.append(chapterText)
                chapterPlainLengths.append(plainChapter.count)
            }
        }

        guard !chapterTexts.isEmpty else { throw ImportError.emptyDocument }

        let displayText = normalizeDisplay(chapterTexts.joined(separator: "\n\n"))
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
            tocEntries = synthesizeTOCFromSpine(
                spineItems: spineItems,
                entryLoader: entryLoader,
                pathToPlainOffset: pathToPlainOffset
            )
        }

        return ParsedEPUBDocument(
            title: packageDoc.title,
            displayText: displayText,
            plainText: plainText,
            images: imageRecords,
            tocEntries: tocEntries
        )
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
    private func normalizeDisplay(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r",   with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips visual-page markers from displayText to produce plainText for TTS.
    private func buildPlainText(from displayText: String) -> String {
        var t = displayText
        // Remove \x0c[[POSEY_VISUAL_PAGE:...]] \x0c sequences.
        t = t.replacingOccurrences(
            of: #"\u{000C}\[\[POSEY_VISUAL_PAGE:[^\]]*\]\]\u{000C}"#,
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
            // Strip fragment and normalize href to match pathToPlainOffset keys.
            let bareHref = raw.href
                .components(separatedBy: "#").first
                .map { ($0 as NSString).lastPathComponent } ?? ""
            let offset = pathToPlainOffset[bareHref] ?? -1
            return EPUBTOCEntry(title: raw.title, plainTextOffset: offset, playOrder: raw.playOrder)
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
                playOrder: playOrder
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
    let manifestItems: [String: EPUBManifestItem]
    let spineItemReferences: [String]
    /// Manifest item ID of the EPUB 3 nav document (properties="nav"), if present.
    let navItemID: String?
    /// Manifest item ID of the EPUB 2 NCX document, if present. NCX items are not
    /// added to manifestItems (they are not readable XHTML) but their href is needed
    /// to parse TOC data.
    let ncxItemID: String?
    /// href values keyed by manifest item ID — includes NCX items not in manifestItems.
    let allItemHrefs: [String: String]
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
    private var manifestItems: [String: EPUBManifestItem] = [:]
    private var allItemHrefs: [String: String] = [:]
    private var navItemID: String?
    private var ncxItemID: String?
    private var spineItemReferences: [String] = []
    private var collectingTitle = false
    private var currentTitle    = ""

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
        return EPUBPackageDocument(
            title: delegate.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            manifestItems: delegate.manifestItems,
            spineItemReferences: delegate.spineItemReferences,
            navItemID: delegate.navItemID,
            ncxItemID: delegate.ncxItemID,
            allItemHrefs: delegate.allItemHrefs
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?,
                attributes attributeDict: [String: String] = [:]) {
        if matches(elementName, suffix: "title") {
            collectingTitle = true; currentTitle = ""; return
        }
        if matches(elementName, suffix: "item"),
           let id   = attributeDict["id"],
           let href = attributeDict["href"] {
            let mediaType  = attributeDict["media-type"] ?? ""
            let properties = attributeDict["properties"] ?? ""
            // Always record href for all items so TOC parsers can find NCX/nav paths.
            allItemHrefs[id] = href
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
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?) {
        if matches(elementName, suffix: "title") {
            collectingTitle = false; title = currentTitle
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
}

/// Parses an EPUB 3 nav document (XHTML) for its `<nav epub:type="toc">` entries.
/// Returns entries in document order with synthetic 1-based playOrder values.
private final class EPUBNavTOCParser: NSObject, XMLParserDelegate {
    private var entries: [RawTOCEntry] = []
    private var insideTOCNav = false
    private var navDepth = 0
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
            }
            if insideTOCNav { navDepth += 1 }
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
            if navDepth <= 0 { insideTOCNav = false }
            return
        }
        if insideTOCNav && localName == "a" && collectingAnchor {
            collectingAnchor = false
            let t = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !currentHref.isEmpty {
                playOrder += 1
                entries.append(RawTOCEntry(title: t, href: currentHref, playOrder: playOrder))
            }
        }
    }
}

/// Parses an EPUB 2 NCX document for its navPoint entries.
/// Handles both standard `application/x-dtbncx+xml` and mislabelled `text/xml` NCX files.
private final class EPUBNCXParser: NSObject, XMLParserDelegate {
    private var entries: [RawTOCEntry] = []
    private var collectingLabel = false
    private var currentLabel = ""
    private var currentSrc   = ""
    private var currentOrder = 0
    private var pendingOrder = 0

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
                entries.append(RawTOCEntry(title: t, href: currentSrc, playOrder: pendingOrder))
            }
        default: break
        }
    }
}

// ========== BLOCK 07: TOC PARSERS - END ==========
