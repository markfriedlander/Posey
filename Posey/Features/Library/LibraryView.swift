import Combine
import NaturalLanguage
import SwiftUI
import UniformTypeIdentifiers

#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: LIBRARY VIEW - START ==========

struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .remoteRegister("library.document.\(document.title)") {
                    if path.last?.id != document.id { path = [document] }
                }
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
                #if DEBUG
                // M9 release-binary hygiene: the local-API antenna
                // toggle is a development-only affordance. DEBUG
                // builds expose it; release App Store builds compile
                // it out entirely so a user picking up Posey from
                // the App Store has no idea the developer-API
                // surface exists.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.toggleLocalAPI()
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(viewModel.localAPIEnabled
                                             ? Color.primary
                                             : Color.primary.opacity(0.25))
                    }
                    .remoteRegister("library.apiToggle") {
                        viewModel.toggleLocalAPI()
                    }
                    .accessibilityLabel(viewModel.localAPIEnabled ? "API On" : "API Off")
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import File") {
                        isImporting = true
                    }
                    .disabled(viewModel.pdfImportStatusMessage != nil)
                    .remoteRegister("library.importTXT") {
                        isImporting = true
                    }
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
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteOpenDocument)
            ) { notification in
                guard let documentID = notification.userInfo?["documentID"] as? UUID else { return }
                let documents = (try? viewModel.databaseManager.documents()) ?? []
                guard let document = documents.first(where: { $0.id == documentID }) else { return }
                if path.last?.id != documentID {
                    path = [document]
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteLibraryNavigateBack)
            ) { _ in
                if !path.isEmpty { path.removeLast() }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteAntennaOff)
            ) { _ in
                if viewModel.localAPIEnabled { viewModel.toggleLocalAPI() }
            }
            .onReceive(
                NotificationCenter.default
                    .publisher(for: .openAskPoseyForDocument)
            ) { notification in
                // M6 simulator-MCP UI driver: when /open-ask-posey
                // posts this notification, navigate to the matching
                // document. ReaderView listens to the same
                // notification and opens the Ask Posey sheet on
                // appear / receipt — so by the time the screenshot
                // fires, the sheet is up.
                guard
                    let info = notification.userInfo,
                    let documentID = info["documentID"] as? UUID
                else { return }
                let documents = (try? viewModel.databaseManager.documents()) ?? []
                guard let document = documents.first(where: { $0.id == documentID }) else { return }
                // Push if not already at this document.
                let needsNavigation = path.last?.id != documentID
                if needsNavigation {
                    path = [document]
                }
                // Re-post the notification on a short delay so
                // ReaderView (just mounted) catches it. Without this,
                // ReaderView's onReceive registers AFTER the original
                // post and never fires. Using userInfo.markRedelivered
                // so the Library observer doesn't re-fire and create
                // an infinite navigation loop.
                if needsNavigation,
                   info["redelivered"] == nil {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        var redeliveredInfo = info
                        redeliveredInfo["redelivered"] = true
                        NotificationCenter.default.post(
                            name: .openAskPoseyForDocument,
                            object: nil,
                            userInfo: redeliveredInfo
                        )
                    }
                }
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
                // Phase B — kick off background contextual enhancement
                // after a short delay so the library/reader appear is
                // smooth before background AFM work begins competing
                // for resources. The scheduler is idempotent and self-
                // exits when there's no pending work.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                    viewModel.enhancementScheduler?.start()
                }
                // M9 release-binary hygiene: the local API server is
                // a development tool. DEBUG builds force-on the
                // antenna at launch (developer convenience); RELEASE
                // builds compile out the auto-start AND the toggle UI
                // entirely so the API never starts unless someone
                // recompiles in DEBUG configuration. The
                // localAPIEnabled @AppStorage default is also OFF in
                // RELEASE (LibraryViewModel) — defense in depth.
                #if DEBUG
                if !viewModel.localAPIEnabled {
                    viewModel.localAPIEnabled = true
                }
                if viewModel.localAPIEnabled && !viewModel.localAPIServer.isRunning {
                    viewModel.toggleLocalAPI(showConnectionInfo: false)
                }
                #endif
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
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: message)
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
    /// Local API antenna default. **DEBUG: ON, RELEASE: OFF.** Per
    /// Mark's M9-blocker requirement — App Store builds must ship
    /// with the antenna OFF by default so users opt in explicitly.
    /// DEBUG builds keep the development convenience of auto-start
    /// (further force-on'd at launch in `body.onAppear`'s `#if DEBUG`
    /// block, so resetting the toggle in dev sessions is harmless).
    #if DEBUG
    @AppStorage("localAPIEnabled") var localAPIEnabled: Bool = true
    #else
    @AppStorage("localAPIEnabled") var localAPIEnabled: Bool = false
    #endif
    /// Set to the connection string when the API starts; drives the "copied" alert.
    @Published var apiConnectionInfo: String? = nil

    let databaseManager: DatabaseManager
    /// Shared Ask Posey embedding index. Built once per LibraryViewModel
    /// instance and handed to every importer so chunks land at import
    /// time across all formats (format-parity standing policy).
    private lazy var embeddingIndex: DocumentEmbeddingIndex = {
        // Wire the AFM-backed metadata extractor when AFM is available.
        // On older OS versions or devices without AFM, the closure is
        // nil and DocumentEmbeddingIndex skips the metadata enhancement
        // stage — content chunks still get indexed, just without the
        // synthesized metadata chunk.
        var extractor: DocumentEmbeddingIndex.MetadataExtractorClosure? = nil
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let service = DocumentMetadataService()
            extractor = { document in
                await service.extractMetadata(from: document)
            }
        }
        #endif
        return DocumentEmbeddingIndex(
            database: databaseManager,
            metadataExtractor: extractor
        )
    }()

    /// Phase B background-enhancement scheduler. Held lazily so it
    /// only spins up if AFM is available; on older OS versions this
    /// stays nil and Phase B is a no-op (Phase A still functional).
    @MainActor lazy var enhancementScheduler: BackgroundEnhancementScheduler? = {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let enhancer = DocumentChunkEnhancer()
            let enhanceClosure: DocumentChunkContextClosure = { text, summary, title in
                await enhancer.contextNote(
                    forChunk: text,
                    documentSummary: summary,
                    documentTitle: title)
            }
            let embedClosure: BackgroundEnhancementScheduler.ChunkEmbedClosure = { text, kind in
                DocumentEmbeddingIndex.embedTextWithKind(text: text, kind: kind)
            }
            return BackgroundEnhancementScheduler(
                database: databaseManager,
                enhance: enhanceClosure,
                embedText: embedClosure
            )
        }
        #endif
        return nil
    }()
    private lazy var txtLibraryImporter      = TXTLibraryImporter(databaseManager: databaseManager, embeddingIndex: embeddingIndex)
    private lazy var markdownLibraryImporter = MarkdownLibraryImporter(databaseManager: databaseManager, embeddingIndex: embeddingIndex)
    private lazy var rtfLibraryImporter      = RTFLibraryImporter(databaseManager: databaseManager, embeddingIndex: embeddingIndex)
    private lazy var docxLibraryImporter     = DOCXLibraryImporter(databaseManager: databaseManager, embeddingIndex: embeddingIndex)
    private lazy var htmlLibraryImporter     = HTMLLibraryImporter(databaseManager: databaseManager, embeddingIndex: embeddingIndex)
    private lazy var epubLibraryImporter     = EPUBLibraryImporter(databaseManager: databaseManager, embeddingIndex: embeddingIndex)
    private lazy var pdfLibraryImporter      = PDFLibraryImporter(databaseManager: databaseManager, embeddingIndex: embeddingIndex)
    // Task 13 #1 (2026-05-03): the LocalAPIServer type and instance
    // exist only in DEBUG builds. Release binaries do not ship the
    // HTTP listener, the bearer-token handling, or any port-bind
    // code. All call sites are guarded by `#if DEBUG`.
    #if DEBUG
    let localAPIServer = LocalAPIServer()
    #endif

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
        #if DEBUG
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
                },
                askHandler: { [weak self] data in
                    await self?.apiAsk(bodyData: data) ?? #"{"error":"unavailable"}"#
                },
                openAskPoseyHandler: { [weak self] data in
                    await self?.apiOpenAskPosey(bodyData: data) ?? #"{"error":"unavailable"}"#
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
        #else
        // Release builds: no-op. The HTTP server type doesn't ship.
        _ = showConnectionInfo
        #endif
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

            case "SEED_ASK_POSEY_FIXTURE":
                // 2026-05-05 — Test-only verb. Seeds a fixture
                // assistant turn into a document's persisted Ask
                // Posey conversation so the simulator can exercise
                // the rendering paths (citation chips, sources
                // strip pill numbering, scroll behavior) WITHOUT
                // needing AFM to be available — the simulator does
                // not have AFM model assets in some configurations.
                //
                // Args: <doc-id>. The fixture is fixed: a short
                // user question, then an assistant response that
                // cites `[2][3]` (twice, adjacent each time) over
                // a chunksInjected array of 3 entries with offsets
                // 100/200/300 and decreasing relevance. Tap a chip
                // → reader jumps to the chunk's startOffset; tap a
                // sources-strip pill → same dispatch. Pill labels
                // MUST read 2 and 3 to pass.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: SEED_ASK_POSEY_FIXTURE:<doc-id>"}"#
                }
                let docs2 = try databaseManager.documents()
                guard docs2.first(where: { $0.id == id }) != nil else {
                    return #"{"error":"Document not found"}"#
                }
                let now = Date()
                let userTurn = StoredAskPoseyTurn(
                    id: UUID().uuidString,
                    documentID: id,
                    timestamp: now.addingTimeInterval(-5),
                    role: "user",
                    content: "What questions does the book raise about colony structure and honey production?",
                    invocation: "document",
                    anchorOffset: nil,
                    intent: "general",
                    chunksInjectedJSON: "[]",
                    fullPromptForLogging: nil,
                    summaryOfTurnsThrough: 0,
                    isSummary: false
                )
                let fixtureChunks: [[String: Any]] = [
                    ["chunkID": 1001, "startOffset": 100, "text": "Front-matter blurb describing the book.", "relevance": 0.78],
                    ["chunkID": 1002, "startOffset": 1200, "text": "A passage about the colony's queen and worker structure.", "relevance": 0.55],
                    ["chunkID": 1003, "startOffset": 2400, "text": "A passage about nectar collection and honey production.", "relevance": 0.42]
                ]
                let chunksJSON: String = {
                    if let data = try? JSONSerialization.data(withJSONObject: fixtureChunks),
                       let s = String(data: data, encoding: .utf8) {
                        return s
                    }
                    return "[]"
                }()
                let assistantTurn = StoredAskPoseyTurn(
                    id: UUID().uuidString,
                    documentID: id,
                    timestamp: now,
                    role: "assistant",
                    content: "The book raises questions about how the colony coordinates work between the queen and workers,[2][3] and how nectar is converted into long-lasting honey through repeated regurgitation and evaporation.[2][3]",
                    invocation: "document",
                    anchorOffset: nil,
                    intent: nil,
                    chunksInjectedJSON: chunksJSON,
                    fullPromptForLogging: "[seeded-fixture]",
                    summaryOfTurnsThrough: 0,
                    isSummary: false
                )
                try databaseManager.appendAskPoseyTurn(userTurn)
                try databaseManager.appendAskPoseyTurn(assistantTurn)
                return json([
                    "seeded": true,
                    "documentID": id.uuidString,
                    "userTurnID": userTurn.id,
                    "assistantTurnID": assistantTurn.id,
                    "expectedPills": [2, 3],
                    "chunksInjectedCount": 3
                ])

            case "SET_EMBEDDING_PROVIDER":
                // 2026-05-04 — Layer 2 benchmark verb. Args:
                //   nlSentence | nlContextual | coreMLMiniLM
                // Switches the provider used by future indexing AND
                // by query embedding for chunks of the matching kind.
                // No automatic reindex — use REINDEX_DOCUMENT after
                // switching to actually use the new provider for
                // existing docs.
                let raw = arg ?? ""
                guard let provider = DocumentEmbeddingIndex.EmbeddingProvider(rawValue: raw) else {
                    let valid = DocumentEmbeddingIndex.EmbeddingProvider.allCases.map { $0.rawValue }.joined(separator: ", ")
                    return #"{"error":"Usage: SET_EMBEDDING_PROVIDER:<\#(valid)>"}"#
                }
                DocumentEmbeddingIndex.preferredProvider = provider
                return json(["embeddingProvider": provider.rawValue])

            case "GET_EMBEDDING_PROVIDER":
                return json(["embeddingProvider": DocumentEmbeddingIndex.preferredProvider.rawValue])

            case "REINDEX_DOCUMENT":
                // 2026-05-04 — RAG fix verb. Wipes existing chunks
                // and rebuilds the embedding index for one doc using
                // current chunking config (e.g. after TOC-skip
                // landed). Args: <doc-id>.
                //
                // 2026-05-05 — Switched from indexIfNeeded (synchronous,
                // no metadata enhancement) to enqueueIndexing (async,
                // triggers AFM metadata extraction + synthetic chunk
                // insertion). Returns immediately with chunkCount = 0
                // because the work is dispatched in the background;
                // poll LIST_CHUNKS or GET_DOCUMENT_METADATA to see
                // when it completes.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: REINDEX_DOCUMENT:<doc-id>"}"#
                }
                let docs = try databaseManager.documents()
                guard let doc = docs.first(where: { $0.id == id }) else {
                    return #"{"error":"Document not found"}"#
                }
                try databaseManager.deleteChunks(for: id)
                embeddingIndex.enqueueIndexing(doc)
                return json([
                    "reindexed": true,
                    "id": id.uuidString,
                    "note": "Reindexing dispatched in background — metadata extraction will run after chunking completes."
                ])

            case "RESET_DOCUMENT_METADATA":
                // 2026-05-05 — Clear extracted metadata so re-extraction
                // can run on the next REINDEX_DOCUMENT (without this,
                // enhanceMetadata short-circuits on the existing
                // extracted_at > 0 sentinel). Used during testing.
                // Writes a sentinel record with extractedAt = epoch 0;
                // documentMetadata(for:) returns nil for that row, so
                // the "already extracted" check fails and re-extraction
                // fires on the next pass.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: RESET_DOCUMENT_METADATA:<doc-id>"}"#
                }
                let cleared = StoredDocumentMetadata(
                    title: nil,
                    authors: [],
                    year: nil,
                    documentType: nil,
                    summary: nil,
                    extractedAt: Date(timeIntervalSince1970: 0),
                    detectedNonEnglish: false
                )
                try databaseManager.saveDocumentMetadata(cleared, for: id)
                return json(["reset": true, "id": id.uuidString])

            case "EXTRACT_METADATA_NOW":
                // 2026-05-05 — Diagnostic verb for the metadata
                // extraction path. Bypasses the chunking pipeline; calls
                // DocumentMetadataService directly and returns the raw
                // result, including AFM availability + any error
                // captured at the call site.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: EXTRACT_METADATA_NOW:<doc-id>"}"#
                }
                let docs = try databaseManager.documents()
                guard let doc = docs.first(where: { $0.id == id }) else {
                    return #"{"error":"Document not found"}"#
                }
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                    let model = SystemLanguageModel.default
                    let availabilityStr: String
                    switch model.availability {
                    case .available: availabilityStr = "available"
                    case .unavailable(let reason): availabilityStr = "unavailable(\(reason))"
                    @unknown default: availabilityStr = "unknown"
                    }
                    if model.availability != .available {
                        return json(["extracted": false,
                                     "reason": "AFM availability: \(availabilityStr)"])
                    }
                    // Call the service AND also catch the error inline
                    // so we can return what AFM actually said.
                    let snippet = String(doc.plainText.prefix(4000))
                    let session = LanguageModelSession(
                        model: model,
                        instructions: "You extract structured metadata from documents. Return concise factual fields. Do not invent. Use empty strings for unknown fields. The summary should be one or two complete sentences."
                    )
                    do {
                        let response = try await session.respond(
                            to: """
                            Below is the opening of a document. Extract its metadata.
                            ----- DOCUMENT OPENING -----
                            \(snippet)
                            ----- END DOCUMENT OPENING -----
                            """,
                            generating: DocumentMetadataPayload.self
                        )
                        let payload = response.content
                        return json([
                            "extracted": true,
                            "afmAvailability": availabilityStr,
                            "title": payload.title,
                            "authors": payload.authors,
                            "year": payload.year,
                            "documentType": payload.documentType,
                            "summary": payload.summary
                        ])
                    } catch {
                        return json([
                            "extracted": false,
                            "afmAvailability": availabilityStr,
                            "errorType": "\(type(of: error))",
                            "errorDescription": "\(error)"
                        ])
                    }
                } else {
                    return json(["extracted": false, "reason": "iOS 26 / macOS 26 required"])
                }
                #else
                return json(["extracted": false, "reason": "FoundationModels framework not available at compile time"])
                #endif

            case "RUN_METADATA_CHAIN":
                // 2026-05-05 — Diagnostic: directly run enhanceMetadata
                // synchronously (well, awaited) and report the outcome.
                // Bypasses the dispatch chain inside enqueueIndexing
                // so we can isolate whether the issue is the chain
                // plumbing vs the enhancement logic itself.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: RUN_METADATA_CHAIN:<doc-id>"}"#
                }
                let docs = try databaseManager.documents()
                guard let doc = docs.first(where: { $0.id == id }) else {
                    return #"{"error":"Document not found"}"#
                }
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                    let service = DocumentMetadataService()
                    let extractor: DocumentEmbeddingIndex.MetadataExtractorClosure = { d in
                        await service.extractMetadata(from: d)
                    }
                    await embeddingIndex.enhanceMetadata(doc, extractor: extractor)
                    let after = try? databaseManager.documentMetadata(for: id)
                    let stored = try databaseManager.chunks(for: id)
                    let synthCount = stored.filter {
                        DocumentEmbeddingIndex.isSyntheticKind($0.embeddingKind)
                    }.count
                    return json([
                        "ranChain": true,
                        "metadataExtracted": after != nil,
                        "syntheticChunkCount": synthCount,
                        "lastFailureReason": DocumentMetadataService.lastFailureReason
                    ])
                } else {
                    return json(["error": "iOS 26 / macOS 26 required"])
                }
                #else
                return json(["error": "FoundationModels framework not available"])
                #endif

            case "PHASE_B_DEBUG":
                // 2026-05-05 — Surface the scheduler's internal state
                // for debugging when chunks aren't getting processed.
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                    let lastFail = DocumentChunkEnhancer.lastFailureReason
                    let pendingDocs = (try? databaseManager.documentsWithPendingChunks()) ?? []
                    let info = ProcessInfo.processInfo
                    return json([
                        "schedulerWired": enhancementScheduler != nil,
                        "isPaused": enhancementScheduler?.isPausedForUserAFM ?? false,
                        "currentReadingDocumentID": enhancementScheduler?.currentReadingDocumentID?.uuidString ?? "",
                        "currentReadingOffset": enhancementScheduler?.currentReadingOffset ?? -1,
                        "pendingDocumentCount": pendingDocs.count,
                        "lowPowerMode": info.isLowPowerModeEnabled,
                        "thermalState": "\(info.thermalState)",
                        "lastEnhancerFailure": lastFail
                    ])
                }
                #endif
                return json(["schedulerWired": false])

            case "PHASE_B_STATUS":
                // 2026-05-05 — Show enhanced/failed/pending counts
                // for a document, with the AFM-vs-fallback split
                // surfaced so the user can see how many chunks
                // landed via AFM vs via the deterministic fallback.
                // The "enhanced" total counts both, since both result
                // in a real context note on the chunk; the split
                // tells you the QUALITY mix (AFM is more targeted,
                // fallback is attribution + entities + summary).
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: PHASE_B_STATUS:<doc-id>"}"#
                }
                let split = try databaseManager.chunkEnhancementCountsBySource(for: id)
                let enhanced = split.afm + split.fallback
                let total = enhanced + split.failed + split.pending
                let afmRate = enhanced == 0 ? 0.0 : (100.0 * Double(split.afm) / Double(enhanced))
                return json([
                    "documentID": id.uuidString,
                    "enhanced": enhanced,
                    "afm": split.afm,
                    "fallback": split.fallback,
                    "failed": split.failed,
                    "pending": split.pending,
                    "total": total,
                    "afmAcceptRate": afmRate
                ])

            case "PHASE_B_START":
                // Force-start the scheduler. Useful for tests that
                // import a doc and want enhancement to kick off
                // without waiting for the library .task to fire.
                if let scheduler = enhancementScheduler {
                    scheduler.start()
                    return json(["started": true])
                } else {
                    return json(["started": false, "reason": "AFM unavailable"])
                }

            case "PHASE_B_STOP":
                if let scheduler = enhancementScheduler {
                    scheduler.stop()
                    return json(["stopped": true])
                } else {
                    return json(["stopped": false, "reason": "scheduler nil"])
                }

            case "ENHANCE_CHUNK_NOW":
                // 2026-05-05 — Diagnostic: run the chunk enhancer on
                // ONE chunk in isolation and report what AFM said
                // (or what error). Used to iterate on the enhancer
                // prompt without waiting for the whole library.
                // Args: <doc-id>:<chunk-index>
                let raw = arg ?? ""
                let parts = raw.split(separator: ":", maxSplits: 1,
                                      omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let id = UUID(uuidString: String(parts[0])),
                      let chunkIdx = Int(String(parts[1])) else {
                    return #"{"error":"Usage: ENHANCE_CHUNK_NOW:<doc-id>:<chunk-index>"}"#
                }
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                    let chunks = try databaseManager.chunks(for: id)
                    guard let target = chunks.first(where: { $0.chunkIndex == chunkIdx }) else {
                        return #"{"error":"Chunk not found"}"#
                    }
                    let docs = try databaseManager.documents()
                    let doc = docs.first(where: { $0.id == id })
                    let metadata = try? databaseManager.documentMetadata(for: id)
                    let title = doc?.title ?? "Untitled"
                    let summary = metadata?.summary
                    let enhancer = DocumentChunkEnhancer()
                    DocumentChunkEnhancer.lastFailureReason = ""
                    let note = await enhancer.contextNote(
                        forChunk: target.text,
                        documentSummary: summary,
                        documentTitle: title)
                    return json([
                        "chunkIndex": chunkIdx,
                        "chunkTextPreview": String(target.text.prefix(300)),
                        "afmNote": note ?? "",
                        "succeeded": note != nil && !(note?.isEmpty ?? true),
                        "lastFailureReason": DocumentChunkEnhancer.lastFailureReason
                    ])
                }
                #endif
                return json(["error": "AFM unavailable"])

            case "RETRY_REFUSED":
                // 2026-05-05 — Reset all ctx_status=2 chunks back to
                // pending so the scheduler retries them with the
                // current enhancer prompt. Used to test prompt
                // iterations on the same content.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: RETRY_REFUSED:<doc-id>"}"#
                }
                let resetCount = try databaseManager.resetFailedChunks(for: id)
                return json([
                    "documentID": id.uuidString,
                    "resetToPending": resetCount
                ])

            case "LIST_REFUSED_CHUNKS":
                // 2026-05-05 — Diagnostic: list chunks that AFM
                // refused during Phase B enhancement (ctx_status = 2),
                // with full text. Lets us inspect what content
                // triggered AFM's safety system so we can iterate
                // on prompt design or implement a fallback path.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: LIST_REFUSED_CHUNKS:<doc-id>"}"#
                }
                let stored = try databaseManager.chunks(for: id)
                let candidates = try databaseManager.unenhancedChunks(for: id)
                let candIndices = Set(candidates.map { $0.chunkIndex })
                // ctx_status=2 chunks aren't in unenhancedChunks (which
                // only returns ctx_status=0). Get them via direct query.
                let refused = try databaseManager.enhancedChunkRecords(for: id, limit: 500)
                    .filter { $0.ctxStatus == 2 }
                let items: [[String: Any]] = refused.map { rec in
                    let fullChunk = stored.first { $0.chunkIndex == rec.chunkIndex }
                    return [
                        "chunkIndex": rec.chunkIndex,
                        "startOffset": rec.startOffset,
                        "text": fullChunk?.text ?? rec.text
                    ]
                }
                _ = candIndices
                return json([
                    "documentID": id.uuidString,
                    "refusedCount": items.count,
                    "chunks": items
                ])

            case "LIST_ENHANCED_CHUNKS":
                // 2026-05-05 — Show which chunks have been ctx-enhanced
                // with their context notes. Args: <doc-id>[:<limit>].
                let raw = arg ?? ""
                let parts = raw.split(separator: ":", maxSplits: 1,
                                      omittingEmptySubsequences: false)
                guard parts.count >= 1,
                      let id = UUID(uuidString: String(parts[0])) else {
                    return #"{"error":"Usage: LIST_ENHANCED_CHUNKS:<doc-id>[:<limit>]"}"#
                }
                let limit = parts.count >= 2 ? (Int(String(parts[1])) ?? 20) : 20
                let canonical = try databaseManager.enhancedChunkRecords(for: id, limit: limit)
                let items: [[String: Any]] = canonical.map { rec in
                    [
                        "chunkIndex": rec.chunkIndex,
                        "startOffset": rec.startOffset,
                        "ctxStatus": rec.ctxStatus,
                        "contextNote": rec.contextNote ?? "",
                        "textPreview": String(rec.text.prefix(120))
                    ]
                }
                return json([
                    "documentID": id.uuidString,
                    "returned": items.count,
                    "chunks": items
                ])

            case "GET_DOCUMENT_METADATA":
                // 2026-05-05 — Read extracted metadata for a document.
                // Returns nil-valued fields when extraction hasn't run.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: GET_DOCUMENT_METADATA:<doc-id>"}"#
                }
                guard let metadata = try databaseManager.documentMetadata(for: id) else {
                    return json([
                        "documentID": id.uuidString,
                        "extracted": false
                    ])
                }
                var result: [String: Any] = [
                    "documentID": id.uuidString,
                    "extracted": true,
                    "extractedAt": ISO8601DateFormatter().string(from: metadata.extractedAt),
                    "authors": metadata.authors,
                    "detectedNonEnglish": metadata.detectedNonEnglish
                ]
                if let title = metadata.title { result["title"] = title }
                if let year = metadata.year { result["year"] = year }
                if let type = metadata.documentType { result["documentType"] = type }
                if let summary = metadata.summary { result["summary"] = summary }
                return json(result)

            case "LIST_SYNTHETIC_CHUNKS":
                // 2026-05-05 — Diagnostic verb to inspect synthetic
                // chunks for a document. Filters document_chunks by
                // embedding_kind suffix ":syn-meta" so we can verify
                // the metadata enhancement actually landed.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: LIST_SYNTHETIC_CHUNKS:<doc-id>"}"#
                }
                let stored = try databaseManager.chunks(for: id)
                let synthetic = stored.filter {
                    DocumentEmbeddingIndex.isSyntheticKind($0.embeddingKind)
                }
                let items: [[String: Any]] = synthetic.map { c in
                    [
                        "chunkIndex": c.chunkIndex,
                        "embeddingKind": c.embeddingKind,
                        "startOffset": c.startOffset,
                        "endOffset": c.endOffset,
                        "text": c.text
                    ]
                }
                return json([
                    "documentID": id.uuidString,
                    "syntheticChunkCount": items.count,
                    "chunks": items
                ])

            case "LIST_CHUNKS":
                // 2026-05-04 — RAG audit verb. Args:
                //   <doc-id>:<offset>:<limit>
                // Returns chunk metadata + text preview for the
                // given range. Used by the Layer 1 chunking audit
                // to inspect what's actually in the index per format.
                let parts = (arg ?? "").split(separator: ":", maxSplits: 2,
                                              omittingEmptySubsequences: false)
                guard parts.count >= 1, let id = UUID(uuidString: String(parts[0])) else {
                    return #"{"error":"Usage: LIST_CHUNKS:<doc-id>[:offset:limit]"}"#
                }
                let offset: Int = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
                let limit: Int  = parts.count >= 3 ? (Int(parts[2]) ?? 20) : 20
                let stored = try databaseManager.chunks(for: id)
                let total = stored.count
                let slice = Array(stored.dropFirst(offset).prefix(limit))
                let items: [[String: Any]] = slice.map { c in
                    [
                        "chunkIndex": c.chunkIndex,
                        "startOffset": c.startOffset,
                        "endOffset": c.endOffset,
                        "length": c.endOffset - c.startOffset,
                        "embeddingKind": c.embeddingKind,
                        "preview": String(c.text.prefix(120)),
                        "tail": String(c.text.suffix(60))
                    ]
                }
                return json(["totalChunks": total, "offset": offset,
                             "returned": slice.count, "chunks": items])

            case "EMBED_QUERY_CONTEXTUAL":
                // 2026-05-04 — Layer 2 benchmark verb. Args:
                //   <doc-id>:<query>
                // Re-embeds `query` AND every chunk using
                // NLContextualEmbedding, computes cosine, returns
                // top-K. Used to A/B test contextual vs. NLEmbedding
                // on known-failing audit cases before committing to
                // a re-index. Slow (re-embeds every chunk per call)
                // but only used in development.
                let raw = arg ?? ""
                guard let colonIdx = raw.firstIndex(of: ":") else {
                    return #"{"error":"Usage: EMBED_QUERY_CONTEXTUAL:<doc-id>:<query>"}"#
                }
                let idStr = String(raw[..<colonIdx])
                let query = String(raw[raw.index(after: colonIdx)...])
                guard let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Invalid document ID"}"#
                }
                let stored = try databaseManager.chunks(for: id)
                guard let embedder = DocumentEmbeddingIndex.contextualEmbedder(for: .english) else {
                    return #"{"error":"NLContextualEmbedding unavailable on this device (iOS 17+ required, model assets must download)"}"#
                }
                guard let qVec = DocumentEmbeddingIndex.embedContextual(query, with: embedder) else {
                    return #"{"error":"Failed to embed query contextually"}"#
                }
                var scored: [(Int, Int, Double, String)] = []
                for c in stored.prefix(500) { // cap for speed
                    if let cv = DocumentEmbeddingIndex.embedContextual(c.text, with: embedder) {
                        let s = DocumentEmbeddingIndex.cosine(qVec, cv)
                        scored.append((c.chunkIndex, c.startOffset, s, String(c.text.prefix(80))))
                    }
                }
                let topK = scored.sorted { $0.2 > $1.2 }.prefix(15)
                let items: [[String: Any]] = topK.map { (idx, off, sim, prev) in
                    ["chunkIndex": idx, "startOffset": off, "similarity": sim, "preview": prev]
                }
                return json(["query": query, "scoredChunks": scored.count,
                             "totalChunks": stored.count, "topMatches": items])

            case "EMBED_QUERY":
                // 2026-05-04 — RAG audit verb. Args:
                //   <doc-id>:<query>
                // Returns the query embedding (truncated) plus the
                // top-K cosine similarities against every chunk in
                // the document. Used by the Layer 2 embedding-quality
                // audit to verify that semantically similar
                // questions and answers cluster correctly.
                let raw = arg ?? ""
                guard let colonIdx = raw.firstIndex(of: ":") else {
                    return #"{"error":"Usage: EMBED_QUERY:<doc-id>:<query>"}"#
                }
                let idStr = String(raw[..<colonIdx])
                let query = String(raw[raw.index(after: colonIdx)...])
                guard let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Invalid document ID"}"#
                }
                let stored = try databaseManager.chunks(for: id)
                let kind = stored.first?.embeddingKind ?? "en-sentence"
                // Match the query embedder to the chunks' embedding kind.
                let qVec: [Double]
                if kind == "en-contextual" {
                    if let ctx = DocumentEmbeddingIndex.contextualEmbedder(for: .english),
                       let v = DocumentEmbeddingIndex.embedContextual(query, with: ctx) {
                        qVec = v
                    } else {
                        qVec = [Double](repeating: 0, count: 384)
                    }
                } else if kind == "en-minilm" {
                    qVec = DocumentEmbeddingIndex.embedMiniLMSync(query) ?? [Double](repeating: 0, count: 384)
                } else {
                    let language = DocumentEmbeddingIndex.language(forKind: kind)
                    let embedder = DocumentEmbeddingIndex.embedder(for: language)
                    qVec = DocumentEmbeddingIndex.embed(query, with: embedder)
                }
                let scored: [(Int, Int, Double, String)] = stored.map { c in
                    let s = DocumentEmbeddingIndex.cosine(qVec, c.embedding)
                    return (c.chunkIndex, c.startOffset, s, String(c.text.prefix(80)))
                }
                let topK = scored.sorted { $0.2 > $1.2 }.prefix(20)
                let items: [[String: Any]] = topK.map { (idx, off, sim, prev) in
                    ["chunkIndex": idx, "startOffset": off,
                     "similarity": sim, "preview": prev]
                }
                return json(["query": query, "totalChunks": stored.count,
                             "topMatches": items])

            case "RAG_TRACE":
                // 2026-05-05 — Generalized RAG diagnostic. Args:
                //   <doc-id>:<query>[:<topK>]
                // Runs the production hybrid retrieval path
                // (`searchHybridDiagnostic`) and returns the score
                // decomposition for the top-K chunks: cosine, lexical,
                // entity-boost, combined, rank, plus the FULL chunk
                // text. Lets us answer "did retrieval find the right
                // chunk and at what rank, was it the cosine or lexical
                // signal that surfaced it, did the entity boost matter"
                // — exactly the questions chunking-vs-prompt-vs-AFM
                // debugging needs answered. See tools/posey_rag_debug.py
                // for the orchestrator that uses this.
                let raw = arg ?? ""
                let parts = raw.split(separator: ":", maxSplits: 2,
                                      omittingEmptySubsequences: false)
                guard parts.count >= 2,
                      let id = UUID(uuidString: String(parts[0])) else {
                    return #"{"error":"Usage: RAG_TRACE:<doc-id>:<query>[:<topK>]"}"#
                }
                // The query may itself contain colons; if topK was
                // supplied, parts[2] holds the rest. Detect topK vs
                // a colon-bearing query: if the LAST trailing
                // ":<integer>" parses as Int and parts.count == 3,
                // treat it as topK; otherwise re-glue.
                let query: String
                let topK: Int
                if parts.count == 3,
                   let candidate = Int(String(parts[2]).trimmingCharacters(in: .whitespaces)) {
                    query = String(parts[1])
                    topK = max(1, min(candidate, 50))
                } else if parts.count == 3 {
                    query = String(parts[1]) + ":" + String(parts[2])
                    topK = 10
                } else {
                    query = String(parts[1])
                    topK = 10
                }
                guard !query.isEmpty else {
                    return #"{"error":"Empty query"}"#
                }
                let totalChunks = try databaseManager.chunkCount(for: id)
                guard totalChunks > 0 else {
                    return #"{"error":"No chunks indexed for document"}"#
                }
                let diagnostic = try embeddingIndex.searchHybridDiagnostic(
                    documentID: id, query: query)
                let provider = diagnostic.first?.chunk.embeddingKind ?? "unknown"
                let topItems: [[String: Any]] = diagnostic.prefix(topK).map { r in
                    [
                        "rank": r.rank,
                        "chunkIndex": r.chunk.chunkIndex,
                        "startOffset": r.chunk.startOffset,
                        "endOffset": r.chunk.endOffset,
                        "cosine": r.cosine,
                        "lexical": r.lexical,
                        "entityBoosted": r.entityBoosted,
                        "combined": r.combined,
                        "embeddingKind": r.chunk.embeddingKind,
                        "text": r.chunk.text
                    ]
                }
                return json([
                    "query": query,
                    "topK": topK,
                    "totalChunks": totalChunks,
                    "embeddingProvider": provider,
                    "topMatches": topItems
                ])

            case "RAG_FIND":
                // 2026-05-05 — Ground-truth probe. Args:
                //   <doc-id>:<keyword>
                // Case-insensitive substring search in the document's
                // plainText. Returns every match offset and the chunk
                // that owns each offset (by [startOffset, endOffset)
                // range). Answers: "is the answer literally in the
                // document, where, and which chunk(s) hold it." When
                // paired with RAG_TRACE you can see whether retrieval
                // surfaced the chunk that contains the verbatim answer
                // or whether something earlier in the pipeline failed.
                //
                // The keyword is treated as a literal substring (no
                // regex). Multi-word phrases work as long as they
                // appear contiguous in the plainText. To probe a
                // pattern you'd need to chain multiple RAG_FIND calls
                // and union the results.
                let raw = arg ?? ""
                guard let colonIdx = raw.firstIndex(of: ":") else {
                    return #"{"error":"Usage: RAG_FIND:<doc-id>:<keyword>"}"#
                }
                let idStr = String(raw[..<colonIdx])
                let keyword = String(raw[raw.index(after: colonIdx)...])
                guard let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Invalid document ID"}"#
                }
                guard !keyword.isEmpty else {
                    return #"{"error":"Empty keyword"}"#
                }
                let docs = try databaseManager.documents()
                guard let doc = docs.first(where: { $0.id == id }) else {
                    return #"{"error":"Document not found"}"#
                }
                let haystack = doc.plainText.lowercased()
                let needle = keyword.lowercased()
                var matchOffsets: [Int] = []
                var searchStart = haystack.startIndex
                while searchStart < haystack.endIndex,
                      let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
                    let off = haystack.distance(from: haystack.startIndex, to: found.lowerBound)
                    matchOffsets.append(off)
                    searchStart = found.upperBound
                    if matchOffsets.count >= 200 { break } // safety cap
                }
                // Map offsets to chunks. A chunk owns offset O when
                // startOffset <= O < endOffset. With 10% overlap an
                // offset may belong to up to two chunks; we report
                // both so the diagnostic doesn't lie about which
                // window retrieval would actually rank.
                let stored = try databaseManager.chunks(for: id)
                let matchItems: [[String: Any]] = matchOffsets.map { offset in
                    let owners = stored.filter {
                        offset >= $0.startOffset && offset < $0.endOffset
                    }
                    let ownerInfo: [[String: Any]] = owners.map { c in
                        [
                            "chunkIndex": c.chunkIndex,
                            "startOffset": c.startOffset,
                            "endOffset": c.endOffset
                        ]
                    }
                    // Excerpt: 60 chars before + keyword + 60 chars
                    // after, from the ORIGINAL plainText (preserves
                    // case). Helps eyeball context without firing a
                    // separate GET_PLAIN_TEXT.
                    let plain = doc.plainText
                    let plainStart = plain.index(plain.startIndex,
                        offsetBy: max(0, offset - 60))
                    let plainEnd = plain.index(plain.startIndex,
                        offsetBy: min(plain.count, offset + keyword.count + 60))
                    let excerpt = String(plain[plainStart..<plainEnd])
                    return [
                        "offset": offset,
                        "chunks": ownerInfo,
                        "excerpt": excerpt
                    ]
                }
                return json([
                    "documentID": id.uuidString,
                    "keyword": keyword,
                    "matchCount": matchOffsets.count,
                    "matches": matchItems,
                    "totalChunks": stored.count,
                    "documentLength": doc.plainText.count
                ])

            case "GET_ASK_POSEY_HISTORY":
                // 2026-05-05 — RAG diagnostic helper. Args:
                //   <doc-id>[:<limit>]
                // Returns the persisted Ask Posey conversation history
                // for the document — every user/assistant turn in
                // chronological order, with role, content, intent,
                // and anchor offset. Lets us replay an old conversation
                // through the diagnostic harness without needing the
                // user to remember the exact question they asked.
                let raw = arg ?? ""
                let parts = raw.split(separator: ":", maxSplits: 1,
                                      omittingEmptySubsequences: false)
                guard parts.count >= 1,
                      let id = UUID(uuidString: String(parts[0])) else {
                    return #"{"error":"Usage: GET_ASK_POSEY_HISTORY:<doc-id>[:<limit>]"}"#
                }
                let limit: Int? = parts.count >= 2 ? Int(String(parts[1])) : nil
                let turns = try databaseManager.askPoseyTurns(for: id, limit: limit)
                let items: [[String: Any]] = turns.map { t in
                    var dict: [String: Any] = [
                        "id": t.id,
                        "timestamp": ISO8601DateFormatter().string(from: t.timestamp),
                        "role": t.role,
                        "content": t.content,
                        "invocation": t.invocation
                    ]
                    if let off = t.anchorOffset { dict["anchorOffset"] = off }
                    if let intent = t.intent { dict["intent"] = intent }
                    return dict
                }
                return json([
                    "documentID": id.uuidString,
                    "turnCount": items.count,
                    "turns": items
                ])

            case "DB_STATS":
                let docs = try databaseManager.documents()
                var byType: [String: Int] = [:]
                for doc in docs { byType[doc.fileType, default: 0] += 1 }
                return json(["documentCount": docs.count, "byFileType": byType])

            case "CLEAR_ASK_POSEY_CONVERSATION":
                // Wipe the persisted conversation for a given document
                // so the test harness can start clean. Mark's Three
                // Hats QA pass needs this to evaluate fresh-context
                // answer quality without prior turns biasing the
                // model. Implemented as a direct DELETE since
                // ask_posey_conversations cascades on document_id —
                // we only delete the conversation rows, the document
                // itself stays put.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Missing or invalid document ID"}"#
                }
                let cleared = try databaseManager.clearAskPoseyConversation(for: id)
                return json(["documentID": idStr, "rowsCleared": cleared])

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

            // ===== Remote-control verbs (2026-05-02) ===========================
            // Build per Mark's directive: the API must be able to do everything
            // a human can do that isn't blocked by Apple security policies.
            // Each verb posts a NotificationCenter event the matching SwiftUI
            // view observes and performs as the equivalent user action — same
            // pattern the existing /open-ask-posey path uses.

            case "READER_GOTO":
                // READER_GOTO:<docID>:<offset>
                guard let parts = arg?.split(separator: ":", maxSplits: 1).map(String.init),
                      parts.count == 2,
                      let docID = UUID(uuidString: parts[0]),
                      let offset = Int(parts[1]) else {
                    return #"{"error":"Usage: READER_GOTO:<docID>:<offset>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteReaderJumpToOffset,
                        object: nil,
                        userInfo: ["documentID": docID, "offset": offset]
                    )
                }
                return json(["status": "posted", "documentID": docID.uuidString, "offset": offset])

            case "READER_DOUBLE_TAP":
                // READER_DOUBLE_TAP:<docID>:<offset> — fires the same in-app
                // handler the double-tap sentence gesture invokes.
                guard let parts = arg?.split(separator: ":", maxSplits: 1).map(String.init),
                      parts.count == 2,
                      let docID = UUID(uuidString: parts[0]),
                      let offset = Int(parts[1]) else {
                    return #"{"error":"Usage: READER_DOUBLE_TAP:<docID>:<offset>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteReaderDoubleTap,
                        object: nil,
                        userInfo: ["documentID": docID, "offset": offset]
                    )
                }
                return json(["status": "posted", "documentID": docID.uuidString, "offset": offset])

            case "EXPORT_ANNOTATIONS":
                // EXPORT_ANNOTATIONS:<docID> — returns the Markdown
                // payload's filename + bytes + base64 so automation
                // can verify Task 12's export end-to-end without
                // tapping the share sheet.
                guard let docID = arg.flatMap({ UUID(uuidString: $0) }) else {
                    return #"{"error":"Usage: EXPORT_ANNOTATIONS:<docID>"}"#
                }
                let documents: [Document]
                do { documents = try databaseManager.documents() }
                catch { return #"{"error":"document lookup failed: \#(error)"}"# }
                guard let doc = documents.first(where: { $0.id == docID }) else {
                    return #"{"error":"document not found"}"#
                }
                let payload = await MainActor.run {
                    AnnotationExporter.export(document: doc, databaseManager: databaseManager)
                }
                return json([
                    "suggestedFilename": payload.suggestedFilename,
                    "mimeType": payload.mimeType,
                    "bytes": payload.bytes.count,
                    "base64": payload.bytes.base64EncodedString()
                ])

            case "READER_TAP":
                // Drive the same toggle-chrome code path the in-app
                // single tap invokes. No coords required — the tap
                // semantics are "toggle chrome visibility."
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteReaderToggleChrome, object: nil)
                }
                return json(["status": "posted"])

            case "READER_CHROME_STATE":
                let visible = await MainActor.run { ReaderChromeState.shared.isVisible }
                return json(["isChromeVisible": visible])

            case "READER_STATE":
                let snapshot = await MainActor.run { RemoteControlState.shared.snapshot() }
                return json(snapshot)

            case "OPEN_NOTES_SHEET":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteOpenNotesSheet, object: nil)
                }
                return json(["status": "posted"])

            case "DISMISS_SHEET":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteDismissPresentedSheet, object: nil)
                }
                return json(["status": "posted"])

            case "SCROLL_ASK_POSEY_TO_LATEST":
                // 2026-05-05 — Bring the most recent assistant message
                // into view in the open Ask Posey sheet, so the test
                // harness can screenshot the chips + SOURCES strip
                // when the conversation is taller than the visible
                // sheet area. AskPoseyView observes the notification
                // and runs a three-pass scrollTo(.bottom).
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteScrollAskPoseyToLatest, object: nil)
                }
                return json(["status": "posted"])

            case "CREATE_BOOKMARK":
                // CREATE_BOOKMARK:<docID>:<offset>
                guard let parts = arg?.split(separator: ":", maxSplits: 1).map(String.init),
                      parts.count == 2,
                      let docID = UUID(uuidString: parts[0]),
                      let offset = Int(parts[1]) else {
                    return #"{"error":"Usage: CREATE_BOOKMARK:<docID>:<offset>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteCreateBookmark,
                        object: nil,
                        userInfo: ["documentID": docID, "offset": offset]
                    )
                }
                return json(["status": "posted", "documentID": docID.uuidString, "offset": offset])

            case "CREATE_NOTE":
                // CREATE_NOTE:<docID>:<offset>:<base64-body>
                // Body is base64 to avoid escaping the colon separator.
                guard let parts = arg?.split(separator: ":", maxSplits: 2).map(String.init),
                      parts.count == 3,
                      let docID = UUID(uuidString: parts[0]),
                      let offset = Int(parts[1]),
                      let bodyData = Data(base64Encoded: parts[2]),
                      let body = String(data: bodyData, encoding: .utf8) else {
                    return #"{"error":"Usage: CREATE_NOTE:<docID>:<offset>:<base64-body>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteCreateNote,
                        object: nil,
                        userInfo: ["documentID": docID, "offset": offset, "body": body]
                    )
                }
                return json(["status": "posted", "documentID": docID.uuidString,
                             "offset": offset, "bodyLength": body.count])

            case "TAP":
                // TAP:<accessibilityID>
                // Tries the registry first (works reliably for SwiftUI
                // controls); falls back to UIView accessibility-tree
                // search for any UIKit elements that registered via
                // raw `.accessibilityIdentifier(_:)` without
                // `.remoteRegister`.
                guard let id = arg, !id.isEmpty else {
                    return #"{"error":"Usage: TAP:<accessibilityID>"}"#
                }
                let outcome = await MainActor.run { () -> [String: Any] in
                    if RemoteTargetRegistry.shared.fire(id) {
                        return ["accessibilityID": id, "found": true, "via": "registry"]
                    }
                    if RemoteControl.tap(accessibilityID: id) {
                        return ["accessibilityID": id, "found": true, "via": "uiview-tree"]
                    }
                    return ["accessibilityID": id, "found": false]
                }
                return json(outcome)

            case "TYPE":
                guard let text = arg else {
                    return #"{"error":"Usage: TYPE:<text>"}"#
                }
                let inserted = await MainActor.run { RemoteControl.type(text: text) }
                return json(["typed": inserted, "length": text.count])

            case "READ_TREE":
                let tree = await MainActor.run { RemoteControl.readTree() }
                return json(tree)

            case "SCREENSHOT":
                let pngData = await MainActor.run { RemoteControl.screenshotPNG() }
                guard let data = pngData else {
                    return #"{"error":"Screenshot failed (no key window)"}"#
                }
                return json(["bytes": data.count, "base64": data.base64EncodedString()])

            case "TAP_CITATION":
                guard let raw = arg, let n = Int(raw), n >= 1 else {
                    return #"{"error":"Usage: TAP_CITATION:<n>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteTapCitation,
                        object: nil,
                        userInfo: ["citationNumber": n]
                    )
                }
                return json(["status": "posted", "citationNumber": n])

            case "TAP_ASKPOSEY_ANCHOR":
                guard let storageID = arg, !storageID.isEmpty else {
                    return #"{"error":"Usage: TAP_ASKPOSEY_ANCHOR:<storageID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteTapAskPoseyAnchor,
                        object: nil,
                        userInfo: ["storageID": storageID]
                    )
                }
                return json(["status": "posted", "storageID": storageID])

            case "TAP_SAVED_ANNOTATION":
                guard let entryID = arg, !entryID.isEmpty else {
                    return #"{"error":"Usage: TAP_SAVED_ANNOTATION:<entryID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteTapSavedAnnotation,
                        object: nil,
                        userInfo: ["entryID": entryID]
                    )
                }
                return json(["status": "posted", "entryID": entryID])

            case "SCROLL_NOTES":
                guard let entryID = arg, !entryID.isEmpty else {
                    return #"{"error":"Usage: SCROLL_NOTES:<entryID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteScrollSavedAnnotations,
                        object: nil,
                        userInfo: ["entryID": entryID]
                    )
                }
                return json(["status": "posted", "entryID": entryID])

            case "TAP_JUMP_TO_NOTE":
                guard let entryID = arg, !entryID.isEmpty else {
                    return #"{"error":"Usage: TAP_JUMP_TO_NOTE:<entryID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteTapJumpToNote,
                        object: nil,
                        userInfo: ["entryID": entryID]
                    )
                }
                return json(["status": "posted", "entryID": entryID])

            // ===== Playback transport ==========================================
            case "PLAYBACK_PLAY":
                guard let idStr = arg, let docID = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: PLAYBACK_PLAY:<docID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remotePlaybackPlay, object: nil,
                                                    userInfo: ["documentID": docID])
                }
                return json(["status": "posted", "documentID": idStr])

            case "PLAYBACK_PAUSE":
                guard let idStr = arg, let docID = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: PLAYBACK_PAUSE:<docID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remotePlaybackPause, object: nil,
                                                    userInfo: ["documentID": docID])
                }
                return json(["status": "posted", "documentID": idStr])

            case "PLAYBACK_NEXT":
                guard let idStr = arg, let docID = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: PLAYBACK_NEXT:<docID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remotePlaybackNext, object: nil,
                                                    userInfo: ["documentID": docID])
                }
                return json(["status": "posted", "documentID": idStr])

            case "PLAYBACK_PREVIOUS":
                guard let idStr = arg, let docID = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: PLAYBACK_PREVIOUS:<docID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remotePlaybackPrevious, object: nil,
                                                    userInfo: ["documentID": docID])
                }
                return json(["status": "posted", "documentID": idStr])

            case "PLAYBACK_RESTART":
                guard let idStr = arg, let docID = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: PLAYBACK_RESTART:<docID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remotePlaybackRestart, object: nil,
                                                    userInfo: ["documentID": docID])
                }
                return json(["status": "posted", "documentID": idStr])

            case "PLAYBACK_STATE":
                // Equivalent to READER_STATE but scoped to playback fields only.
                let snap = await MainActor.run { RemoteControlState.shared.snapshot() }
                return json([
                    "playbackState": snap["playbackState"] ?? "idle",
                    "currentSentenceIndex": snap["currentSentenceIndex"] ?? 0,
                    "currentOffset": snap["currentOffset"] ?? 0,
                    "visibleDocumentID": snap["visibleDocumentID"] ?? NSNull()
                ])

            // ===== Sheet opens ================================================
            case "OPEN_PREFERENCES_SHEET":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteOpenPreferencesSheet, object: nil)
                }
                return json(["status": "posted"])

            case "OPEN_TOC_SHEET":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteOpenTOCSheet, object: nil)
                }
                return json(["status": "posted"])

            case "OPEN_AUDIO_EXPORT_SHEET":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteOpenAudioExportSheet, object: nil)
                }
                return json(["status": "posted"])

            case "OPEN_SEARCH_BAR":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteOpenSearchBar, object: nil)
                }
                return json(["status": "posted"])

            case "OPEN_DOCUMENT":
                guard let idStr = arg, let docID = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: OPEN_DOCUMENT:<docID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteOpenDocument, object: nil,
                                                    userInfo: ["documentID": docID])
                }
                return json(["status": "posted", "documentID": idStr])

            // ===== Library nav ================================================
            case "LIBRARY_NAVIGATE_BACK":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteLibraryNavigateBack, object: nil)
                }
                return json(["status": "posted"])

            case "ANTENNA_OFF":
                // Re-enabling the antenna is a user-consent surface (the
                // toolbar toggle); intentionally not exposed via API.
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteAntennaOff, object: nil)
                }
                return json(["status": "posted"])

            // ===== Preferences ================================================
            case "SET_VOICE_MODE":
                guard let value = arg?.lowercased(),
                      value == "best" || value == "custom" else {
                    return #"{"error":"Usage: SET_VOICE_MODE:<best|custom>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteSetVoiceMode, object: nil,
                                                    userInfo: ["isCustom": value == "custom"])
                }
                return json(["status": "posted", "voiceMode": value])

            case "SET_RATE":
                // Accepts the same percentage scale the in-app rate
                // slider uses: 50–200 (% of default speech rate). Only
                // takes effect in Custom voice mode — Best Available
                // honors the system Spoken Content rate, matching
                // existing UI behavior.
                guard let value = arg, let pct = Float(value), pct >= 50, pct <= 200 else {
                    return #"{"error":"Usage: SET_RATE:<percentage 50..200>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteSetRate, object: nil,
                                                    userInfo: ["ratePercentage": pct])
                }
                return json(["status": "posted", "ratePercentage": pct])

            case "SET_FONT_SIZE":
                guard let value = arg, let size = Double(value), size >= 14, size <= 44 else {
                    return #"{"error":"Usage: SET_FONT_SIZE:<14..44>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteSetFontSize, object: nil,
                                                    userInfo: ["fontSize": size])
                }
                return json(["status": "posted", "fontSize": size])

            case "SET_READING_STYLE":
                guard let raw = arg?.lowercased(),
                      ["standard", "focus", "immersive", "motion"].contains(raw) else {
                    return #"{"error":"Usage: SET_READING_STYLE:<standard|focus|immersive|motion>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteSetReadingStyle, object: nil,
                                                    userInfo: ["readingStyle": raw])
                }
                return json(["status": "posted", "readingStyle": raw])

            case "SET_MOTION_PREFERENCE":
                guard let raw = arg?.lowercased(),
                      ["off", "on", "auto"].contains(raw) else {
                    return #"{"error":"Usage: SET_MOTION_PREFERENCE:<off|on|auto>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteSetMotionPreference, object: nil,
                                                    userInfo: ["motionPreference": raw])
                }
                return json(["status": "posted", "motionPreference": raw])

            // ===== TOC + search ==============================================
            case "JUMP_TO_PAGE":
                // JUMP_TO_PAGE:<docID>:<page>
                guard let parts = arg?.split(separator: ":", maxSplits: 1).map(String.init),
                      parts.count == 2,
                      let docID = UUID(uuidString: parts[0]),
                      let page = Int(parts[1]) else {
                    return #"{"error":"Usage: JUMP_TO_PAGE:<docID>:<page>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteJumpToPage, object: nil,
                                                    userInfo: ["documentID": docID, "page": page])
                }
                return json(["status": "posted", "documentID": parts[0], "page": page])

            case "SEARCH":
                guard let query = arg else {
                    return #"{"error":"Usage: SEARCH:<query>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteSetSearchQuery, object: nil,
                                                    userInfo: ["query": query])
                }
                return json(["status": "posted", "query": query])

            case "SEARCH_NEXT":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteSearchNext, object: nil)
                }
                return json(["status": "posted"])

            case "SEARCH_PREVIOUS":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteSearchPrevious, object: nil)
                }
                return json(["status": "posted"])

            case "SEARCH_CLEAR":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteSearchClear, object: nil)
                }
                return json(["status": "posted"])

            // ===== Audio export (headless) ==================================
            case "EXPORT_AUDIO":
                guard let idStr = arg, let docID = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: EXPORT_AUDIO:<docID>"}"#
                }
                let documents = (try? databaseManager.documents()) ?? []
                guard let doc = documents.first(where: { $0.id == docID }) else {
                    return #"{"error":"Document not found"}"#
                }
                let job = await MainActor.run {
                    RemoteAudioExportRegistry.shared.create(
                        documentID: docID, documentTitle: doc.title
                    )
                }
                // Kick off the render in a detached task — return the
                // job id immediately so the caller can poll status.
                let plainText = doc.plainText
                let title = doc.title
                let jobID = job.id
                Task.detached { @MainActor in
                    await runHeadlessAudioExport(
                        jobID: jobID, plainText: plainText, title: title
                    )
                }
                return json(["status": "started", "jobID": jobID, "documentID": idStr])

            case "AUDIO_EXPORT_STATUS":
                guard let jobID = arg, !jobID.isEmpty else {
                    return #"{"error":"Usage: AUDIO_EXPORT_STATUS:<jobID>"}"#
                }
                let snap = await MainActor.run { RemoteAudioExportRegistry.shared.get(jobID)?.snapshot() }
                if let snap { return json(snap) }
                return #"{"error":"Job not found"}"#

            case "AUDIO_EXPORT_FETCH":
                guard let jobID = arg, !jobID.isEmpty else {
                    return #"{"error":"Usage: AUDIO_EXPORT_FETCH:<jobID>"}"#
                }
                let job = await MainActor.run { RemoteAudioExportRegistry.shared.get(jobID) }
                guard let job else { return #"{"error":"Job not found"}"# }
                guard job.status == .finished, let url = job.resultURL else {
                    return json(["jobID": jobID, "status": job.status.rawValue,
                                 "error": "Not finished"])
                }
                guard let data = try? Data(contentsOf: url) else {
                    return #"{"error":"Couldn't read result file"}"#
                }
                return json([
                    "jobID": jobID,
                    "filename": url.lastPathComponent,
                    "bytes": data.count,
                    "base64": data.base64EncodedString()
                ])

            // ===== Discovery =================================================
            case "LIST_REMOTE_TARGETS":
                let ids = await MainActor.run { RemoteTargetRegistry.shared.registeredIDs() }
                return json(["count": ids.count, "ids": ids])

            case "LIST_SAVED_ANNOTATIONS":
                // Surfaces the unified Saved Annotations list as JSON
                // so the test driver can pick valid entryIDs to tap
                // without parsing the SwiftUI tree.
                guard let idStr = arg, let docID = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: LIST_SAVED_ANNOTATIONS:<docID>"}"#
                }
                let anchors = (try? databaseManager.askPoseyAnchorRows(for: docID)) ?? []
                let notes = (try? databaseManager.notes(for: docID)) ?? []
                var entries: [[String: Any]] = []
                for row in anchors {
                    entries.append([
                        "kind": "conversation",
                        "id": "conversation:\(row.id)",
                        "storageID": row.id,
                        "offset": row.anchorOffset ?? 0,
                        "anchorText": row.content,
                        "invocation": row.invocation,
                        "timestamp": row.timestamp.timeIntervalSince1970
                    ])
                }
                for n in notes {
                    entries.append([
                        "kind": n.kind == .bookmark ? "bookmark" : "note",
                        "id": "note:\(n.id.uuidString)",
                        "noteID": n.id.uuidString,
                        "offset": n.startOffset,
                        "body": n.body ?? "",
                        "timestamp": n.createdAt.timeIntervalSince1970
                    ])
                }
                entries.sort { ($0["timestamp"] as? Double ?? 0) < ($1["timestamp"] as? Double ?? 0) }
                return json(["documentID": idStr, "count": entries.count, "entries": entries])

            // ===== End remote-control verbs ====================================

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
        var payload: [String: Any] = [
            "apiEnabled": true,
            "documentCount": docs.count
        ]
        #if DEBUG
        payload["connectionInfo"] = localAPIServer.connectionInfo
        #endif
        return json(payload)
    }

    // MARK: — Ask Posey backend handler (M6 test infrastructure)
    //
    // POST /ask body shape:
    //   { "documentID": "<uuid>", "question": "<text>",
    //     "anchorOffset": <int|null>, "anchorText": "<text|null>",
    //     "scope": "passage"|"document"  // default passage if anchor present, else document
    //   }
    //
    // Runs the FULL pipeline: intent classification → prompt builder
    // (anchor + surrounding + STM verbatim + summary + RAG chunks +
    // user question) → fresh LanguageModelSession → AFM stream →
    // metadata. Persists user + assistant turns to
    // ask_posey_conversations exactly the same way the UI's send()
    // does, so the sheet sees the new conversation when next opened.

    func apiAsk(bodyData: Data) async -> String {
        guard let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
            return #"{"error":"Malformed JSON body"}"#
        }
        guard let idStr = body["documentID"] as? String,
              let docID = UUID(uuidString: idStr) else {
            return #"{"error":"Missing or invalid documentID"}"#
        }
        guard let question = body["question"] as? String,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return #"{"error":"Missing or empty question"}"#
        }

        // Look up the document. Must exist for the conversation FK
        // to satisfy when persistence runs.
        let documents: [Document]
        do {
            documents = try databaseManager.documents()
        } catch {
            return #"{"error":"Document lookup failed: \#(error)"}"#
        }
        guard let document = documents.first(where: { $0.id == docID }) else {
            return #"{"error":"Document not found"}"#
        }

        // Build anchor based on scope. Default: passage scope when
        // anchor info is supplied; document scope when not.
        let anchor: AskPoseyAnchor?
        let scopeStr = (body["scope"] as? String)?.lowercased()
        let anchorText = body["anchorText"] as? String
        let anchorOffset = body["anchorOffset"] as? Int
        switch scopeStr {
        case "document":
            anchor = nil
        case "passage", nil, "":
            if let anchorText, let anchorOffset {
                anchor = AskPoseyAnchor(text: anchorText, plainTextOffset: anchorOffset)
            } else {
                // No anchor info supplied — degrade to document scope
                // so the pipeline runs without an anchor. The view
                // model copes; the prompt builder skips ANCHOR.
                anchor = nil
            }
        default:
            return #"{"error":"Unknown scope; expected 'passage' or 'document'"}"#
        }

        // Compose live deps if available on this OS. Without them
        // the view model's send() falls back to the echo stub —
        // useful for tests that don't have AFM.
        var classifier: AskPoseyClassifying?
        var streamer: AskPoseyStreaming?
        var summarizer: AskPoseySummarizing?
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let service = AskPoseyService()
            classifier = service
            streamer = service
            summarizer = service
        }
        #endif

        // The local-API /ask path is NOT a fresh user invocation —
        // it appends Q&A to whatever conversation is in progress for
        // this document. To prevent every /ask call from spawning a
        // duplicate anchor marker (which would pollute Saved
        // Annotations with one row per API call), we look up the most
        // recent anchor row and pass its storage id as
        // `initialScrollAnchorStorageID` — the view model treats that
        // signal as "navigation to existing" and skips the
        // append-on-init step. If no anchor row exists yet (truly
        // fresh API-driven session), we leave the field nil so a
        // single anchor still gets created.
        let mostRecentAnchorID: String? = (try? databaseManager.askPoseyAnchorRows(for: docID))?
            .first?.id

        // Task 4 #9 — opt-in pairwise STM mode. Body field
        // `summarizationMode: "pairwise"` flips the flag for this
        // call. Default ("verbatim" or absent) keeps the existing
        // user-questions-only narrative STM rendering.
        let summarizationModeStr = (body["summarizationMode"] as? String)?.lowercased()
        let useSummarizedSTM = (summarizationModeStr == "pairwise")

        let viewModel = AskPoseyChatViewModel(
            documentID: docID,
            documentPlainText: document.plainText,
            documentTitle: document.title,
            anchor: anchor,
            initialScrollAnchorStorageID: mostRecentAnchorID,
            classifier: classifier,
            streamer: streamer,
            summarizer: summarizer,
            databaseManager: databaseManager,
            useSummarizedSTM: useSummarizedSTM
        )
        await viewModel.awaitHistoryLoaded()

        viewModel.inputText = question
        if classifier != nil, streamer != nil {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                await viewModel.send()
            } else {
                await viewModel.sendEchoStub()
            }
            #else
            await viewModel.sendEchoStub()
            #endif
        } else {
            await viewModel.sendEchoStub()
        }

        // Pull metadata for the JSON response.
        let assistantMessage = viewModel.messages.last(where: { $0.role == .assistant })
        let response = assistantMessage?.content ?? ""

        var payload: [String: Any] = [
            "documentID": docID.uuidString,
            "question": question,
            "response": response,
            "summarizationMode": useSummarizedSTM ? "pairwise" : "verbatim"
        ]
        if let stats = viewModel.lastPairwiseStats {
            payload["pairwiseStats"] = [
                "pairsTotal": stats.pairsTotal,
                "pairsCached": stats.pairsCached,
                "pairsSummarized": stats.pairsSummarized,
                "pairsRewritten": stats.pairsRewritten,
                "sentencesProduced": stats.sentencesProduced,
                "sentencesFlagged": stats.sentencesFlagged,
                "sentencesDropped": stats.sentencesDropped
            ]
        }
        if let intent = viewModel.lastIntent {
            payload["intent"] = intent.rawValue
        }
        if let metadata = viewModel.lastMetadata {
            payload["promptTokens"] = metadata.promptTokenTotal
            payload["inferenceDuration"] = metadata.inferenceDuration
            // Mark's Three Hats QA pass needs the verbatim prompt
            // body to debug answer-quality failures. Returned as
            // `fullPrompt` so test runners can inspect what the
            // model actually saw.
            payload["fullPrompt"] = metadata.fullPromptForLogging
            payload["breakdown"] = [
                "system": metadata.breakdown.system,
                "anchor": metadata.breakdown.anchor,
                "surrounding": metadata.breakdown.surrounding,
                "conversationSummary": metadata.breakdown.conversationSummary,
                "stm": metadata.breakdown.stm,
                "ragChunks": metadata.breakdown.ragChunks,
                "userQuestion": metadata.breakdown.userQuestion,
                "totalIncludingScaffolding": metadata.breakdown.totalIncludingScaffolding
            ]
            payload["droppedSections"] = metadata.droppedSections.map { drop in
                [
                    "section": drop.section.rawValue,
                    "identifier": drop.identifier,
                    "reason": drop.reason
                ]
            }
            payload["chunksInjected"] = metadata.chunksInjected.map { chunk in
                [
                    "chunkID": chunk.chunkID,
                    "startOffset": chunk.startOffset,
                    "relevance": chunk.relevance
                ]
            }
        } else if viewModel.lastError != nil {
            payload["note"] = "No metadata — send failed; see error field"
        } else {
            payload["note"] = "No metadata — likely echo-stub path (AFM unavailable)"
        }

        if let error = viewModel.lastError {
            payload["error"] = error.errorDescription ?? "\(error)"
            // When the send failed, the most recent assistant message
            // in `messages` is from the PREVIOUS successful turn, not
            // this one. Surface that explicitly so the test runner
            // doesn't think the error message is the response.
            payload["response"] = ""
        }

        return json(payload)
    }

    // MARK: — Open Ask Posey UI driver (simulator MCP integration)
    //
    // POST /open-ask-posey body shape:
    //   { "documentID": "<uuid>", "scope": "passage"|"document" }
    //
    // Posts a NotificationCenter event the LibraryView and ReaderView
    // observe to navigate to the document and open the sheet. The
    // simulator MCP can then screenshot the sheet to verify the user
    // experience.

    func apiOpenAskPosey(bodyData: Data) async -> String {
        guard let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
            return #"{"error":"Malformed JSON body"}"#
        }
        guard let idStr = body["documentID"] as? String,
              let docID = UUID(uuidString: idStr) else {
            return #"{"error":"Missing or invalid documentID"}"#
        }
        let scope = (body["scope"] as? String)?.lowercased() ?? "passage"
        guard scope == "passage" || scope == "document" else {
            return #"{"error":"Unknown scope; expected 'passage' or 'document'"}"#
        }

        // Verify the document exists so the UI doesn't get a phantom
        // request that never resolves.
        let documents: [Document]
        do {
            documents = try databaseManager.documents()
        } catch {
            return #"{"error":"Document lookup failed: \#(error)"}"#
        }
        guard documents.contains(where: { $0.id == docID }) else {
            return #"{"error":"Document not found"}"#
        }

        // Optional Notes-tap-conversation path: when set, the sheet
        // opens scrolled to a specific anchor row in the existing
        // thread instead of appending a new one. Body field is
        // optional so existing callers (default reader-glyph
        // invocation) keep working unchanged.
        let initialAnchorStorageID = body["initialAnchorStorageID"] as? String

        await MainActor.run {
            var info: [AnyHashable: Any] = [
                "documentID": docID,
                "scope": scope
            ]
            if let initialAnchorStorageID {
                info["initialAnchorStorageID"] = initialAnchorStorageID
            }
            NotificationCenter.default.post(
                name: .openAskPoseyForDocument,
                object: nil,
                userInfo: info
            )
        }

        var response: [String: Any] = [
            "documentID": docID.uuidString,
            "scope": scope,
            "status": "opened",
            "note": "NotificationCenter post dispatched; UI will navigate + open sheet"
        ]
        if let initialAnchorStorageID {
            response["initialAnchorStorageID"] = initialAnchorStorageID
        }
        return json(response)
    }

    // MARK: — Notifications for the simulator MCP UI driver

    // Defined here rather than in a separate file because it's used
    // only by the local API → UI handoff path.
    static var openAskPoseyForDocumentNotification: Notification.Name {
        Notification.Name.openAskPoseyForDocument
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
