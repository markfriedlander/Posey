import Combine
import SwiftUI
import UniformTypeIdentifiers

// ========== BLOCK 01: LIBRARY VIEW - START ==========

struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @State private var isImporting = false
    @State private var path: [Document] = []
    @State private var documentPendingDeletion: Document? = nil
    /// Guards `maybeRestoreLastOpenedDocument` so it runs exactly once per
    /// app launch. Without this guard, `.task` re-fires when the library
    /// re-appears after popping back from the reader, and the restore can
    /// re-push the same document onto the navigation stack before
    /// `.onChange(of: path)` has cleared `lastOpenedDocumentID`. The visible
    /// symptom was: tap back from a reader → reader bounces right back; tap
    /// back twice to actually return; some users saw two push animations
    /// when a doc was tapped from the library because the queued restore
    /// landed on top of the user's tap.
    @State private var didAttemptInitialRestore = false
    private let playbackMode: AppLaunchConfiguration.PlaybackMode
    private let isTestMode: Bool
    private let shouldAutoOpenFirstDocument: Bool
    private let shouldAutoPlayOnReaderAppear: Bool
    private let shouldAutoCreateNoteOnReaderAppear: Bool
    private let shouldAutoCreateBookmarkOnReaderAppear: Bool
    private let automationNoteBody: String

    init(
        databaseManager: DatabaseManager,
        playbackMode: AppLaunchConfiguration.PlaybackMode = .system,
        isTestMode: Bool = false,
        shouldAutoOpenFirstDocument: Bool = false,
        shouldAutoPlayOnReaderAppear: Bool = false,
        shouldAutoCreateNoteOnReaderAppear: Bool = false,
        shouldAutoCreateBookmarkOnReaderAppear: Bool = false,
        automationNoteBody: String = "Automated smoke note"
    ) {
        self.playbackMode = playbackMode
        self.isTestMode = isTestMode
        self.shouldAutoOpenFirstDocument = shouldAutoOpenFirstDocument
        self.shouldAutoPlayOnReaderAppear = shouldAutoPlayOnReaderAppear
        self.shouldAutoCreateNoteOnReaderAppear = shouldAutoCreateNoteOnReaderAppear
        self.shouldAutoCreateBookmarkOnReaderAppear = shouldAutoCreateBookmarkOnReaderAppear
        self.automationNoteBody = automationNoteBody
        _viewModel = StateObject(wrappedValue: LibraryViewModel(databaseManager: databaseManager))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(viewModel.documents) { document in
                NavigationLink(value: document) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.title)
                            .font(.headline)
                        Text("\(document.characterCount) characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("library.document.\(document.title)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        documentPendingDeletion = document
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .overlay {
                if viewModel.documents.isEmpty && viewModel.pdfImportStatusMessage == nil {
                    ContentUnavailableView(
                        "No Documents Yet",
                        systemImage: "text.document",
                        description: Text("Import a TXT, Markdown, RTF, DOCX, HTML, EPUB, or PDF file to start the reading loop.")
                    )
                }
            }
            .navigationTitle("Posey")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.toggleLocalAPI()
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(viewModel.localAPIEnabled
                                             ? Color.primary
                                             : Color.primary.opacity(0.25))
                    }
                    .accessibilityIdentifier("library.apiToggle")
                    .accessibilityLabel(viewModel.localAPIEnabled ? "API On" : "API Off")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import File") {
                        isImporting = true
                    }
                    .disabled(viewModel.pdfImportStatusMessage != nil)
                    .accessibilityIdentifier("library.importTXT")
                }
            }
            .navigationDestination(for: Document.self) { document in
                ReaderView(
                    document: document,
                    databaseManager: viewModel.databaseManager,
                    playbackMode: playbackMode,
                    isTestMode: isTestMode,
                    shouldAutoPlayOnAppear: shouldAutoPlayOnReaderAppear,
                    shouldAutoCreateNoteOnAppear: shouldAutoCreateNoteOnReaderAppear,
                    shouldAutoCreateBookmarkOnAppear: shouldAutoCreateBookmarkOnReaderAppear,
                    automationNoteBody: automationNoteBody
                )
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.plainText, .rtf, .html, .pdf] + richDocumentContentTypes + markdownContentTypes,
                allowsMultipleSelection: false
            ) { result in
                viewModel.handleImport(result: result)
            }
            .safeAreaInset(edge: .bottom) {
                if let message = viewModel.pdfImportStatusMessage {
                    importProgressBanner(message: message)
                }
            }
            .task {
                viewModel.loadDocuments()
                maybeOpenFirstDocument()
                if !didAttemptInitialRestore {
                    didAttemptInitialRestore = true
                    maybeRestoreLastOpenedDocument()
                }
                // Debug builds always force the antenna ON at launch so dev
                // sessions never need a manual toggle. Release builds respect
                // whatever the user has set in UserDefaults.
                #if DEBUG
                if !viewModel.localAPIEnabled {
                    viewModel.localAPIEnabled = true
                }
                #endif
                // Auto-restart API server if it was enabled before app was killed
                // (or just force-enabled by the DEBUG block above). Pass
                // showConnectionInfo: false so the alert doesn't fire — at
                // launch the alert collides with the navigation-stack
                // auto-restore push and the user's last-opened document
                // silently fails to reopen.
                if viewModel.localAPIEnabled && !viewModel.localAPIServer.isRunning {
                    viewModel.toggleLocalAPI(showConnectionInfo: false)
                }
            }
            .onAppear {
                viewModel.loadDocuments()
                maybeOpenFirstDocument()
            }
            .onChange(of: viewModel.documents.count) { _, _ in
                maybeOpenFirstDocument()
            }
            .onChange(of: path) { _, newPath in
                // Track the last-opened document so cold launches reopen it
                // instead of dumping the user back at the library list.
                // Empty path = user backed out → forget the last document.
                PlaybackPreferences.shared.lastOpenedDocumentID = newPath.last?.id
            }
            .alert("Import Failed", isPresented: $viewModel.isShowingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .alert("API Ready — Copied to Clipboard",
                   isPresented: Binding(
                       get: { viewModel.apiConnectionInfo != nil },
                       set: { if !$0 { viewModel.apiConnectionInfo = nil } }
                   )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.apiConnectionInfo ?? "")
            }
            .alert("Delete \"\(documentPendingDeletion?.title ?? "")\"?",
                   isPresented: Binding(
                       get: { documentPendingDeletion != nil },
                       set: { if !$0 { documentPendingDeletion = nil } }
                   )) {
                Button("Delete", role: .destructive) {
                    if let doc = documentPendingDeletion {
                        viewModel.deleteDocument(doc)
                    }
                    documentPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    documentPendingDeletion = nil
                }
            } message: {
                Text("This will permanently remove the document and all its notes.")
            }
            .overlay(alignment: .bottomLeading) {
                if isTestMode {
                    Text("\(viewModel.documents.count)")
                        .font(.caption2)
                        .padding(4)
                        .background(.thinMaterial)
                        .accessibilityIdentifier("library.documentCount")
                }
            }
        }
    }

    private func importProgressBanner(message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
                .tint(.primary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: message)
    }

    private func maybeOpenFirstDocument() {
        guard shouldAutoOpenFirstDocument else { return }
        guard path.isEmpty, let first = viewModel.documents.first else { return }
        path = [first]
    }

    /// Restore the document the user was last reading. Skipped when the
    /// auto-open-first-document automation hook is active (test mode), or
    /// when something is already on the navigation path (e.g. user just
    /// imported a file mid-launch).
    private func maybeRestoreLastOpenedDocument() {
        guard !shouldAutoOpenFirstDocument else { return }
        guard path.isEmpty else { return }
        guard let lastID = PlaybackPreferences.shared.lastOpenedDocumentID else { return }
        guard let document = viewModel.documents.first(where: { $0.id == lastID }) else {
            // The remembered document was deleted out from under us — forget it
            // so we don't keep trying to restore something that no longer exists.
            PlaybackPreferences.shared.lastOpenedDocumentID = nil
            return
        }
        path = [document]
    }

    private var markdownContentTypes: [UTType] {
        [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
    }

    private var richDocumentContentTypes: [UTType] {
        [UTType(filenameExtension: "docx"), UTType(filenameExtension: "epub")].compactMap { $0 }
    }
}

