import Combine
import SwiftUI
import UniformTypeIdentifiers

// ========== BLOCK 01: LIBRARY VIEW - START ==========

struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @State private var isImporting = false
    @State private var path: [Document] = []
    @State private var documentPendingDeletion: Document? = nil
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
                // Auto-restart API server if it was enabled before app was killed.
                if viewModel.localAPIEnabled && !viewModel.localAPIServer.isRunning {
                    viewModel.toggleLocalAPI()
                }
            }
            .onAppear {
                viewModel.loadDocuments()
                maybeOpenFirstDocument()
            }
            .onChange(of: viewModel.documents.count) { _, _ in
                maybeOpenFirstDocument()
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
    @AppStorage("localAPIEnabled") var localAPIEnabled: Bool = false
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
    func toggleLocalAPI() {
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
            UIPasteboard.general.string = info
            apiConnectionInfo = info
            print("PoseyAPI: \(info)")
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

            default:
                return #"{"error":"Unknown command: \#(verb)"}"#
            }
        } catch {
            return json(["error": error.localizedDescription])
        }
    }

    // MARK: — Import handler

    func apiImport(filename: String, data: Data) async -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let doc: Document
            if ext == "pdf" {
                pdfImportStatusMessage = "API: Importing \(filename)\u{2026}"
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
