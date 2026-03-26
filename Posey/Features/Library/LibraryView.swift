import Combine
import SwiftUI
import UniformTypeIdentifiers

// ========== BLOCK 01: LIBRARY VIEW - START ==========

struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @State private var isImporting = false
    @State private var path: [Document] = []
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

    let databaseManager: DatabaseManager
    private lazy var txtLibraryImporter    = TXTLibraryImporter(databaseManager: databaseManager)
    private lazy var markdownLibraryImporter = MarkdownLibraryImporter(databaseManager: databaseManager)
    private lazy var rtfLibraryImporter    = RTFLibraryImporter(databaseManager: databaseManager)
    private lazy var docxLibraryImporter   = DOCXLibraryImporter(databaseManager: databaseManager)
    private lazy var htmlLibraryImporter   = HTMLLibraryImporter(databaseManager: databaseManager)
    private lazy var epubLibraryImporter   = EPUBLibraryImporter(databaseManager: databaseManager)
    private lazy var pdfLibraryImporter    = PDFLibraryImporter(databaseManager: databaseManager)

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