// ========== BLOCK 01: LIBRARY VIEW - END ==========

// ========== BLOCK 02: LIBRARY VIEW MODEL - START ==========

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var documents: [Document] = []
    @Published var isShowingError = false
    @Published var errorMessage = ""
    /// Non-nil while a PDF import is in progress. Drives the progress banner.
    @Published private(set) var pdfImportStatusMessage: String? = nil
    /// Whether the local API server is running.
    ///
    /// Defaults to **true** for the duration of development so dev sessions
    /// don't require manually toggling the antenna icon every fresh install
    /// or DB reset. The auto-restart logic in `LibraryView.task` brings the
    /// server up automatically on launch when this is true.
    ///
    /// Before App Store submission this default must flip back to `false`
    /// — public users should opt into the API explicitly. Tracked in
    /// NEXT.md under the App-Store-readiness checklist.
    @AppStorage("localAPIEnabled") var localAPIEnabled: Bool = true
    /// Set to the connection string when the API starts; drives the "copied" alert.
    @Published var apiConnectionInfo: String? = nil

    let databaseManager: DatabaseManager
    private lazy var txtLibraryImporter    = TXTLibraryImporter(databaseManager: databaseManager)
    private lazy var markdownLibraryImporter = MarkdownLibraryImporter(databaseManager: databaseManager)
    private lazy var rtfLibraryImporter    = RTFLibraryImporter(databaseManager: databaseManager)
    private lazy var docxLibraryImporter   = DOCXLibraryImporter(databaseManager: databaseManager)
    private lazy var htmlLibraryImporter   = HTMLLibraryImporter(databaseManager: databaseManager)
    private lazy var epubLibraryImporter   = EPUBLibraryImporter(databaseManager: databaseManager)
    private lazy var pdfLibraryImporter    = PDFLibraryImporter(databaseManager: databaseManager)
    let localAPIServer = LocalAPIServer()

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func loadDocuments() {
        do {
            documents = try databaseManager.documents()
        } catch {
            present(error)
        }
    }

    func deleteDocument(_ document: Document) {
        do {
            try databaseManager.deleteDocument(document)
            loadDocuments()
        } catch {
            present(error)
        }
    }

    func handleImport(result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let fileType = url.pathExtension.lowercased()

            // PDF is handled asynchronously so OCR doesn't block the main thread.
            if fileType == "pdf" {
                handlePDFImport(url: url)
                return
            }

            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            switch fileType {
            case "txt":               _ = try txtLibraryImporter.importDocument(from: url)
            case "md", "markdown":    _ = try markdownLibraryImporter.importDocument(from: url)
            case "rtf":               _ = try rtfLibraryImporter.importDocument(from: url)
            case "docx":              _ = try docxLibraryImporter.importDocument(from: url)
            case "html", "htm":       _ = try htmlLibraryImporter.importDocument(from: url)
            case "epub":              _ = try epubLibraryImporter.importDocument(from: url)
            default:                  throw LibraryImportError.unsupportedFileType
            }
            loadDocuments()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}

