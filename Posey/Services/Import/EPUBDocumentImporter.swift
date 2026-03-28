import Foundation

// ========== BLOCK 01: MODELS AND ERRORS - START ==========

struct ParsedEPUBDocument {
    let title: String?
    /// Normalized text with inline \x0c-delimited visual-image markers
    /// [[POSEY_VISUAL_PAGE:0:uuid]] at each <img> position.
    let displayText: String
    /// Plain text without any image markers — used for TTS segmentation.
    let plainText: String
    /// One record per inline image extracted from the EPUB content.
    let images: [PageImageRecord]
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
        let spinePaths    = packageDoc.spineItemReferences.compactMap { idref in
            packageDoc.manifestItems[idref].map { item in
                resolveArchivePath(baseDirectory: baseDirectory, relativePath: item.href)
            }
        }

        var chapterTexts: [String] = []  // displayText per chapter (may contain markers)
        var imageRecords: [PageImageRecord] = []

        for path in spinePaths {
            guard let chapterData = entryLoader(path) else { continue }
            let chapterDir = (path as NSString).deletingLastPathComponent

            // Extract inline images, replacing <img> tags with \x0c-delimited markers.
            let (processedData, chapterImages) = extractInlineImages(
                from: chapterData,
                chapterBasePath: chapterDir,
                entryLoader: entryLoader
            )
            imageRecords.append(contentsOf: chapterImages)

            if let chapterText = try? htmlImporter.loadText(fromData: processedData) {
                chapterTexts.append(chapterText)
            }
        }

        guard !chapterTexts.isEmpty else { throw ImportError.emptyDocument }

        let displayText = normalizeDisplay(chapterTexts.joined(separator: "\n\n"))
        let plainText   = buildPlainText(from: displayText)

        return ParsedEPUBDocument(
            title: packageDoc.title,
            displayText: displayText,
            plainText: plainText,
            images: imageRecords
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
}

// ========== BLOCK 05: NORMALIZATION AND PATH HELPERS - END ==========

// ========== BLOCK 06: XML PARSERS - START ==========

private struct EPUBPackageDocument {
    let title: String?
    let manifestItems: [String: EPUBManifestItem]
    let spineItemReferences: [String]
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
    private var spineItemReferences: [String] = []
    private var collectingTitle = false
    private var currentTitle    = ""

    /// Media types that are navigation/TOC documents rather than readable content.
    private static let tocMediaTypes: Set<String> = [
        "application/x-dtbncx+xml",       // EPUB 2 NCX table of contents
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
            spineItemReferences: delegate.spineItemReferences
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
            // Skip navigation/TOC documents — not readable content.
            guard !Self.tocMediaTypes.contains(mediaType.lowercased()),
                  !properties.lowercased().split(separator: " ").contains("nav") else { return }
            manifestItems[id] = EPUBManifestItem(href: href, mediaType: mediaType, properties: properties)
            return
        }
        if matches(elementName, suffix: "itemref"),
           let idref = attributeDict["idref"] {
            // linear="no" items are out of the reading flow (cover pages, nav docs).
            let linear = attributeDict["linear"] ?? "yes"
            guard linear.lowercased() != "no" else { return }
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
