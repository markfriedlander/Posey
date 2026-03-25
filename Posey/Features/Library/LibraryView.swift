import Combine
import SwiftUI
import UniformTypeIdentifiers

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
                if viewModel.documents.isEmpty {
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

    private func maybeOpenFirstDocument() {
        guard shouldAutoOpenFirstDocument else {
            return
        }

        guard path.isEmpty, let firstDocument = viewModel.documents.first else {
            return
        }

        path = [firstDocument]
    }

    private var markdownContentTypes: [UTType] {
        [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
    }

    private var richDocumentContentTypes: [UTType] {
        [UTType(filenameExtension: "docx"), UTType(filenameExtension: "epub")].compactMap { $0 }
    }
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var documents: [Document] = []
    @Published var isShowingError = false
    @Published var errorMessage = ""

    let databaseManager: DatabaseManager
    private lazy var txtLibraryImporter = TXTLibraryImporter(databaseManager: databaseManager)
    private lazy var markdownLibraryImporter = MarkdownLibraryImporter(databaseManager: databaseManager)
    private lazy var rtfLibraryImporter = RTFLibraryImporter(databaseManager: databaseManager)
    private lazy var docxLibraryImporter = DOCXLibraryImporter(databaseManager: databaseManager)
    private lazy var htmlLibraryImporter = HTMLLibraryImporter(databaseManager: databaseManager)
    private lazy var epubLibraryImporter = EPUBLibraryImporter(databaseManager: databaseManager)
    private lazy var pdfLibraryImporter = PDFLibraryImporter(databaseManager: databaseManager)

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
            guard let url = try result.get().first else {
                return
            }

            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let fileType = url.pathExtension.lowercased()

            switch fileType {
            case "txt":
                _ = try txtLibraryImporter.importDocument(from: url)
            case "md", "markdown":
                _ = try markdownLibraryImporter.importDocument(from: url)
            case "rtf":
                _ = try rtfLibraryImporter.importDocument(from: url)
            case "docx":
                _ = try docxLibraryImporter.importDocument(from: url)
            case "html", "htm":
                _ = try htmlLibraryImporter.importDocument(from: url)
            case "epub":
                _ = try epubLibraryImporter.importDocument(from: url)
            case "pdf":
                _ = try pdfLibraryImporter.importDocument(from: url)
            default:
                throw LibraryImportError.unsupportedFileType
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

private enum LibraryImportError: LocalizedError {
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
                return "Posey can import TXT, Markdown, RTF, DOCX, HTML, EPUB, and text-based PDF files in this pass."
        }
    }
}