// ========== BLOCK 02: LIBRARY VIEW MODEL - END ==========

// ========== BLOCK 03: PDF ASYNC IMPORT - START ==========

extension LibraryViewModel {
    /// Routes PDF imports through an async path so Vision OCR never blocks
    /// the main thread. Phase 1 (parse + OCR) runs on a background thread.
    /// Phase 2 (DB write) returns to the main actor.
    private func handlePDFImport(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        pdfImportStatusMessage = "Importing PDF\u{2026}"

        // Capture the importer as a value — PDFLibraryImporter is a struct,
        // but we only use it for the DB write (main actor), not in the Task.
        Task { @MainActor [weak self] in
            guard let self else {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                return
            }
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                pdfImportStatusMessage = nil
            }
            do {
                let parsed = try await parsePDFOffMainThread(url: url) { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.pdfImportStatusMessage = message
                    }
                }
                _ = try pdfLibraryImporter.persistParsedDocument(parsed, from: url)
                loadDocuments()
            } catch {
                present(error)
            }
        }
    }
}

/// Runs `PDFDocumentImporter.loadDocument` on a background thread.
/// `PDFDocumentImporter` has no instance stored properties — it is trivially
/// Sendable and safe to use from any thread.
/// Returns a `ParsedPDFDocument` (Sendable struct) back to the caller.
private func parsePDFOffMainThread(
    url: URL,
    onProgress: @escaping @Sendable (String) -> Void
) async throws -> ParsedPDFDocument {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try PDFDocumentImporter().loadDocument(from: url) { progress in
                    onProgress(progress.message)
                }
                cont.resume(returning: result)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

// ========== BLOCK 03: PDF ASYNC IMPORT - END ==========

// ========== BLOCK 04: LIBRARY IMPORT ERROR - START ==========

private enum LibraryImportError: LocalizedError {
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Posey can import TXT, Markdown, RTF, DOCX, HTML, EPUB, and text-based PDF files in this pass."
        }
    }
}

// ========== BLOCK 04: LIBRARY IMPORT ERROR - END ==========

// ========== BLOCK 05: LOCAL API SERVER - START ==========

extension LibraryViewModel {

