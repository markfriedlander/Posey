import Foundation

struct ParsedEPUBDocument {
    let title: String?
    let plainText: String
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

    func loadDocument(from url: URL) throws -> ParsedEPUBDocument {
        let data = try Data(contentsOf: url)
        return try loadDocument(fromData: data)
    }

    func loadDocument(fromData data: Data) throws -> ParsedEPUBDocument {
        let archive = try archive(from: data)
        let containerXML = try entryData(named: "META-INF/container.xml", archive: archive)
        let packagePath = try EPUBContainerParser.packageDocumentPath(from: containerXML)
        let packageXML = try entryData(named: packagePath, archive: archive)
        let packageDocument = try EPUBPackageParser.parse(packageXML)

        let baseDirectory = (packagePath as NSString).deletingLastPathComponent
        let spinePaths = packageDocument.spineItemReferences.compactMap { idref in
            packageDocument.manifestItems[idref].map { manifestItem in
                resolveArchivePath(baseDirectory: baseDirectory, relativePath: manifestItem.href)
            }
        }

        var chapterTexts: [String] = []
        chapterTexts.reserveCapacity(spinePaths.count)

        for path in spinePaths {
            guard let chapterData = try? entryData(named: path, archive: archive) else {
                continue
            }

            if let chapterText = try? htmlImporter.loadText(fromData: chapterData) {
                chapterTexts.append(chapterText)
            }
        }

        let normalized = normalize(chapterTexts.joined(separator: "\n\n"))
        guard normalized.isEmpty == false else {
            throw ImportError.emptyDocument
        }

        return ParsedEPUBDocument(
            title: packageDocument.title,
            plainText: normalized
        )
    }

    private func archive(from data: Data) throws -> ZIPArchive {
        do {
            return try ZIPArchive(data: data)
        } catch {
            throw ImportError.unreadableDocument
        }
    }

    private func entryData(named fileName: String, archive: ZIPArchive) throws -> Data {
        do {
            return try archive.entryData(named: fileName)
        } catch {
            throw ImportError.unreadableDocument
        }
    }

    private func resolveArchivePath(baseDirectory: String, relativePath: String) -> String {
        let baseURL = URL(fileURLWithPath: baseDirectory, isDirectory: true)
        let resolvedURL = baseURL.appendingPathComponent(relativePath).standardizedFileURL
        var path = resolvedURL.path
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        return path
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct EPUBPackageDocument {
    let title: String?
    let manifestItems: [String: EPUBManifestItem]
    let spineItemReferences: [String]
}

private struct EPUBManifestItem {
    let href: String
}

private final class EPUBContainerParser: NSObject, XMLParserDelegate {
    private var packageDocumentPath: String?

    static func packageDocumentPath(from data: Data) throws -> String {
        let parserDelegate = EPUBContainerParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate

        guard parser.parse(), let packageDocumentPath = parserDelegate.packageDocumentPath else {
            throw EPUBDocumentImporter.ImportError.unreadableDocument
        }

        return packageDocumentPath
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
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
    private var currentTitle = ""

    static func parse(_ data: Data) throws -> EPUBPackageDocument {
        let parserDelegate = EPUBPackageParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate

        guard parser.parse() else {
            throw EPUBDocumentImporter.ImportError.unreadableDocument
        }

        return EPUBPackageDocument(
            title: parserDelegate.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            manifestItems: parserDelegate.manifestItems,
            spineItemReferences: parserDelegate.spineItemReferences
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
        if matches(elementName, suffix: "title") {
            collectingTitle = true
            currentTitle = ""
            return
        }

        if matches(elementName, suffix: "item"),
           let id = attributeDict["id"],
           let href = attributeDict["href"] {
            manifestItems[id] = EPUBManifestItem(href: href)
            return
        }

        if matches(elementName, suffix: "itemref"),
           let idref = attributeDict["idref"] {
            spineItemReferences.append(idref)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingTitle {
            currentTitle.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        if matches(elementName, suffix: "title") {
            collectingTitle = false
            title = currentTitle
        }
    }

    private func matches(_ elementName: String, suffix: String) -> Bool {
        elementName == suffix || elementName.hasSuffix(":\(suffix)")
    }
}