    /// Toggle the local API server on or off. Prints connection info to console on start.
    /// `showConnectionInfo` controls the "API Ready — Copied to Clipboard" alert.
    /// Manual user toggles surface the alert; the launch-time auto-start does NOT
    /// — at launch, the alert collides with the navigation-stack auto-restore
    /// push (UIKit refuses to mutate the navigation stack while another
    /// transition or presentation is in flight) and the document the user was
    /// last reading silently fails to restore. Suppressing the alert at
    /// auto-start lets the restore push land cleanly.
    func toggleLocalAPI(showConnectionInfo: Bool = true) {
        if localAPIServer.isRunning {
            localAPIServer.stop()
            localAPIEnabled = false
        } else {
            localAPIServer.start(
                commandHandler: { [weak self] cmd in
                    await self?.executeAPICommand(cmd) ?? #"{"error":"unavailable"}"#
                },
                importHandler: { [weak self] filename, data in
                    await self?.apiImport(filename: filename, data: data) ?? #"{"error":"unavailable"}"#
                },
                stateHandler: { [weak self] in
                    await self?.apiState() ?? #"{"error":"unavailable"}"#
                }
            )
            localAPIEnabled = true
            let info = localAPIServer.connectionInfo
            print("PoseyAPI: \(info)")
            if showConnectionInfo {
                UIPasteboard.general.string = info
                apiConnectionInfo = info
            }
        }
    }

    // MARK: — Command handler

    func executeAPICommand(_ command: String) async -> String {
        let colonIdx = command.firstIndex(of: ":")
        let verb = (colonIdx.map { String(command[..<$0]) } ?? command).uppercased()
        let arg  = colonIdx.map { String(command[command.index(after: $0)...]) }

        do {
            switch verb {

            case "LIST_DOCUMENTS":
                let docs = try databaseManager.documents()
                let arr: [[String: Any]] = docs.map {
                    ["id": $0.id.uuidString, "title": $0.title,
                     "fileType": $0.fileType, "characterCount": $0.characterCount,
                     "importedAt": ISO8601DateFormatter().string(from: $0.importedAt)]
                }
                return json(arr)

            case "GET_TEXT":
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Missing or invalid document ID"}"#
                }
                let docs = try databaseManager.documents()
                guard let doc = docs.first(where: { $0.id == id }) else {
                    return #"{"error":"Document not found"}"#
                }
                return json(["id": doc.id.uuidString, "title": doc.title,
                             "fileType": doc.fileType, "displayText": doc.displayText])

            case "GET_PLAIN_TEXT":
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Missing or invalid document ID"}"#
                }
                let docs = try databaseManager.documents()
                guard let doc = docs.first(where: { $0.id == id }) else {
                    return #"{"error":"Document not found"}"#
                }
                return json(["id": doc.id.uuidString, "title": doc.title,
                             "fileType": doc.fileType, "plainText": doc.plainText])

            case "DELETE_DOCUMENT":
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Missing or invalid document ID"}"#
                }
                let docs = try databaseManager.documents()
                guard let doc = docs.first(where: { $0.id == id }) else {
                    return #"{"error":"Document not found"}"#
                }
                try databaseManager.deleteDocument(doc)
                loadDocuments()
                return json(["deleted": true, "id": id.uuidString])

            case "RESET_ALL":
                let docs = try databaseManager.documents()
                for doc in docs { try databaseManager.deleteDocument(doc) }
                loadDocuments()
                return json(["deleted": docs.count])

            case "DB_STATS":
                let docs = try databaseManager.documents()
                var byType: [String: Int] = [:]
                for doc in docs { byType[doc.fileType, default: 0] += 1 }
                return json(["documentCount": docs.count, "byFileType": byType])

            case "GET_IMAGE":
                guard let imageID = arg, !imageID.isEmpty else {
                    return #"{"error":"Missing image ID"}"#
                }
                guard let data = try databaseManager.imageData(for: imageID) else {
                    return #"{"error":"Image not found"}"#
                }
                return json(["imageID": imageID, "base64": data.base64EncodedString(),
                             "byteCount": data.count])

            case "LIST_IMAGES":
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Missing or invalid document ID"}"#
                }
                let imageIDs = try databaseManager.imageIDs(for: id)
                return json(["documentID": idStr, "imageIDs": imageIDs, "count": imageIDs.count])

            case "LIST_TOC":
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Missing or invalid document ID"}"#
                }
                let toc = try databaseManager.tocEntries(for: id)
                let arr: [[String: Any]] = toc.map {
                    ["title": $0.title, "plainTextOffset": $0.plainTextOffset,
                     "playOrder": $0.playOrder]
                }
                return json(["documentID": idStr, "count": toc.count, "entries": arr])

            default:
                return #"{"error":"Unknown command: \#(verb)"}"#
            }
        } catch {
            return json(["error": error.localizedDescription])
        }
    }

    // MARK: — Import handler

    func apiImport(filename: String, data: Data) async -> String {
        let cleanFilename = LibraryViewModel.sanitizeFilename(filename)
        let ext = (cleanFilename as NSString).pathExtension.lowercased()
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(cleanFilename)
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let doc: Document
            if ext == "pdf" {
                pdfImportStatusMessage = "API: Importing \(cleanFilename)\u{2026}"
                defer { pdfImportStatusMessage = nil }
                let parsed = try await parsePDFOffMainThread(url: tempURL) { [weak self] msg in
                    Task { @MainActor [weak self] in self?.pdfImportStatusMessage = msg }
                }
                doc = try pdfLibraryImporter.persistParsedDocument(parsed, from: tempURL)
            } else {
                switch ext {
                case "txt":             doc = try txtLibraryImporter.importDocument(from: tempURL)
                case "md", "markdown":  doc = try markdownLibraryImporter.importDocument(from: tempURL)
                case "rtf":             doc = try rtfLibraryImporter.importDocument(from: tempURL)
                case "docx":            doc = try docxLibraryImporter.importDocument(from: tempURL)
                case "html", "htm":     doc = try htmlLibraryImporter.importDocument(from: tempURL)
                case "epub":            doc = try epubLibraryImporter.importDocument(from: tempURL)
                default:                throw LibraryImportError.unsupportedFileType
                }
            }
            loadDocuments()
            return json(["success": true, "id": doc.id.uuidString,
                         "title": doc.title, "fileType": doc.fileType,
                         "characterCount": doc.characterCount])
        } catch {
            return json(["success": false, "error": error.localizedDescription])
        }
    }

    // MARK: — State handler

    func apiState() async -> String {
        let docs = (try? databaseManager.documents()) ?? []
        return json([
            "apiEnabled": true,
            "documentCount": docs.count,
            "connectionInfo": localAPIServer.connectionInfo
        ])
    }

    // MARK: — JSON helper

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"error":"JSON encoding failed"}"#
        }
        return str
    }
}

// ========== BLOCK 05: LOCAL API SERVER - END ==========

// ========== BLOCK 06: FILENAME SANITIZATION - START ==========

extension LibraryViewModel {

    /// Sanitizes a filename received from the API or file picker before it is
    /// written to the temporary directory or used as a document title.
    ///
    /// Handles:
    ///   - Null bytes and control characters
    ///   - Path separators (/ and \) that would escape the temp directory
    ///   - macOS reserved characters (: ? * < > | " and ASCII NUL)
    ///   - Leading / trailing whitespace and dots
    ///   - Path traversal sequences (..)
    ///   - Duplicate file extensions (report.pdf.pdf → report.pdf)
    ///   - Names that are empty after sanitization
    static func sanitizeFilename(_ raw: String) -> String {
        var name = raw

        // Strip null bytes first — they can cause subtle downstream bugs.
        name = name.replacingOccurrences(of: "\0", with: "")

        // Replace characters that are illegal on iOS/macOS filesystems or that
        // cause import failures / ugly titles. Colon is the macOS metadata
        // separator; slashes would escape the directory.
        let illegal = CharacterSet(charactersIn: "/\\:|?*<>\"")
        name = name.components(separatedBy: illegal).joined(separator: "_")

        // Collapse any control characters (U+0000–U+001F, U+007F).
        name = name.unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F }
            .reduce("") { $0 + String($1) }

        // Remove path-traversal sequences.
        name = name.replacingOccurrences(of: "..", with: ".")

        // Trim leading/trailing whitespace and dots (dots alone are invisible in Finder).
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name = String(name.dropFirst()) }

        // Deduplicate file extension (e.g. "book.pdf.pdf" → "book.pdf").
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            let withoutExt = (name as NSString).deletingPathExtension
            if (withoutExt as NSString).pathExtension.lowercased() == ext {
                name = withoutExt
            }
        }

        // Re-trim after extension fixup.
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate to 200 chars, preserving the extension.
        if name.count > 200 {
            let extPart = ext.isEmpty ? "" : ".\(ext)"
            let basePart = (name as NSString).deletingPathExtension
            let truncBase = String(basePart.prefix(200 - extPart.count))
            name = truncBase + extPart
        }

        // Final fallback for pathological inputs.
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = "imported_document"
        }
        return name
    }
}

// ========== BLOCK 06: FILENAME SANITIZATION - END ==========
