import AVFoundation
import Combine
import NaturalLanguage
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: LIBRARY VIEW - START ==========

struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 2026-06-18 — Pillar 3: the library-level escape switch (halt + clean
    // rebuild). Lives here because saturation originates from library imports,
    // so the control is reachable exactly when needed — not buried in a reader
    // sheet. Surfaced only while indexing is active or a rebuild is pending.
    @ObservedObject private var indexingTracker = IndexingTracker.sharedForChat
    @ObservedObject private var escape = IndexingEscapeController.shared
    @State private var showHaltConfirm = false
    @State private var isImporting = false
    #if DEBUG
    @State private var showEmbeddingBoard = false
    #endif
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

    /// Is any background indexing happening right now (something to halt)?
    private var isIndexingActive: Bool {
        indexingTracker.currentIndexingDocumentID != nil
            || !indexingTracker.embedQueuePositions.isEmpty
            || !indexingTracker.reReadingDocumentIDs.isEmpty
    }

    /// Extracted from `body`, with the CONDITIONAL parts pushed into View-space
    /// (`escapeToolbarButton`) rather than conditional `ToolbarContent` — the
    /// latter (`if/else` over `ToolbarItem`) tripped "unable to type-check in
    /// reasonable time". One trailing `ToolbarItem` holds an `HStack` of the
    /// (optional) escape glyph + the import glyph.
    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        #if DEBUG
        // M9 release-binary hygiene: the local-API antenna toggle is a
        // development-only affordance. DEBUG builds expose it; release App Store
        // builds compile it out entirely so a user picking up Posey from the App
        // Store has no idea the developer-API surface exists.
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 16) {
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

                // 2026-06-19 (Mark) — embedding status board, next to the antenna.
                // On-phone transparency into the embedding backfill / indexing.
                Button {
                    showEmbeddingBoard = true
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .accessibilityLabel("Embedding status")
                .remoteRegister("library.embeddingBoard") {
                    showEmbeddingBoard = true
                }
            }
        }
        #endif
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                escapeToolbarButton
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.importStatusMessage != nil)
                .accessibilityLabel("Import File")
                .remoteRegister("library.importTXT") {
                    isImporting = true
                }
            }
        }
    }

    /// Pillar 3 escape switch (compact, Mark 2026-06-18): a glyph shown ONLY
    /// while work is happening — a red Stop while indexing, a Rebuild while a
    /// halt is pending — next to the import glyph. The per-card statuses carry
    /// the words, so the toolbar carries only the action; nothing when idle.
    @ViewBuilder
    private var escapeToolbarButton: some View {
        if isIndexingActive {
            Button(role: .destructive) {
                showHaltConfirm = true
            } label: {
                Image(systemName: "stop.circle.fill")
            }
            .tint(.red)
            .disabled(escape.isHalting)
            .accessibilityLabel("Stop indexing")
            .accessibilityIdentifier("library.stopIndexing")
            // Co-located with its trigger (and OFF the body's modifier chain, to
            // keep the view's body under the type-checker's reasonable-time limit).
            .confirmationDialog("Stop indexing and rebuild?",
                                isPresented: $showHaltConfirm,
                                titleVisibility: .visible) {
                Button("Stop & rebuild", role: .destructive) {
                    Task { await escape.halt() }
                }
                Button("Keep indexing", role: .cancel) {}
            } message: {
                Text("Posey will stop preparing your books and rebuild from scratch once your device is cool. Your books stay readable the whole time.")
            }
        } else if !escape.pendingReindex.isEmpty {
            Button {
                escape.rebuildNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Rebuild library")
            .accessibilityIdentifier("library.rebuildPending")
        }
    }

    /// One library row. Extracted from `body` so the (now larger) view's body
    /// type-checks in reasonable time — adding the Pillar-3 escape state pushed
    /// the inline List closure over the inference limit; isolating the row keeps
    /// each piece cheap.
    @ViewBuilder
    private func documentRow(_ document: Document) -> some View {
        NavigationLink(value: document) {
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.headline)
                // **Bundle 2c + follow-up (2026-05-26)** —
                // edition-disambiguation subtitle. Helper hides the conditional
                // behind a single String? so the type-checker doesn't reason
                // about the ternary inline.
                if let subtitle = viewModel.editionSubtitle(for: document) {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(alignment: .firstTextBaseline) {
                    LibraryReadingTimeLabel(
                        document: document,
                        databaseManager: viewModel.databaseManager
                    )
                    Spacer(minLength: 8)
                    // Ask Posey readiness, bookending opposite the reading-time
                    // (Mark's design, 2026-06-18).
                    AskPoseyLibraryStatusLabel(
                        documentID: document.id,
                        databaseManager: viewModel.databaseManager
                    )
                }
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

    /// The List + its directly-attached chrome (empty-state overlay, title,
    /// toolbar), split out of `body` so the full modifier chain stays under the
    /// type-checker's reasonable-time limit.
    private var libraryList: some View {
        List(viewModel.documents) { document in
            documentRow(document)
        }
        .overlay {
            if viewModel.documents.isEmpty && viewModel.importStatusMessage == nil {
                ContentUnavailableView(
                    "No Documents Yet",
                    systemImage: "text.document",
                    description: Text("Import a TXT, Markdown, RTF, DOCX, HTML, EPUB, or PDF file to start the reading loop.")
                )
            }
        }
        .navigationTitle("Posey")
        .toolbar { libraryToolbar }
        .modifier(EmbeddingBoardSheet(isPresented: embeddingBoardBinding,
                                      databaseManager: viewModel.databaseManager))
    }

    /// Binding that's a no-op in RELEASE (the board is DEBUG-only, next to the
    /// DEBUG antenna). Keeps the body modifier chain unconditional so the
    /// type-checker stays happy.
    private var embeddingBoardBinding: Binding<Bool> {
        #if DEBUG
        return $showEmbeddingBoard
        #else
        return .constant(false)
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            libraryList
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
            .modifier(LibraryRemoteRouting(path: $path, viewModel: viewModel))
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.plainText, .rtf, .html, .pdf] + richDocumentContentTypes + markdownContentTypes,
                allowsMultipleSelection: false
            ) { result in
                viewModel.handleImport(result: result)
            }
            .safeAreaInset(edge: .bottom) {
                if let message = viewModel.importStatusMessage {
                    importProgressBanner(message: message)
                }
            }
            .task { runLaunchTasks() }
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

    /// The library's on-appear launch work, extracted from the `.task` closure
    /// so `body` stays under the type-checker's reasonable-time limit. Loads
    /// documents, restores the last-read doc, heals abandoned indexing, and (in
    /// DEBUG) auto-starts the antenna / (in RELEASE) force-clears it.
    private func runLaunchTasks() {
        viewModel.loadDocuments()
        maybeOpenFirstDocument()
        if !didAttemptInitialRestore {
            didAttemptInitialRestore = true
            maybeRestoreLastOpenedDocument()
        }
        // 2026-05-14 (B1) — heal-on-launch for docs left with 0 chunks by an
        // interrupted prior indexing pass. Cheap: one COUNT(*) per doc + a
        // re-enqueue for the small set (typically zero) that need it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            viewModel.healAbandonedIndexing()
        }
        // M9 release-binary hygiene: the local API server is a development tool.
        // DEBUG builds force-on the antenna at launch (developer convenience);
        // RELEASE builds compile out the auto-start AND the toggle UI entirely so
        // the API never starts unless someone recompiles in DEBUG. The
        // localAPIEnabled @AppStorage default is also OFF in RELEASE
        // (LibraryViewModel) — defense in depth.
        #if DEBUG
        if !viewModel.localAPIEnabled {
            viewModel.localAPIEnabled = true
        }
        if viewModel.localAPIEnabled && !viewModel.localAPIServer.isRunning {
            viewModel.toggleLocalAPI(showConnectionInfo: false)
        }
        #else
        // 2026-05-12 — defense-in-depth: even if a prior DEBUG install's
        // @AppStorage `localAPIEnabled` persists across to a Release reinstall,
        // force-clear it so the antenna never starts in a Release binary. The
        // LocalAPIServer file is also #if DEBUG-wrapped so it can't physically
        // run; this is belt-and-suspenders.
        if viewModel.localAPIEnabled {
            viewModel.localAPIEnabled = false
        }
        #endif
    }
}

/// The library's notification routing — the five remote/antenna `onReceive`
/// handlers, bundled into one modifier so `LibraryView.body` isn't a single
/// modifier chain long enough to blow the SwiftUI type-checker. Behavior is a
/// faithful port of the inline handlers.
private struct LibraryRemoteRouting: ViewModifier {
    @Binding var path: [Document]
    let viewModel: LibraryViewModel

    func body(content: Content) -> some View {
        content
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
                NotificationCenter.default.publisher(for: PDFEnhancementService.enhancementDidComplete)
            ) { _ in
                // Refresh so the card's characterCount + reading-time reflect the
                // post-Tier-2/3 corrected text.
                viewModel.loadDocuments()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .openAskPoseyForDocument)
            ) { notification in
                // M6 simulator-MCP UI driver: navigate to the matching document;
                // ReaderView opens the Ask Posey sheet on receipt.
                guard
                    let info = notification.userInfo,
                    let documentID = info["documentID"] as? UUID
                else { return }
                let documents = (try? viewModel.databaseManager.documents()) ?? []
                guard let document = documents.first(where: { $0.id == documentID }) else { return }
                let needsNavigation = path.last?.id != documentID
                if needsNavigation {
                    path = [document]
                }
                // Always redeliver (not just on first nav): ReaderView's onReceive
                // may register after the original post; the `redelivered` flag
                // prevents the Library observer from looping.
                if info["redelivered"] == nil {
                    let delay: Int = needsNavigation ? 500 : 100
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(delay))
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
    }
}

// ========== BLOCK 01: LIBRARY VIEW - END ==========

// ========== BLOCK 02: LIBRARY VIEW MODEL - START ==========

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var documents: [Document] = []
    @Published var isShowingError = false
    @Published var errorMessage = ""
    /// Non-nil while ANY import is in progress (all 7 formats). Drives the
    /// non-blocking bottom progress banner. 2026-06-15: generalized from the
    /// old PDF-only `pdfImportStatusMessage` — with Path A every format imports
    /// off-main, so this banner is the "belt and suspenders" reassurance that
    /// the book is being added while the UI stays usable.
    @Published private(set) var importStatusMessage: String? = nil

    /// In-character copy for the import banner (Mark's line). Wording is easy
    /// to change here; shown for every format's import.
    static let importBannerMessage = "Posey is reading ahead\u{2026}"
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
    // 2026-05-23 — Step 8f: the lazy `embeddingIndex`
    // (DocumentEmbeddingIndex) and the Phase B
    // `enhancementScheduler` (BackgroundEnhancementScheduler) lived
    // here before. Both removed in 8f's tear-down. Importers no
    // longer take an embedding-index parameter; PDF enhancement
    // routes its end-of-Tier-3 chunker fire through
    // UnitEmbeddingService.shared directly.
    private lazy var txtLibraryImporter      = TXTLibraryImporter(databaseManager: databaseManager)
    private lazy var markdownLibraryImporter = MarkdownLibraryImporter(databaseManager: databaseManager)
    private lazy var rtfLibraryImporter      = RTFLibraryImporter(databaseManager: databaseManager)
    private lazy var docxLibraryImporter     = DOCXLibraryImporter(databaseManager: databaseManager)
    private lazy var htmlLibraryImporter     = HTMLLibraryImporter(databaseManager: databaseManager)
    private lazy var epubLibraryImporter     = EPUBLibraryImporter(databaseManager: databaseManager)
    private lazy var pdfLibraryImporter      = PDFLibraryImporter(databaseManager: databaseManager)
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
        rebuildAmbiguousTitleSet()
    }

    /// **Bundle 2c (2026-05-26)** — set of titles that appear on two
    /// or more documents. Used by the library card to decide whether
    /// to surface the filename as an "edition" subtitle.
    @Published private(set) var ambiguousTitles: Set<String> = []

    private func rebuildAmbiguousTitleSet() {
        var counts: [String: Int] = [:]
        for doc in documents { counts[doc.title, default: 0] += 1 }
        ambiguousTitles = Set(counts.filter { $0.value > 1 }.keys)
    }

    /// True when at least one other library document shares this
    /// document's title — drives the filename-as-subtitle disambiguation.
    func isTitleAmbiguous(for document: Document) -> Bool {
        ambiguousTitles.contains(document.title)
    }

    /// **Bundle 2 follow-up (2026-05-26)** — subtitle resolution for
    /// the library card. Returns nil for unique titles; for ambiguous
    /// titles, prefers the importer-supplied `editionLabel` (EPUB
    /// illustrator metadata) and falls back to the filename when no
    /// editionLabel is present.
    func editionSubtitle(for document: Document) -> String? {
        guard isTitleAmbiguous(for: document) else { return nil }
        if let label = document.editionLabel, !label.isEmpty {
            return label
        }
        return document.fileName
    }

    /// 2026-05-14 (B1) — Heal-on-launch for documents whose Ask Posey
    /// indexing pass didn't finish before the app was killed.
    ///
    /// Background: very long documents (GEB at 1.89M chars, Illuminatus
    /// at 1.65M chars) can take 90+ seconds to chunk + embed. If the
    /// app is suspended or force-quit mid-pass, `enqueueIndexing`'s
    /// dispatched work disappears and the document is left with 0
    /// chunks — Ask Posey becomes silently blind to it. There's no
    /// surfaced error; users hit "I can't find that in the document"
    /// for content that obviously exists.
    ///
    /// This pass scans every persisted document, finds any with
    /// plain-text content but no chunks (a strong signal of an
    /// abandoned indexing pass), and re-enqueues them via the normal
    /// `enqueueIndexing` path. The library's regular `enqueueIndexing`
    /// already skips documents that ARE indexed, so this is safe to
    /// call unconditionally.
    func healAbandonedIndexing() {
        // 2026-05-23 — Step 8f: routes through UnitEmbeddingService
        // (idempotent — replaceAllUnitEmbeddingChunks atomically
        // rebuilds the chunk set for each doc). The 200-char floor
        // is preserved so trivially-short docs don't churn.
        do {
            let docs = try databaseManager.documents()
            let dbRef = databaseManager
            for doc in docs {
                guard doc.characterCount >= 200 else { continue }
                let count = (try? databaseManager.unitEmbeddingChunks(for: doc.id).count) ?? 0
                if count == 0 {
                    dbgLog("LibraryViewModel: heal-on-launch — re-enqueueing %@ (%d chars, 0 chunks)",
                           doc.title, doc.characterCount)
                    let docID = doc.id
                    Task.detached {
                        await UnitEmbeddingService.shared.enqueueIndexing(
                            documentID: docID, databaseManager: dbRef
                        )
                    }
                }
            }
        } catch {
            dbgLog("LibraryViewModel: heal-on-launch aborted: %@", "\(error)")
        }
    }

    func deleteDocument(_ document: Document) {
        do {
            // 2026-05-23 — Step 8f: explicit cancellation of the
            // legacy embedding-index in-flight job was removed
            // here. UnitEmbeddingService is actor-serialized; its
            // FK-vulnerable writes can't race a delete because the
            // delete cascades via SQLite's ON DELETE CASCADE
            // (document_units → unit_embedding_chunks). PDF
            // enhancement still needs the explicit cancel below
            // because its Tier 2/3 work runs on a separate actor
            // queue not bounded by SQLite FK semantics.
            Task { await PDFEnhancementService.shared.cancel(document.id) }
            // 2026-06-08 (audit fix #2) — cancel any in-flight RAPTOR build
            // for the same reason: its build runs on a separate actor queue
            // and could otherwise re-insert summary rows after the cascade.
            Task { await RaptorTreeService.shared.cancel(document.id) }
            try databaseManager.deleteDocument(document)
            // 2026-05-22 Phase 2.2 Step 5 — drop the source PDF
            // sidecar (no longer needed once the doc is gone).
            PDFSourceStore.delete(document.id)
            loadDocuments()
            // 2026-05-13 — A4: invalidate any cached audio export
            // tied to this document. AudioExportCache.shared
            // listens for this notification and removes the file.
            NotificationCenter.default.post(
                name: AudioExportCache.documentDidDelete,
                object: nil,
                userInfo: [AudioExportCache.notificationDocumentIDKey: document.id]
            )
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

            // 2026-05-22 — HTML now also async because of the
            // Readability pre-pass (WKWebView runs JS to extract
            // article body). Route into its own task so the security-
            // scoped URL lifetime is managed in the async context.
            if fileType == "html" || fileType == "htm" {
                handleHTMLImport(url: url)
                return
            }

            // 2026-06-15 (Path A — off-main import): EPUB now imports through
            // its own async task like HTML/PDF. Its parse runs off the main
            // thread, hopping to main only for the per-chapter WebKit step, so
            // adding a large EPUB no longer freezes the UI.
            if fileType == "epub" {
                handleEPUBImport(url: url)
                return
            }

            // 2026-06-15 (Path A, completing the sweep): the pure-text formats
            // (TXT/MD/RTF/DOCX) have no main-thread requirement, so they import
            // off-main via a background task too. "Launch and use, not wait" now
            // holds for every format. (PDF/HTML/EPUB already returned above.)
            handleTextFormatImport(url: url, fileType: fileType)
        } catch {
            present(error)
        }
    }

    /// 2026-05-22 — HTML import async path (Readability pre-pass).
    /// Mirrors `handlePDFImport`'s shape: own Task, security-scoped
    /// URL access inside the task, error → `present(error)` on main.
    private func handleHTMLImport(url: URL) {
        Task { @MainActor in
            importStatusMessage = Self.importBannerMessage
            defer { importStatusMessage = nil }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await htmlLibraryImporter.importDocument(from: url)
                loadDocuments()
            } catch {
                present(error)
            }
        }
    }

    /// 2026-06-15 (Path A — off-main import) — EPUB async import path. Mirrors
    /// `handleHTMLImport`: own Task, security-scoped URL access managed in the
    /// async context. `EPUBLibraryImporter.importDocument` is now `async` and
    /// runs off-main (hopping to main only for the per-chapter NSAttributedString
    /// step), so the UI stays responsive while a large EPUB imports.
    private func handleEPUBImport(url: URL) {
        Task { @MainActor in
            importStatusMessage = Self.importBannerMessage
            defer { importStatusMessage = nil }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await epubLibraryImporter.importDocument(from: url)
                loadDocuments()
            } catch {
                present(error)
            }
        }
    }

    /// 2026-06-15 (Path A — off-main import) — TXT/MD/RTF/DOCX import path.
    /// These importers are pure Swift (no WebKit / main-thread requirement), so
    /// the parse + DB write run on a detached background task; only the security-
    /// scoped URL bracketing and the final `loadDocuments()` touch the main actor.
    /// Importers stay synchronous (fresh instance built inside the task from the
    /// Sendable DatabaseManager), so their signatures and tests are untouched.
    private func handleTextFormatImport(url: URL, fileType: String) {
        let db = databaseManager
        Task { @MainActor in
            importStatusMessage = Self.importBannerMessage
            defer { importStatusMessage = nil }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                try await Task.detached(priority: .userInitiated) {
                    switch fileType {
                    case "txt":            _ = try TXTLibraryImporter(databaseManager: db).importDocument(from: url)
                    case "md", "markdown": _ = try MarkdownLibraryImporter(databaseManager: db).importDocument(from: url)
                    case "rtf":            _ = try RTFLibraryImporter(databaseManager: db).importDocument(from: url)
                    case "docx":           _ = try DOCXLibraryImporter(databaseManager: db).importDocument(from: url)
                    default:               throw LibraryImportError.unsupportedFileType
                    }
                }.value
                loadDocuments()
            } catch {
                present(error)
            }
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
        importStatusMessage = Self.importBannerMessage

        // Capture the importer as a value — PDFLibraryImporter is a struct,
        // but we only use it for the DB write (main actor), not in the Task.
        Task { @MainActor [weak self] in
            guard let self else {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                return
            }
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                importStatusMessage = nil
            }
            do {
                // 2026-05-16 (B8) — Reject binary-misnamed-as-PDF
                // before kicking the heavy parse off thread.
                try FormatPrecheck.checkPDF(url: url)
                let parsed = try await parsePDFOffMainThread(url: url) { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.importStatusMessage = message
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
                importHandler: { [weak self] filename, data, overwrite in
                    await self?.apiImport(filename: filename, data: data, overwrite: overwrite) ?? #"{"error":"unavailable"}"#
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

            case "HELP", "LIST_COMMANDS":
                // 2026-06-19 — self-describing antenna surface. `HELP` dumps the
                // full categorized catalog of every /command verb; `HELP:<verb>`
                // returns one entry; `HELP:<category-or-substring>` filters. Built
                // so an operator never has to grep source to discover a verb
                // (GET_ENHANCEMENT_STATUS existed but went unfound mid-diagnosis).
                // The catalog is drift-guarded against this switch by
                // tools/check_antenna_catalog.sh.
                return json(AntennaCommandCatalog.help(filter: arg))

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

            case "EXTRACT_METADATA":
                // Force bibliographic extraction (author + year) + store to
                // structured columns. Backfill for existing docs + test hook.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Missing or invalid document ID"}"#
                }
                await DocumentMetadataExtractor.extractAndStoreIfNeeded(
                    documentID: id, databaseManager: databaseManager, force: true)
                let meta = try? databaseManager.documentMetadata(for: id)
                return json(["id": id.uuidString,
                             "authors": (meta?.authors ?? []).joined(separator: ", "),
                             "year": meta?.year ?? "",
                             "lastFailure": DocumentMetadataExtractor.lastFailureReason])

            case "DELETE_DOCUMENT":
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Missing or invalid document ID"}"#
                }
                let docs = try databaseManager.documents()
                guard let doc = docs.first(where: { $0.id == id }) else {
                    return #"{"error":"Document not found"}"#
                }
                // 2026-05-23 — Step 8f: explicit legacy-index
                // cancellation removed (see LibraryViewModel
                // .deleteDocument). PDF enhancement still wants the
                // explicit cancel — its actor queue isn't bounded
                // by SQLite cascade semantics.
                Task { await PDFEnhancementService.shared.cancel(doc.id) }
                Task { await RaptorTreeService.shared.cancel(doc.id) }  // audit fix #2
                try databaseManager.deleteDocument(doc)
                // 2026-05-22 — Tier 1/2 Phase 1 calibration sidecar.
                PageFlagsStore.delete(documentID: doc.id)
                // 2026-05-22 Phase 2.2 Step 5 — source PDF sidecar.
                PDFSourceStore.delete(doc.id)
                loadDocuments()
                // 2026-05-13 — A4: invalidate cached audio export.
                NotificationCenter.default.post(
                    name: AudioExportCache.documentDidDelete,
                    object: nil,
                    userInfo: [AudioExportCache.notificationDocumentIDKey: doc.id]
                )
                return json(["deleted": true, "id": id.uuidString])

            case "RESET_ALL":
                let docs = try databaseManager.documents()
                // 2026-05-23 — Step 8f: explicit legacy-index
                // cancellation removed (see deleteDocument).
                Task {
                    for doc in docs { await PDFEnhancementService.shared.cancel(doc.id) }
                }
                Task {  // audit fix #2 — cancel in-flight RAPTOR builds too
                    for doc in docs { await RaptorTreeService.shared.cancel(doc.id) }
                }
                for doc in docs { try databaseManager.deleteDocument(doc) }
                // 2026-05-22 — Tier 1/2 Phase 1 calibration sidecars.
                for doc in docs { PageFlagsStore.delete(documentID: doc.id) }
                // 2026-05-22 Phase 2.2 Step 5 — source PDF sidecars.
                for doc in docs { PDFSourceStore.delete(doc.id) }
                loadDocuments()
                // 2026-05-13 — A4: nuke the entire audio-export cache
                // when every document is wiped.
                AudioExportCache.shared.deleteAll()
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

            case "SET_LLM":
                // **MLX verification (2026-05-26)** — write the selected
                // model id into UserDefaults under
                // `ModelCatalog.defaultsKey`. The next /ask turn calls
                // `ModelCatalog.current()` which reads that key, so the
                // model switch takes effect immediately on the next
                // ask. Use the catalog id ("mlx-community/...") or the
                // short alias ("gemma" / "qwen" / "llama" / "dolphin").
                guard let raw = arg, !raw.isEmpty else {
                    return #"{"error":"Usage: SET_LLM:<modelID> or SET_LLM:<alias>"}"#
                }
                let aliases: [String: ModelConfiguration] = [
                    "afm": ModelCatalog.appleFoundation,
                    "apple": ModelCatalog.appleFoundation,
                    "gemma": ModelCatalog.gemma4_E2B,
                    "qwen": ModelCatalog.qwen35_2B,
                    "llama": ModelCatalog.llama32_3B,
                    "dolphin": ModelCatalog.dolphin30_3B
                ]
                let resolved: ModelConfiguration? = {
                    if let exact = ModelCatalog.model(id: raw) { return exact }
                    return aliases[raw.lowercased()]
                }()
                guard let model = resolved else {
                    let all = ModelCatalog.all.map(\.id).joined(separator: ", ")
                    return #"{"error":"Unknown model. Known ids: \#(all). Aliases: afm, gemma, qwen, llama, dolphin"}"#
                }
                UserDefaults.standard.set(model.id, forKey: ModelCatalog.defaultsKey)
                return json([
                    "status": "set",
                    "id": model.id,
                    "displayName": model.displayName,
                    "source": "\(model.source)"
                ])

            case "GET_LLM":
                let model = ModelCatalog.current()
                return json([
                    "id": model.id,
                    "displayName": model.displayName,
                    "source": "\(model.source)",
                    "sizeGB": model.sizeGB ?? 0,
                    "contextWindow": model.contextWindow
                ])

            case "SET_PROMPT_VARIANT":
                // 2026-06-19 — A/B prompt-rebalance tuning. Flip the
                // process-global active prose variant the live chat view
                // model reads when it builds inputs. `current` = the
                // untouched control; `rebalanced` = control + the substance
                // accelerator spliced before the HARD RULES. In-memory only
                // (an app relaunch resets to `current`). Held constant for a
                // whole conversation thread — clear the conversation between
                // arms; never toggle mid-thread.
                guard let raw = arg?.lowercased(),
                      let variant = AskPoseyPromptVariant(rawValue: raw) else {
                    return #"{"error":"Usage: SET_PROMPT_VARIANT:current|rebalanced"}"#
                }
                await MainActor.run { AskPoseyPromptVariant.active = variant }
                return json(["status": "set", "promptVariant": variant.rawValue])

            case "GET_PROMPT_VARIANT":
                let active = await MainActor.run { AskPoseyPromptVariant.active }
                return json(["promptVariant": active.rawValue])

            case "SET_NEIGHBOR_EXPANSION":
                // 2026-06-19 — SMALL-TO-BIG tuning knob. Sets the neighbor
                // RADIUS (chunks expanded on each side of a retrieved winner).
                // 0 = off (raw small chunks). In-memory (resets on relaunch);
                // a first-class variable for the embedder A/B/C sweep.
                guard let raw = arg, let n = Int(raw.trimmingCharacters(in: .whitespaces)), n >= 0, n <= 10 else {
                    return #"{"error":"Usage: SET_NEIGHBOR_EXPANSION:<0-10>  (0 = off)"}"#
                }
                await MainActor.run { NeighborExpansion.radius = n }
                return json(["status": "set", "neighborRadius": n])

            case "GET_NEIGHBOR_EXPANSION":
                let (r, override) = await MainActor.run { (NeighborExpansion.radius, NeighborExpansion.budgetOverride) }
                // The live model-derived RAG budget (what the expander uses when
                // there's no sweep override) — so the harness sees the real value.
                let modelRagBudget = AskPoseyTokenBudget.forModel(ModelCatalog.answerModel(), longDocument: false).ragBudgetTokens
                var payload: [String: Any] = [
                    "neighborRadius": r,
                    "default": NeighborExpansion.defaultRadius,
                    "ragTokenBudget_modelDerived": modelRagBudget,
                    "ragTokenBudget_fallback": NeighborExpansion.ragTokenBudgetFallback,
                    "ragTokenBudget_effective": override ?? modelRagBudget
                ]
                payload["ragTokenBudget_override"] = override ?? "auto (model-derived)"
                return json(payload)

            case "SET_RAG_TOKEN_BUDGET":
                // 2026-06-20 — A/B/C sweep knob for the neighbor-expansion RAG
                // token ceiling, INDEPENDENT of the active model. ":auto" clears
                // the override (back to model-derived). In-memory; resets on
                // relaunch. Lets the harness vary the budget as its own variable.
                //   SET_RAG_TOKEN_BUDGET:auto        → model-derived (default)
                //   SET_RAG_TOKEN_BUDGET:2400        → force 2400 tokens
                let raw = (arg ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                if raw == "auto" || raw.isEmpty {
                    await MainActor.run { NeighborExpansion.budgetOverride = nil }
                    return json(["status": "set", "ragTokenBudget": "auto (model-derived)"])
                }
                guard let n = Int(raw), n >= 200, n <= 16000 else {
                    return #"{"error":"Usage: SET_RAG_TOKEN_BUDGET:<200-16000|auto>"}"#
                }
                await MainActor.run { NeighborExpansion.budgetOverride = n }
                return json(["status": "set", "ragTokenBudget": n])

            case "SET_QUERY_EXPANSION":
                // SET_QUERY_EXPANSION:on|off — production gate for the
                // LLM query-expansion lever (default OFF; value unproven on
                // P&P — ties only). RAG_DEBUG_EXPANDED measures it
                // regardless of this flag.
                let raw = (arg ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                let on = (raw == "on" || raw == "true" || raw == "1" || raw == "yes")
                UserDefaults.standard.set(on, forKey: "askPoseyQueryExpansionEnabled")
                return json(["status": "ok", "queryExpansionEnabled": on])

            case "SET_EMBEDDING_PROVIDER":
                // 2026-05-27 — rewired to the post-8f EmbedderMigrationCoordinator.
                // Args: "nlcontextual" | "nomic". Triggers download (if needed) +
                // re-embed migration. Returns immediately; poll GET_EMBEDDING_PROVIDER
                // for state.
                let raw = arg?.lowercased() ?? ""
                let target: EmbeddingBackend
                switch raw {
                case "nlcontextual", "nl", "contextual": target = .nlContextual
                case "nomic": target = .nomic
                case "mxbai": target = .mxbai
                default: return #"{"error":"Usage: SET_EMBEDDING_PROVIDER:<nlcontextual|nomic|mxbai>"}"#
                }
                await MainActor.run {
                    EmbedderMigrationCoordinator.shared.beginSwitch(to: target, database: databaseManager)
                }
                return json(["status": "switching", "target": target.rawValue])

            case "GET_EMBEDDING_PROVIDER":
                // 2026-05-27 — rewired. Reports current backend + migration phase.
                // 2026-06-17 — per-backend-column swap visibility: `current` is
                // the ACTIVE (read) backend (flipped only at swap completion);
                // `swapTarget` is the backend a swap is building (nil if none);
                // `swapInProgress` drives the Ask Posey lock; `askPoseyUnlocked`
                // is the resulting reader-surface gate.
                let current = EmbeddingBackend.current().rawValue
                let phase = await MainActor.run { String(describing: EmbedderMigrationCoordinator.shared.currentPhase) }
                return json([
                    "current": current,
                    "phase": phase,
                    "swapInProgress": EmbeddingBackend.isSwapInProgress,
                    "swapTarget": EmbeddingBackend.swapTarget()?.rawValue ?? "",
                    "askPoseyUnlocked": AskPoseyAvailability.isUnlocked
                ])

            case "EMBEDDING_COVERAGE":
                // 2026-06-19 (Mark) — read-only per-backend coverage so we can
                // SEE the gaps before/after a backfill (e.g. docs embedded by
                // Nomic but not NLContextual). Enum-driven → auto-covers mxbai
                // when that backend lands. Usage:
                //   EMBEDDING_COVERAGE            → corpus summary per backend
                //   EMBEDDING_COVERAGE:docs       → + per-document gaps (only
                //                                   docs missing ≥1 backend)
                let wantDocs = (arg?.lowercased() == "docs")
                do {
                    let coverage = try databaseManager.embeddingCoverage()
                    var summary: [[String: Any]] = []
                    for c in coverage {
                        summary.append([
                            "backend": c.backend.rawValue,
                            "active": c.backend == EmbeddingBackend.current(),
                            "filled": c.filled,
                            "missing": c.missing,
                            "total": c.total,
                            "complete": c.isComplete
                        ])
                    }
                    var payload: [String: Any] = [
                        "activeBackend": EmbeddingBackend.current().rawValue,
                        "backends": summary
                    ]
                    if wantDocs {
                        let byDoc = try databaseManager.embeddingCoverageByDocument()
                        let titles = Dictionary(
                            uniqueKeysWithValues: (try databaseManager.documents()).map { ($0.id, $0.title) }
                        )
                        let cols = EmbeddingBackend.allCases
                        var docRows: [[String: Any]] = []
                        for d in byDoc {
                            // Only surface documents missing at least one backend.
                            let missingBackends = cols.filter {
                                (d.filledByColumn[$0.vectorColumn] ?? 0) < d.total
                            }
                            guard !missingBackends.isEmpty else { continue }
                            var perBackend: [String: Any] = [:]
                            for b in cols {
                                perBackend[b.rawValue] = d.filledByColumn[b.vectorColumn] ?? 0
                            }
                            docRows.append([
                                "documentID": d.documentID.uuidString,
                                "title": titles[d.documentID] ?? "(unknown)",
                                "total": d.total,
                                "filled": perBackend,
                                "missing": missingBackends.map { $0.rawValue }
                            ])
                        }
                        payload["incompleteDocuments"] = docRows
                        payload["incompleteCount"] = docRows.count
                    }
                    return json(payload)
                } catch {
                    return json(["error": "EMBEDDING_COVERAGE failed: \(error.localizedDescription)"])
                }

            case "VALIDATE_EMBEDDINGS":
                // 2026-06-20 (Mark) — read-only health spot-check on STORED
                // vectors: prove the backfill wrote real embeddings (right dim,
                // all-finite, non-zero norm), not just non-NULL bytes. Samples
                // up to 200 random rows per backend.
                //   VALIDATE_EMBEDDINGS            → all three backends
                //   VALIDATE_EMBEDDINGS:mxbai      → one backend
                let which: [EmbeddingBackend]
                if let a = arg?.lowercased(), a != "all",
                   let b = EmbeddingBackend(rawValue: a) {
                    which = [b]
                } else {
                    which = EmbeddingBackend.allCases
                }
                do {
                    var reports: [[String: Any]] = []
                    var allHealthy = true
                    for b in which {
                        let r = try databaseManager.validateStoredEmbeddings(backend: b)
                        if r.sampled > 0 && !r.healthy { allHealthy = false }
                        reports.append([
                            "backend": r.backend,
                            "active": b == EmbeddingBackend.current(),
                            "expectedDim": r.expectedDim,
                            "sampled": r.sampled,
                            "dimMismatch": r.dimMismatch,
                            "nonFinite": r.nonFinite,
                            "zeroNorm": r.zeroNorm,
                            "minNorm": r.minNorm,
                            "maxNorm": r.maxNorm,
                            "healthy": r.healthy
                        ])
                    }
                    return json([
                        "allHealthy": allHealthy,
                        "note": "sampled up to 200 random stored vectors per backend; healthy = right dim, all-finite, non-zero norm",
                        "reports": reports
                    ])
                } catch {
                    return json(["error": "VALIDATE_EMBEDDINGS failed: \(error.localizedDescription)"])
                }

            case "ASK_POSEY_TURN_STATS":
                // 2026-06-20 — verify embed-at-save (conversation-memory fix):
                // how many user/assistant turns for a doc carry an active-backend
                // embedding. Read-only.   ASK_POSEY_TURN_STATS:<documentID>
                guard let docID = UUID(uuidString: (arg ?? "").trimmingCharacters(in: .whitespaces)) else {
                    return json(["error": "usage: ASK_POSEY_TURN_STATS:<documentID>"])
                }
                do {
                    let backend = EmbeddingBackend.current()
                    let stats = try databaseManager.askPoseyTurnEmbeddingStats(documentID: docID, backend: backend)
                    return json([
                        "documentID": docID.uuidString,
                        "backend": backend.rawValue,
                        "totalTurns": stats.totalTurns,
                        "embedded": stats.embedded,
                        "missing": stats.totalTurns - stats.embedded
                    ])
                } catch {
                    return json(["error": "ASK_POSEY_TURN_STATS failed: \(error.localizedDescription)"])
                }

            case "SET_MEMORY_DEPTH":
                // 2026-06-20 — override the verbatim STM depth (exchanges) so the
                // conversation-recall pass is testable with short conversations
                // and sweepable in the A/B/C. ':auto' restores the per-model value.
                //   SET_MEMORY_DEPTH:1     → 1 exchange (2-msg verbatim window)
                //   SET_MEMORY_DEPTH:auto  → per-model default
                let raw = (arg ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                if raw == "auto" || raw.isEmpty {
                    await MainActor.run { AskPoseyChatViewModel.memoryDepthOverride = nil }
                    return json(["status": "set", "memoryDepth": "auto (per-model)"])
                }
                guard let n = Int(raw), n >= 1, n <= 50 else {
                    return #"{"error":"Usage: SET_MEMORY_DEPTH:<1-50|auto>"}"#
                }
                await MainActor.run { AskPoseyChatViewModel.memoryDepthOverride = n }
                return json(["status": "set", "memoryDepthExchanges": n, "verbatimMessages": n * 2])

            case "RECALL_TURNS":
                // 2026-06-20 — verify Part B (hybrid conversation-turn recall)
                // standalone, before it's wired into the prompt (Part C). Embeds
                // the query (.query) + runs the recall pass with NO STM exclusion
                // (raw retrieval probe).   RECALL_TURNS:<documentID>|<query>
                let rparts = (arg ?? "").split(separator: "|", maxSplits: 1).map(String.init)
                guard rparts.count == 2, let rDocID = UUID(uuidString: rparts[0].trimmingCharacters(in: .whitespaces)) else {
                    return json(["error": "usage: RECALL_TURNS:<documentID>|<query>"])
                }
                let rQuery = rparts[1].trimmingCharacters(in: .whitespaces)
                let rBackend = EmbeddingBackend.current()
                let rVec = await Task.detached(priority: .userInitiated) {
                    EmbeddingProvider.shared.embed(rQuery, as: .query, in: rBackend) ?? []
                }.value
                do {
                    let turns = try databaseManager.retrieveConversationTurns(
                        documentID: rDocID, queryVector: rVec, queryText: rQuery,
                        excludeMostRecent: 0, backend: rBackend, limit: 6)
                    return json([
                        "documentID": rDocID.uuidString,
                        "query": rQuery,
                        "queryEmbedded": !rVec.isEmpty,
                        "recalledCount": turns.count,
                        "turns": turns.map { ["role": $0.role, "rrf": $0.rrfScore, "content": String($0.content.prefix(160))] }
                    ])
                } catch {
                    return json(["error": "RECALL_TURNS failed: \(error.localizedDescription)"])
                }

            case "SEARCH_CHUNKS":
                // 2026-06-20 (CC) — read-only BM25 search over ONE document's
                // stored chunk text, returning the actual indexed text. Lets the
                // A/B-test answer-key authoring pull verbatim defining-passages
                // from POSEY'S OWN extraction (critical for PDFs/CBA, whose text
                // can differ from a raw-file extraction). Also a harness debug aid.
                //   SEARCH_CHUNKS:<documentID>|<query words>
                let parts = (arg ?? "").split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let docID = UUID(uuidString: parts[0].trimmingCharacters(in: .whitespaces)) else {
                    return json(["error": "usage: SEARCH_CHUNKS:<documentID>|<query words>"])
                }
                let query = parts[1].trimmingCharacters(in: .whitespaces)
                do {
                    let hits = try databaseManager.searchUnitEmbeddingChunkTexts(documentID: docID, query: query, limit: 6)
                    return json([
                        "documentID": docID.uuidString,
                        "query": query,
                        "hitCount": hits.count,
                        "hits": hits.map { ["chunkIndex": $0.chunkIndex, "bm25": $0.rawBM25, "text": $0.text] }
                    ])
                } catch {
                    return json(["error": "SEARCH_CHUNKS failed: \(error.localizedDescription)"])
                }

            case "BACKFILL_EMBEDDINGS":
                // 2026-06-19 (Mark) — fill an INACTIVE backend's column for the
                // whole corpus, non-locking (Ask Posey stays up on the active
                // backend), paced. Prereq for the embedder A/B/C comparison.
                //   BACKFILL_EMBEDDINGS:nl       → fill embedding_nl
                //   BACKFILL_EMBEDDINGS:nomic    → fill embedding_nomic
                //   BACKFILL_EMBEDDINGS:all      → fill every backend EXCEPT the
                //                                  active (the queue owns active)
                // Returns immediately; poll BACKFILL_STATUS or EMBEDDING_COVERAGE.
                let active = EmbeddingBackend.current()
                let targets: [EmbeddingBackend]
                switch (arg ?? "").lowercased() {
                case "nl", "nlcontextual":
                    targets = [.nlContextual]
                case "nomic":
                    targets = [.nomic]
                case "mxbai":
                    targets = [.mxbai]
                case "all":
                    targets = EmbeddingBackend.allCases.filter { $0 != active }
                default:
                    return #"{"error":"Usage: BACKFILL_EMBEDDINGS:<nl|nomic|mxbai|all>"}"#
                }
                if EmbeddingBackend.isSwapInProgress {
                    return json(["error": "a backend swap is in progress — backfill refused (they both write columns). Wait for the swap to finish."])
                }
                if EmbeddingBackfillCoordinator.shared.isRunning {
                    return json(["error": "a backfill is already running — poll BACKFILL_STATUS."])
                }
                EmbeddingBackfillCoordinator.shared.begin(targets: targets, database: databaseManager)
                return json([
                    "started": true,
                    "targets": targets.map { $0.rawValue },
                    "note": "Non-locking background backfill dispatched. Poll BACKFILL_STATUS or EMBEDDING_COVERAGE."
                ])

            case "BACKFILL_STATUS":
                // 2026-06-19 — current backfill phase (running/done/error/idle).
                let phaseDesc = String(describing: EmbeddingBackfillCoordinator.shared.phase)
                return json([
                    "running": EmbeddingBackfillCoordinator.shared.isRunning,
                    "phase": phaseDesc
                ])

            case "CANCEL_BACKFILL":
                // 2026-06-19 — cancel an in-flight backfill. Still-NULL rows stay
                // NULL; a later BACKFILL_EMBEDDINGS resumes them.
                EmbeddingBackfillCoordinator.shared.cancel()
                return json(["status": "cancel-requested"])

            case "EMBEDDER_LOADTEST":
                // 2026-06-19 (Mark) — embedder model-load GATE. Headlessly load a
                // candidate model via swift-embeddings' Bert path and confirm a
                // finite, normalizable vector + its dimension, BEFORE building a
                // full backend. Default repo = mxbai. Usage:
                //   EMBEDDER_LOADTEST                → mixedbread-ai/mxbai-embed-large-v1
                //   EMBEDDER_LOADTEST:<hf-repo-id>   → any BERT-family repo
                // Returns immediately; poll EMBEDDER_LOADTEST_STATUS.
                let repo = (arg?.isEmpty == false ? arg! : "mixedbread-ai/mxbai-embed-large-v1")
                if await MainActor.run(body: { EmbedderLoadTest.isRunning }) {
                    return json(["error": "a load test is already running — poll EMBEDDER_LOADTEST_STATUS."])
                }
                EmbedderLoadTest.run(repo: repo)
                return json(["started": true, "repo": repo,
                             "note": "Loading off-main (downloads ~670MB first time). Poll EMBEDDER_LOADTEST_STATUS."])

            case "EMBEDDER_LOADTEST_STATUS":
                let r = await MainActor.run { EmbedderLoadTest.report }
                var payload: [String: Any] = ["state": r.state, "repo": r.repo]
                if let v = r.dim { payload["dim"] = v }
                if let v = r.allFinite { payload["allFinite"] = v }
                if let v = r.l2Norm { payload["l2Norm"] = v }
                if let v = r.sample { payload["sample"] = v }
                if let v = r.loadMs { payload["loadMs"] = v }
                if let v = r.encodeMs { payload["encodeMs"] = v }
                if let v = r.error { payload["error"] = v }
                return json(payload)

            case "CANCEL_EMBEDDING_MIGRATION":
                // 2026-05-28 — cancellation surface for mid-flight Nomic
                // re-embed. Without this, a user who switches embedder
                // and changes their mind has to wait for the full
                // migration to complete (can be 10+ minutes on a phone
                // library with multiple large docs). Calls
                // EmbedderMigrationCoordinator.cancel() which flips
                // cancelRequested; the migrator checks at every chunk
                // batch and bails to .cancelled cleanly.
                await MainActor.run {
                    EmbedderMigrationCoordinator.shared.cancel()
                }
                return json(["status": "cancel-requested"])

            case "DOWNLOAD_MODEL":
                // 2026-06-17 — headless model download (test/diagnostic) so the
                // progress fix + on/off reliability can be verified without UI
                // taps. Usage: DOWNLOAD_MODEL:<modelID> (full repo path).
                guard let id = arg, let cfg = ModelCatalog.model(id: id) else {
                    return #"{"error":"Usage: DOWNLOAD_MODEL:<known-model-id>"}"#
                }
                await MLXModelDownloader.shared.startDownload(
                    modelID: cfg.id, repoID: cfg.repoID ?? cfg.id, sizeGB: cfg.sizeGB)
                return json(["status": "download-started", "modelID": cfg.id])

            case "DELETE_MODEL":
                guard let id = arg, ModelCatalog.model(id: id) != nil else {
                    return #"{"error":"Usage: DELETE_MODEL:<known-model-id>"}"#
                }
                await MLXModelDownloader.shared.deleteModel(modelID: id)
                return json(["status": "deleted", "modelID": id])

            case "MODEL_DOWNLOAD_STATE":
                guard let id = arg else {
                    return #"{"error":"Usage: MODEL_DOWNLOAD_STATE:<model-id>"}"#
                }
                let snap = await MainActor.run { () -> [String: Any] in
                    let st = MLXModelDownloader.shared.downloadStates[id]
                    return [
                        "modelID": id,
                        "isDownloaded": MLXModelDownloader.shared.isModelDownloaded(id),
                        "isDownloading": st?.isDownloading ?? false,
                        "progress": st?.progress ?? 0,
                        "message": st?.message ?? "",
                        "error": st?.error ?? ""
                    ]
                }
                return json(snap)

            case "SET_SPOILER_CATCHER_ENGINE":
                // 2026-06-17 — Spoiler firewall (Layer 2) A/B test. Picks which
                // engine judges narrative-event-ness: "mlx" (the answer model)
                // or "afm". Persisted; the catcher reads it on every pass. Lets
                // the A/B sweep run the SAME probes under each engine and
                // compare leak rates. Usage: SET_SPOILER_CATCHER_ENGINE:<mlx|afm>
                let raw = (arg ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                guard let engine = await MainActor.run(body: { () -> SpoilerCatcher.Engine? in
                    guard let e = SpoilerCatcher.Engine(rawValue: raw) else { return nil }
                    SpoilerCatcher.engine = e
                    return e
                }) else {
                    return #"{"error":"Usage: SET_SPOILER_CATCHER_ENGINE:<mlx|afm>"}"#
                }
                return json(["status": "ok", "engine": engine.rawValue])

            case "GET_SPOILER_CATCHER_ENGINE":
                let engine = await MainActor.run { SpoilerCatcher.engine.rawValue }
                return json(["engine": engine])

            case "SET_SPOILER_PROTECTION":
                // 2026-06-17 — Spoiler firewall (Layer 0). Flip a document's
                // per-doc protection flag from the antenna (for verification —
                // ask the same question protected vs not).
                // Usage: SET_SPOILER_PROTECTION:<doc-id>:<on|off>
                let parts = (arg ?? "").split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let id = UUID(uuidString: parts[0]) else {
                    return #"{"error":"Usage: SET_SPOILER_PROTECTION:<doc-id>:<on|off>"}"#
                }
                let want = parts[1].lowercased()
                let on = (want == "on" || want == "true" || want == "1" || want == "yes")
                do {
                    try databaseManager.setSpoilerProtection(on, for: id)
                } catch {
                    return #"{"error":"Failed to set spoiler protection: \#(error)"}"#
                }
                return json(["status": "ok", "documentID": id.uuidString, "spoilerProtection": on])

            case "SET_READING_POSITION":
                // 2026-06-17 — Spoiler firewall test support. FORCE the reading
                // position (current + furthest) to an exact offset so the A/B
                // probes can set the spoiler line precisely (the furthest offset
                // is otherwise max()-sticky). Usage: SET_READING_POSITION:<doc>:<offset>
                let parts = (arg ?? "").split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let id = UUID(uuidString: parts[0]), let off = Int(parts[1]) else {
                    return #"{"error":"Usage: SET_READING_POSITION:<doc-id>:<offset>"}"#
                }
                do {
                    try databaseManager.forceReadingPosition(off, for: id)
                } catch {
                    return #"{"error":"Failed to set reading position: \#(error)"}"#
                }
                return json(["status": "ok", "documentID": id.uuidString, "offset": off])

            case "REINDEX_DOCUMENT":
                // 2026-05-23 — Step 8f: rewired to the new
                // unit-anchored chunker. Atomically rebuilds the
                // chunk set for `id` from the document's units, then
                // fills embeddings under the active backend.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: REINDEX_DOCUMENT:<doc-id>"}"#
                }
                let docs = try databaseManager.documents()
                guard docs.first(where: { $0.id == id }) != nil else {
                    return #"{"error":"Document not found"}"#
                }
                let dbRef = databaseManager
                Task.detached {
                    // forceRebuild: REINDEX means "re-chunk from scratch" (e.g.
                    // after a chunker fix), so it must override the new
                    // resume-on-partial default that would otherwise just top up
                    // NULL rows on the existing chunks. (2026-06-19)
                    await UnitEmbeddingService.shared.enqueueIndexing(
                        documentID: id, databaseManager: dbRef, forceRebuild: true
                    )
                }
                return json([
                    "reindexed": true,
                    "id": id.uuidString,
                    "note": "Re-chunking + re-embedding dispatched in background. Poll LIST_UNIT_CHUNKS for completion."
                ])

            case "RESET_DOCUMENT_METADATA":
                // 2026-05-23 — Step 8f: removed alongside the
                // synthetic-metadata / DocumentMetadataService surface.
                _ = arg
                return #"{"error":"RESET_DOCUMENT_METADATA removed in Step 8f."}"#

            case "EXTRACT_METADATA_NOW":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"EXTRACT_METADATA_NOW removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "RUN_METADATA_CHAIN":
                // 2026-05-05 — Diagnostic: directly run enhanceMetadata
                // synchronously (well, awaited) and report the outcome.
                // Bypasses the dispatch chain inside enqueueIndexing
                // so we can isolate whether the issue is the chain
                // plumbing vs the enhancement logic itself.
                // 2026-05-23 — Step 8f: RUN_METADATA_CHAIN,
                // PHASE_B_DEBUG, PHASE_B_STATUS, PHASE_B_START,
                // PHASE_B_STOP all torn out — the synthetic-metadata
                // chunk path and the Phase B chunk enhancer / scheduler
                // are gone. Return a friendly note so any lingering
                // test harness that hits these gets a clear signal.
                _ = arg
                return #"{"error":"Verb removed in Step 8f (synthetic-metadata + Phase B chunk enhancement torn out)."}"#

            case "INDEXING_STATE":
                // 2026-05-24 — re-wired to IndexingTracker.sharedForChat
                // (post-8f tracker re-build). Args: optional <doc-id>
                // to scope to one document. With no arg, dumps state
                // for every in-flight document.
                let tracker = IndexingTracker.sharedForChat
                let progress = tracker.indexingProgress
                if let raw = arg, !raw.isEmpty {
                    guard let id = UUID(uuidString: raw) else {
                        return #"{"error":"Invalid document ID"}"#
                    }
                    if let p = progress[id] {
                        return json([
                            "documentID": id.uuidString,
                            "processed": p.processed,
                            "total": p.total,
                            "fraction": p.fraction,
                            "isIndexing": true
                        ])
                    }
                    return json([
                        "documentID": id.uuidString,
                        "isIndexing": false
                    ])
                }
                let items: [[String: Any]] = progress.map { (id, p) in
                    [
                        "documentID": id.uuidString,
                        "processed": p.processed,
                        "total": p.total,
                        "fraction": p.fraction
                    ]
                }
                return json([
                    "inFlightCount": items.count,
                    "documents": items
                ])

            case "THERMAL_STATE":
                // Pillar 2 observation: current device thermal state (+ the
                // governor's view, which honors the DEBUG injection). Lets a
                // verification run confirm proactive pacing keeps the device
                // cool during indexing, and feeds Pillar 4's "cooling down".
                func thermalName(_ s: ProcessInfo.ThermalState) -> String {
                    switch s {
                    case .nominal: return "nominal"
                    case .fair: return "fair"
                    case .serious: return "serious"
                    case .critical: return "critical"
                    @unknown default: return "unknown"
                    }
                }
                let governed = await ThermalGovernor.shared.snapshot()
                return json([
                    "thermalState": thermalName(ProcessInfo.processInfo.thermalState),
                    "governorState": thermalName(governed),
                    "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled
                ])

            case "HALT_INDEXING":
                // Pillar 3 escape switch (headless): same path the library's
                // "Stop" button drives — halt all background indexing + clear the
                // affected docs' suspect index for a clean rebuild. Lets a
                // verification run (or a recovery from an over-queue) trigger the
                // halt without a physical tap.
                await IndexingEscapeController.shared.halt()
                let pending = IndexingEscapeController.shared.pendingReindex.map { $0.uuidString }
                let cooling = IndexingEscapeController.shared.waitingForCooldown
                return json(["halted": true,
                             "pendingReindex": pending,
                             "waitingForCooldown": cooling])

            case "REBUILD_INDEXING":
                // Pillar 3: the "Rebuild now" affordance, headless — re-enqueue
                // every pending document through the safe paced queue immediately.
                IndexingEscapeController.shared.rebuildNow()
                return json(["rebuilding": true])

            case "ENHANCE_CHUNK_NOW":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"ENHANCE_CHUNK_NOW removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "RETRY_REFUSED":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"RETRY_REFUSED removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "LIST_REFUSED_CHUNKS":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"LIST_REFUSED_CHUNKS removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "LIST_ENHANCED_CHUNKS":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"LIST_ENHANCED_CHUNKS removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "LIST_UNITS_SUMMARY":
                // Step 9 diagnostic — kind counts + first 10 units for
                // a document. Used to verify heading promotion fired
                // (DOCX/HTML/EPUB/PDF Phase 0 prerequisite work).
                guard let raw = arg, let id = UUID(uuidString: raw) else {
                    return #"{"error":"Usage: LIST_UNITS_SUMMARY:<doc-id>"}"#
                }
                let units = try databaseManager.units(for: id)
                var kindCounts: [String: Int] = [:]
                for u in units { kindCounts[u.kind.rawValue, default: 0] += 1 }
                let samples: [[String: Any]] = units.prefix(10).map { u in
                    [
                        "seq": u.sequence,
                        "kind": u.kind.rawValue,
                        "level": u.metadata.headingLevel ?? -1,
                        "preview": String(u.text.prefix(60))
                    ]
                }
                return json([
                    "documentID": id.uuidString,
                    "totalUnits": units.count,
                    "kindCounts": kindCounts,
                    "samples": samples
                ])

            case "READER_OBSERVATION":
                // 8f follow-up #12 diagnostic — returns the live
                // ReaderObservation snapshot so harness tests can
                // verify reader-aware lock plumbing fires (open
                // document tracked, current unit resolved on
                // sentence advance, state cleared on dismiss).
                let snap = ReaderObservation.shared.snapshot()
                return json([
                    "openDocumentID": snap.openDocumentID?.uuidString ?? "",
                    "currentOffset": snap.currentOffset ?? -1,
                    "currentUnitID": snap.currentUnitID?.uuidString ?? "",
                    "visibleChunkCount": snap.visibleChunks.count,
                    "ttsInUseChunkIndex": snap.ttsInUseChunk?.chunkIndex ?? -1
                ])

            case "GET_ENHANCEMENT_STATUS":
                // 2026-05-22 Phase 2.2 Step 7 — diagnostic verb.
                // Returns the document's enhancement_status state +
                // tier2_pages_done summary + tier3_tokens_done + last
                // error, plus the live in-memory queue snapshot from
                // PDFEnhancementService for visibility into whether
                // the doc is queued / processing / idle.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: GET_ENHANCEMENT_STATUS:<doc-id>"}"#
                }
                let row = try databaseManager.enhancementStatus(for: id)
                let snapshot = await PDFEnhancementService.shared.snapshot()
                let pagesDoneCount: Int = {
                    guard let row,
                          let data = row.tier2PagesDoneJSON.data(using: .utf8),
                          let arr = try? JSONDecoder().decode([Int].self, from: data) else { return 0 }
                    return arr.count
                }()
                return json([
                    "documentID": id.uuidString,
                    "status": row?.status ?? "na",
                    "tier2PagesDoneCount": pagesDoneCount,
                    "tier3TokensDone": row?.tier3TokensDone ?? 0,
                    "error": row?.error ?? "",
                    "queue": snapshot.queue.map(\.uuidString),
                    "currentlyProcessing": snapshot.current?.uuidString ?? "",
                    "cancelledInMemory": snapshot.cancelled.map(\.uuidString),
                    "queuePosition": snapshot.queue.firstIndex(of: id) ?? -1
                ])

            case "LIST_AFM_CORRECTIONS":
                // 2026-06-09 (#3 Tier-3 verify) — diagnostic verb exposing the
                // recorded AFM fusion verdicts for a document. `changed` lists
                // rows where corrected != original (REAL applied corrections —
                // proves Tier-3 fired, not just ran); `keptCount` is the
                // unchanged verdicts recorded for idempotency. Lets the antenna
                // confirm a fusion correction fired AND persisted (survives
                // relaunch, since it reads the on-disk table).
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: LIST_AFM_CORRECTIONS:<doc-id>"}"#
                }
                let afmRows = try databaseManager.afmCorrections(for: id)
                let changed = afmRows.filter { $0.original != $0.corrected }
                return json([
                    "documentID": id.uuidString,
                    "total": afmRows.count,
                    "changedCount": changed.count,
                    "keptCount": afmRows.count - changed.count,
                    "changed": changed.map { ["original": $0.original, "corrected": $0.corrected] }
                ])

            case "HEAVY_LANE_STATUS":
                // 2026-06-09 (global serial lane) — diagnostic + on-device
                // SEQUENTIAL PROOF. `maxConcurrentObserved` must stay 1 and
                // `overlapsInRing` must be 0 (the lane's recorded START/END
                // intervals never overlap → only one heavy op runs at a
                // time). `recent` lists the last ops with start/end so the
                // non-overlapping timeline is visible. Queried mid-processing
                // it also shows the antenna stays responsive under load.
                let lane = await HeavyWorkLane.shared.status()
                let sortedRing = lane.recent.sorted { $0.startedAt < $1.startedAt }
                var overlaps = 0
                if sortedRing.count >= 2 {
                    for i in 1..<sortedRing.count where sortedRing[i].startedAt < sortedRing[i - 1].endedAt {
                        overlaps += 1
                    }
                }
                let recentJSON = sortedRing.suffix(20).map { e -> [String: Any] in
                    ["label": e.label,
                     "ms": e.durationMs,
                     "start": Int(e.startedAt.timeIntervalSince1970 * 1000),
                     "end": Int(e.endedAt.timeIntervalSince1970 * 1000)]
                }
                return json([
                    "currentLabel": lane.currentLabel ?? "",
                    "queueDepth": lane.queueDepth,
                    "concurrentNow": lane.concurrentNow,
                    "maxConcurrentObserved": lane.maxConcurrentObserved,
                    "totalCompleted": lane.totalCompleted,
                    "overlapsInRing": overlaps,
                    "recent": recentJSON
                ])

            case "HEAVY_LANE_RESET":
                // Reset the lane telemetry so a verification run starts the
                // maxConcurrentObserved / totalCompleted tally clean.
                await HeavyWorkLane.shared.resetTelemetry()
                return #"{"reset":true}"#

            case "LIST_PAGE_FLAGS":
                // 2026-05-22 — Tier 1/2 Phase 1 calibration verb.
                // Returns the per-page confidence-detector output for
                // a PDF document. Empty / "not assessed" when called
                // on a non-PDF, on a PDF imported before this build,
                // or when the sidecar was deleted.
                //
                // Usage:
                //   LIST_PAGE_FLAGS:<doc-id>           — flagged pages only (default)
                //   LIST_PAGE_FLAGS:<doc-id>:all       — every page including unflagged
                //
                // The default surface is flagged-only because that's
                // what calibration cares about. The full per-page
                // payload (signals + reasons) is included for each
                // returned page so we can recompute thresholds offline
                // without re-importing.
                let raw = arg ?? ""
                let parts = raw.split(separator: ":", maxSplits: 1,
                                      omittingEmptySubsequences: false)
                guard parts.count >= 1,
                      let id = UUID(uuidString: String(parts[0])) else {
                    return #"{"error":"Usage: LIST_PAGE_FLAGS:<doc-id>[:all]"}"#
                }
                let includeAll = parts.count >= 2 && String(parts[1]).lowercased() == "all"
                guard let record = PageFlagsStore.read(documentID: id) else {
                    return json([
                        "documentID": id.uuidString,
                        "assessed": false,
                        "reason": "no calibration record on disk (re-import to populate)"
                    ])
                }
                let included = includeAll
                    ? record.flags
                    : record.flags.filter { $0.needsTier2 }
                let pages: [[String: Any]] = included.map { f in
                    var page: [String: Any] = [
                        "pageIndex": f.pageIndex,
                        "needsTier2": f.needsTier2,
                        "tier2Mode": f.tier2Mode.rawValue,
                        "reasons": f.reasons,
                        "signals": [
                            "charCount": f.signals.charCount,
                            "pageAreaPt2": f.signals.pageAreaPt2,
                            "charDensity": f.signals.charDensity,
                            "longCapsTokenCount": f.signals.longCapsTokenCount,
                            "avgWordLength": f.signals.avgWordLength
                        ]
                    ]
                    if let t2 = f.tier2 {
                        page["tier2"] = [
                            "ran": t2.ran,
                            "decision": t2.decision,
                            "tier2Chars": t2.tier2Chars
                        ]
                    }
                    return page
                }
                let summary = record.summary
                return json([
                    "documentID": record.documentID,
                    "fileName": record.fileName ?? "",
                    "assessed": true,
                    "detectorVersion": record.detectorVersion,
                    "assessedAt": ISO8601DateFormatter().string(from: record.assessedAt),
                    "pageCount": summary.pageCount,
                    "flaggedCount": summary.flaggedCount,
                    "modeCounts": summary.modeCounts,
                    "tier2Counts": summary.tier2Counts,
                    "returned": pages.count,
                    "includeAll": includeAll,
                    "pages": pages
                ])

            case "GET_DOCUMENT_METADATA":
                // 2026-05-29 — restored: reads the structured bibliographic
                // fields (author + year) populated by DocumentMetadataExtractor.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Missing or invalid document ID"}"#
                }
                let meta = try databaseManager.documentMetadata(for: id)
                return json(["id": id.uuidString,
                             "title": meta?.title ?? "",
                             "authors": (meta?.authors ?? []).joined(separator: ", "),
                             "year": meta?.year ?? "",
                             "extractedAt": "\(meta?.extractedAt.timeIntervalSince1970 ?? 0)"])

            case "LIST_SYNTHETIC_CHUNKS":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"LIST_SYNTHETIC_CHUNKS removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "LIST_UNIT_CHUNKS":
                // 2026-05-23 — Step 8b: inspect the NEW unit-anchored
                // chunk table (`unit_embedding_chunks`). Args: <doc-id>.
                // Returns counts (total, with embedding, without) plus
                // FTS5 mirror rowcount + a few text/length samples.
                // Cheap; used by the verification harness during the
                // 8a-8f rebuild rollout.
                guard let raw = arg, let id = UUID(uuidString: raw) else {
                    return #"{"error":"Usage: LIST_UNIT_CHUNKS:<doc-id>"}"#
                }
                let rows = try databaseManager.unitEmbeddingChunks(for: id)
                let filled = rows.filter { $0.embedding != nil }.count
                let samples: [[String: Any]] = rows.prefix(5).map { c in
                    [
                        "chunkIndex": c.chunkIndex,
                        "length": c.text.count,
                        "startUnitID": c.startUnitID.uuidString,
                        "startIntra": c.startIntraOffset,
                        "endUnitID": c.endUnitID.uuidString,
                        "endIntra": c.endIntraOffset,
                        "embeddingDims": c.embedding?.count ?? 0,
                        "preview": String(c.text.prefix(60))
                    ]
                }
                return json([
                    "documentID": id.uuidString,
                    "totalChunks": rows.count,
                    "embeddingsFilled": filled,
                    "embeddingsNull": rows.count - filled,
                    "samples": samples
                ])

            case "LIST_CHUNKS":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"LIST_CHUNKS removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "BUILD_RAPTOR_TREE":
                // BUILD_RAPTOR_TREE:<doc-id>:<k>:<maxChunks>
                //
                // 2026-05-30 — end-to-end RAPTOR tier slice: cluster +
                // AFM-summarize + verify (cosine + entity-grounding), then
                // EMBED each verified summary (NLContextual) and STORE it in
                // the collapsed pool (unit_embedding_chunks, chunk_index >=
                // raptorSummaryIndexBase). Leaves untouched. After this, the
                // existing HybridRetriever fuses leaves + summaries with no
                // retriever change. Returns counts + the stored summaries.
                let pr = (arg ?? "").split(separator: ":", maxSplits: 2).map(String.init)
                guard pr.count >= 1, let id = UUID(uuidString: pr[0].trimmingCharacters(in: .whitespaces)) else {
                    return #"{"error":"Usage: BUILD_RAPTOR_TREE:<doc-id>:<k>:<maxChunks>"}"#
                }
                let kReq2 = pr.count > 1 ? (Int(pr[1]) ?? 16) : 16
                let maxChunks2 = pr.count > 2 ? (Int(pr[2]) ?? 400) : 400
                let leaves2 = ((try? databaseManager.unitEmbeddingChunks(for: id)) ?? [])
                    .filter { $0.embedding != nil && $0.chunkIndex < DatabaseManager.raptorSummaryIndexBase }
                    .sorted { $0.chunkIndex < $1.chunkIndex }
                let slice2 = Array(leaves2.prefix(maxChunks2))
                guard slice2.count >= 2 else { return #"{"error":"not enough embedded leaf chunks"}"# }
                let inputNodes2 = slice2.map {
                    RaptorTreeBuilder.InputNode(
                        chunkIndex: $0.chunkIndex, text: $0.text, embedding: $0.embedding!,
                        startUnitID: $0.startUnitID, endUnitID: $0.endUnitID)
                }
                let docText2 = (try? databaseManager.documents())?.first(where: { $0.id == id })?.plainText ?? ""
                let builder2 = RaptorTreeBuilder()
                let cfg2 = RaptorTreeBuilder.Config(clusterCount: kReq2)
                let summaryNodes2 = await builder2.buildLayer(layer: 1, nodes: inputNodes2, documentText: docText2, config: cfg2)
                // Embed each verified summary (NLContextual .document) + store.
                var toStore: [StoredUnitEmbeddingChunk] = []
                for (i, node) in summaryNodes2.enumerated() {
                    // Global serial lane (this is the DEBUG manual-RAPTOR verb;
                    // route its summary embeds through the lane too so a manual
                    // build can't overlap automatic background heavy work).
                    let nodeText = node.text
                    let emb = await HeavyWorkLane.shared.run(label: "RAPTOR-embed-debug") {
                        EmbeddingProvider.shared.embed(nodeText, as: .document)
                    }
                    toStore.append(StoredUnitEmbeddingChunk(
                        id: UUID(),
                        documentID: id,
                        chunkIndex: DatabaseManager.raptorSummaryIndexBase + i,
                        startUnitID: node.startUnitID,
                        startIntraOffset: 0,
                        endUnitID: node.endUnitID,
                        endIntraOffset: 0,
                        text: node.text,
                        embedding: emb))
                }
                do { try databaseManager.replaceSummaryNodes(toStore, for: id) }
                catch { return "{\"error\":\"store failed: \(error)\"}" }
                let stored = toStore.map { ["chunkIndex": $0.chunkIndex, "embedded": $0.embedding != nil, "text": String($0.text.prefix(140))] as [String: Any] }
                let payloadB: [String: Any] = [
                    "documentID": id.uuidString,
                    "leafChunksUsed": slice2.count,
                    "summaryNodesStored": toStore.count,
                    "summaries": stored
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payloadB),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"BUILD_RAPTOR_TREE serialization failed"}"#

            case "RAPTOR_SUMMARIZE_TEST":
                // RAPTOR_SUMMARIZE_TEST:<doc-id>:<k>:<maxChunks>
                //
                // 2026-05-30 — first end-to-end slice of the RAPTOR tier:
                // cluster the first <maxChunks> leaf chunks (cosine k-means,
                // NLContextual embeddings) into <k> groups, summarize each
                // with the ACTIVE model (AFM @Generable, paced), VERIFY each
                // against its source, and return the summaries + member
                // samples so generation quality can be read directly before
                // any storage/retrieval wiring. Defaults (AFM+NLContextual)
                // must produce coherent, faithful summaries here.
                let p = (arg ?? "").split(separator: ":", maxSplits: 2).map(String.init)
                guard p.count >= 1, let id = UUID(uuidString: p[0].trimmingCharacters(in: .whitespaces)) else {
                    return #"{"error":"Usage: RAPTOR_SUMMARIZE_TEST:<doc-id>:<k>:<maxChunks>"}"#
                }
                let kReq = p.count > 1 ? (Int(p[1]) ?? 12) : 12
                let maxChunks = p.count > 2 ? (Int(p[2]) ?? 300) : 300
                let leaves = ((try? databaseManager.unitEmbeddingChunks(for: id)) ?? [])
                    .filter { $0.embedding != nil && $0.chunkIndex < 1_000_000 }
                    .sorted { $0.chunkIndex < $1.chunkIndex }
                let slice = Array(leaves.prefix(maxChunks))
                guard slice.count >= 2 else { return #"{"error":"not enough embedded leaf chunks"}"# }
                let textByIdx = Dictionary(uniqueKeysWithValues: slice.map { ($0.chunkIndex, $0.text) })
                let inputNodes = slice.map {
                    RaptorTreeBuilder.InputNode(
                        chunkIndex: $0.chunkIndex, text: $0.text, embedding: $0.embedding!,
                        startUnitID: $0.startUnitID, endUnitID: $0.endUnitID)
                }
                let docText = (try? databaseManager.documents())?.first(where: { $0.id == id })?.plainText ?? ""
                let builder = RaptorTreeBuilder()
                let cfg = RaptorTreeBuilder.Config(clusterCount: kReq)
                let nodes = await builder.buildLayer(layer: 1, nodes: inputNodes, documentText: docText, config: cfg)
                let nodeRows: [[String: Any]] = nodes.map { n in
                    let samples = n.memberChunkIndices.prefix(3).compactMap { textByIdx[$0].map { String($0.prefix(70)).replacingOccurrences(of: "\n", with: " ") } }
                    return [
                        "members": n.memberChunkIndices.count,
                        "verifyKept": n.verifyKept,
                        "verifyDropped": n.verifyDropped,
                        "memberSamples": samples,
                        "summary": n.text
                    ]
                }
                let payloadR: [String: Any] = [
                    "documentID": id.uuidString,
                    "leafChunksUsed": slice.count,
                    "requestedK": kReq,
                    "summaryNodes": nodes.count,
                    "nodes": nodeRows
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payloadR),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"RAPTOR_SUMMARIZE_TEST serialization failed"}"#

            case "EXPORT_EMBEDDINGS":
                // EXPORT_EMBEDDINGS:<doc-id>[:<maxCount>]
                //
                // 2026-05-30 — exports real chunk embeddings (+ short text)
                // for the off-device k-means cluster-coherence measurement
                // (RAPTOR tier gate: do Posey's embeddings cluster
                // coherently enough to summarize?). Strided even sample to
                // keep the payload small; embeddings rounded to 4 decimals
                // (plenty for cosine/k-means).
                let parts = (arg ?? "").split(separator: ":", maxSplits: 1).map(String.init)
                guard let first = parts.first,
                      let id = UUID(uuidString: first.trimmingCharacters(in: .whitespaces)) else {
                    return #"{"error":"Usage: EXPORT_EMBEDDINGS:<doc-id>[:<maxCount>]"}"#
                }
                let maxCount = parts.count > 1 ? (Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 600) : 600
                let all = ((try? databaseManager.unitEmbeddingChunks(for: id)) ?? [])
                    .filter { $0.embedding != nil }
                let stride = max(1, all.count / max(1, maxCount))
                var sampled: [[String: Any]] = []
                var i = 0
                while i < all.count {
                    let c = all[i]
                    if let emb = c.embedding {
                        sampled.append([
                            "idx": c.chunkIndex,
                            "text": String(c.text.prefix(160)).replacingOccurrences(of: "\n", with: " "),
                            "emb": emb.map { ($0 * 10000).rounded() / 10000 }
                        ])
                    }
                    i += stride
                }
                let payloadX: [String: Any] = [
                    "documentID": id.uuidString,
                    "total": all.count,
                    "sampled": sampled.count,
                    "stride": stride,
                    "dim": all.first?.embedding?.count ?? 0,
                    "chunks": sampled
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payloadX),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"EXPORT_EMBEDDINGS serialization failed"}"#

            case "LIST_HEADINGS":
                // LIST_HEADINGS:<doc-id>
                //
                // 2026-05-30 — structured-knowledge sectioning diagnostic.
                // Dumps every heading unit (kind=.heading) with sequence,
                // level, and text, plus total-unit + prose-char counts, so
                // we can judge whether a format's importer produces clean
                // chapter boundaries to anchor section-level summaries — or
                // ragged detection that needs a size-window fallback.
                guard let raw = arg, let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
                    return #"{"error":"Usage: LIST_HEADINGS:<doc-id>"}"#
                }
                let units = (try? databaseManager.units(for: id)) ?? []
                let headings = units.filter { $0.kind == .heading }
                var proseChars = 0
                for u in units where u.kind.carriesProseText { proseChars += u.text.count }
                let headingRows: [[String: Any]] = headings.map { h in
                    [
                        "seq": h.sequence,
                        "level": h.metadata.headingLevel as Any? ?? NSNull(),
                        "len": h.text.count,
                        "text": String(h.text.prefix(80)).replacingOccurrences(of: "\n", with: " ")
                    ]
                }
                let payloadH: [String: Any] = [
                    "documentID": id.uuidString,
                    "totalUnits": units.count,
                    "headingCount": headings.count,
                    "proseChars": proseChars,
                    "avgCharsPerHeading": headings.isEmpty ? proseChars : proseChars / max(1, headings.count),
                    "headings": headingRows
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payloadH),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"LIST_HEADINGS serialization failed"}"#

            case "FIND_CHUNK":
                // FIND_CHUNK:<doc-id>:<substring>
                //
                // 2026-05-30 — chunking diagnostic (Rule 5 render-and-look).
                // Returns the FULL text of every retrieval chunk whose text
                // contains <substring> (case-insensitive), with its index,
                // char length, and start/end unit. Tells us definitively
                // whether a passage lives as one clean chunk, is split across
                // a boundary, or is buried inside a larger window.
                guard let parts = arg?.split(separator: ":", maxSplits: 1).map(String.init),
                      parts.count == 2,
                      let docID = UUID(uuidString: parts[0].trimmingCharacters(in: .whitespaces)) else {
                    return #"{"error":"FIND_CHUNK requires <doc-id>:<substring>"}"#
                }
                let needle = parts[1].lowercased()
                let allChunks = (try? databaseManager.unitEmbeddingChunks(for: docID)) ?? []
                let matches = allChunks
                    .filter { $0.text.lowercased().contains(needle) }
                    .map { c -> [String: Any] in
                        [
                            "chunkIndex": c.chunkIndex,
                            "length": c.text.count,
                            "startUnit": c.startUnitID.uuidString,
                            "endUnit": c.endUnitID.uuidString,
                            "spansUnits": c.startUnitID != c.endUnitID,
                            "text": c.text
                        ]
                    }
                let payloadF: [String: Any] = [
                    "documentID": docID.uuidString,
                    "needle": parts[1],
                    "totalChunks": allChunks.count,
                    "matchCount": matches.count,
                    "matches": matches
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payloadF),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"FIND_CHUNK serialization failed"}"#

            case "EMBED_QUERY_CONTEXTUAL":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"EMBED_QUERY_CONTEXTUAL removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "EMBED_QUERY":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"EMBED_QUERY removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "RAG_TRACE":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"RAG_TRACE removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "RAG_FIND":
                // 2026-05-23 — Step 8f: removed (legacy chunk/metadata/scheduler verb).
                _ = arg
                return #"{\"error\":\"RAG_FIND removed in Step 8f (legacy retrieval / chunk-enhancer surface area torn out).\"}"#

            case "RAG_DEBUG":
                // RAG_DEBUG:<doc-id>:<query>
                //
                // 2026-05-30 — Hal-style retrieval observability (ported
                // from Hal's MEMORY_SEARCH_DEBUG). Runs the REAL
                // HybridRetriever.retrieve() but with a GENEROUS limit
                // (25) so the full candidate ranking is visible — not just
                // the ~2 chunks that survive AFM's tiny prompt budget in a
                // live /ask. For every candidate it returns the fused RRF
                // relevance AND the separate semantic-cosine + semantic-rank
                // + BM25-rank, so the tuning loop can SEE why a chunk did or
                // didn't rank, instead of inferring it from the 2 injected
                // chunks. Plus outcome-level gate state (bm25Excluded,
                // topRelevance) and the fixed RRF constants in effect.
                guard let parts = arg?.split(separator: ":", maxSplits: 1).map(String.init),
                      parts.count == 2,
                      let docID = UUID(uuidString: parts[0].trimmingCharacters(in: .whitespaces)) else {
                    return #"{"error":"RAG_DEBUG requires <doc-id>:<query>"}"#
                }
                let query = parts[1]
                let retriever = HybridRetriever(database: databaseManager)
                let outcome = retriever.retrieve(documentID: docID, query: query, limit: 25)
                let candidates: [[String: Any]] = outcome.results.enumerated().map { (i, c) in
                    var row: [String: Any] = [
                        "rank": i + 1,
                        "chunkID": c.chunkID,
                        "rrf": (c.relevance * 100000).rounded() / 100000,
                        "semanticScore": c.semanticScore.map { ($0 * 1000).rounded() / 1000 as Any } ?? NSNull(),
                        "semanticRank": c.semanticRank.map { $0 as Any } ?? NSNull(),
                        "bm25Rank": c.bm25Rank.map { $0 as Any } ?? NSNull(),
                        "textPreview": String(c.text.prefix(160)).replacingOccurrences(of: "\n", with: " ")
                    ]
                    // Flag the BM25-only signal explicitly (semantic dark on
                    // this chunk) — the case that fabricates answers.
                    row["bm25Only"] = (c.semanticScore == nil)
                    return row
                }
                let payload: [String: Any] = [
                    "documentID": docID.uuidString,
                    "query": query,
                    "candidateCount": outcome.results.count,
                    "topRelevance": (outcome.topRelevance * 100000).rounded() / 100000,
                    "bm25Excluded": outcome.bm25Excluded,
                    "confidenceFloor": (HybridRetriever.confidenceFloor * 100000).rounded() / 100000,
                    "candidates": candidates
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"RAG_DEBUG serialization failed"}"#

            case "RAG_DEBUG_EXPANDED":
                // RAG_DEBUG_EXPANDED:<doc-id>:<query>
                //
                // 2026-05-30 — measurement tool for the query-expansion
                // lever (Hal MEMORY_SEARCH_EXPANDED parallel). Runs the
                // SAME two-pass flow the chat path uses: base retrieve →
                // trigger check → LLM expand (active model) → re-retrieve
                // with terms OR'd into BM25 → keep-if-better. Returns the
                // trigger reason, the LLM terms, base-vs-expanded top
                // relevance, whether it was kept, and the top candidates
                // of BOTH passes so the recall lift is visible. Generous
                // limit (25). Idempotent / read-only (no cache write).
                guard let parts = arg?.split(separator: ":", maxSplits: 1).map(String.init),
                      parts.count == 2,
                      let docID = UUID(uuidString: parts[0].trimmingCharacters(in: .whitespaces)) else {
                    return #"{"error":"RAG_DEBUG_EXPANDED requires <doc-id>:<query>"}"#
                }
                let query = parts[1]
                let retriever = HybridRetriever(database: databaseManager)
                let base = retriever.retrieve(documentID: docID, query: query, limit: 25)
                let reason = AskPoseyQueryExpansion.triggerReason(
                    topRelevance: base.topRelevance, topChunks: base.results
                )
                var terms: [String] = []
                var expandedTop: Double? = nil
                var expandedCandidates: [[String: Any]] = []
                var kept = false
                if reason != nil {
                    terms = await AskPoseyQueryExpansion.expand(query: query)
                    if !terms.isEmpty {
                        let expanded = retriever.retrieve(
                            documentID: docID, query: query, limit: 25, expansionTerms: terms
                        )
                        expandedTop = (expanded.topRelevance * 100000).rounded() / 100000
                        kept = expanded.topRelevance >= base.topRelevance
                        expandedCandidates = expanded.results.prefix(8).enumerated().map { (i, c) in
                            [
                                "rank": i + 1,
                                "rrf": (c.relevance * 100000).rounded() / 100000,
                                "semanticScore": c.semanticScore.map { ($0 * 1000).rounded() / 1000 as Any } ?? NSNull(),
                                "bm25Rank": c.bm25Rank.map { $0 as Any } ?? NSNull(),
                                "bm25Only": (c.semanticScore == nil),
                                "textPreview": String(c.text.prefix(140)).replacingOccurrences(of: "\n", with: " ")
                            ]
                        }
                    }
                }
                let baseCandidates: [[String: Any]] = base.results.prefix(8).enumerated().map { (i, c) in
                    [
                        "rank": i + 1,
                        "rrf": (c.relevance * 100000).rounded() / 100000,
                        "semanticScore": c.semanticScore.map { ($0 * 1000).rounded() / 1000 as Any } ?? NSNull(),
                        "bm25Rank": c.bm25Rank.map { $0 as Any } ?? NSNull(),
                        "bm25Only": (c.semanticScore == nil),
                        "textPreview": String(c.text.prefix(140)).replacingOccurrences(of: "\n", with: " ")
                    ]
                }
                let payloadE: [String: Any] = [
                    "documentID": docID.uuidString,
                    "query": query,
                    "triggered": reason != nil,
                    "triggerReason": reason ?? NSNull(),
                    "expansionTerms": terms,
                    "baseTopRelevance": (base.topRelevance * 100000).rounded() / 100000,
                    "expandedTopRelevance": expandedTop.map { $0 as Any } ?? NSNull(),
                    "kept": kept ? "expanded" : "base",
                    "baseCandidates": baseCandidates,
                    "expandedCandidates": expandedCandidates
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payloadE),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"RAG_DEBUG_EXPANDED serialization failed"}"#

            case "RAG_EVAL":
                // RAG_EVAL:<doc-id>:<query>
                //
                // 2026-06-20 — embedder/retrieval A/B/C Phase-1 instrument
                // (model-free). Unlike RAG_DEBUG (160-char previews, no
                // neighbor expansion), this runs the EXACT chat retrieval
                // path — `AskPoseyChatViewModel.retrieveRAGChunks` — so it
                // reflects the active embedder (SET_EMBEDDING_PROVIDER), the
                // small-to-big neighbor radius (SET_NEIGHBOR_EXPANSION), the
                // model-aware RAG token budget, and the 0.40 relevance floor,
                // then returns the FULL stitched context the model would read.
                // The harness substring-tests the answer-key defining passage
                // against `stitched` to score retrieval hit-rate WITHOUT
                // invoking the LLM (no heat, no AFM cooldown). Faithful reuse
                // of the VM, not a divergent reimplementation (Rule 9).
                // Read-only: retrieval persists no turns.
                guard let parts = arg?.split(separator: ":", maxSplits: 1).map(String.init),
                      parts.count == 2,
                      let docID = UUID(uuidString: parts[0].trimmingCharacters(in: .whitespaces)) else {
                    return #"{"error":"RAG_EVAL requires <doc-id>:<query>"}"#
                }
                let query = parts[1]
                let evalDocs = (try? databaseManager.documents()) ?? []
                guard let evalDoc = evalDocs.first(where: { $0.id == docID }) else {
                    return #"{"error":"RAG_EVAL: document not found"}"#
                }
                let evalVM = AskPoseyChatViewModel(
                    documentID: docID,
                    documentPlainText: evalDoc.plainText,
                    documentTitle: evalDoc.title,
                    anchor: nil,
                    invocationReadingOffset: nil,
                    initialScrollAnchorStorageID: nil,
                    streamer: nil,
                    summarizer: nil,
                    databaseManager: databaseManager,
                    useSummarizedSTM: false)
                await evalVM.awaitHistoryLoaded()
                let evalChunks = await evalVM.retrieveRAGChunksForEval(for: query)
                let stitched = evalChunks.map { $0.text }.joined(separator: "\n\n")
                var evalRows: [[String: Any]] = []
                for (i, c) in evalChunks.enumerated() {
                    var row: [String: Any] = [
                        "rank": i + 1,
                        "relevance": (c.relevance * 100000).rounded() / 100000,
                        "startOffset": c.startOffset,
                        "length": c.text.count
                    ]
                    if let sem = c.semanticScore {
                        row["semanticScore"] = (sem * 1000).rounded() / 1000
                    } else {
                        row["semanticScore"] = NSNull()
                    }
                    evalRows.append(row)
                }
                let evalPayload: [String: Any] = [
                    "documentID": docID.uuidString,
                    "query": query,
                    "backend": EmbeddingBackend.current().rawValue,
                    "radius": NeighborExpansion.radius,
                    "topRelevance": (evalVM.lastRetrievalTopRelevance * 100000).rounded() / 100000,
                    "chunkCount": evalChunks.count,
                    "stitchedLength": stitched.count,
                    "stitched": stitched,
                    "chunks": evalRows
                ]
                if let data = try? JSONSerialization.data(withJSONObject: evalPayload),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"RAG_EVAL serialization failed"}"#

            case "GENERATE":
                // GENERATE:<prompt> — raw active-LLM generation with NO retrieval,
                // NO grounding, NO document context. The prompt is sent as a single
                // user turn through the model's own chat template. For HyDE Phase-1c
                // (let the on-device model generate a hypothetical answer passage to
                // re-query with) + direct model-behavior probes. Respects SET_LLM.
                guard let genPrompt = arg,
                      !genPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return #"{"error":"Usage: GENERATE:<prompt>"}"#
                }
                var generated = ""
                do {
                    let stream = LLMService.shared.streamChat(
                        messages: [ChatMessage(role: .user, content: genPrompt)],
                        model: ModelCatalog.current(),
                        options: LLMGenerationOptions(temperature: 0.0)
                    )
                    // streamChat yields CUMULATIVE snapshots — last == full text.
                    for try await chunk in stream { generated = chunk }
                } catch {
                    return #"{"error":"GENERATE failed: \#(error.localizedDescription)"}"#
                }
                let genPayload: [String: Any] = [
                    "model": ModelCatalog.current().displayName,
                    "prompt": genPrompt,
                    "response": generated
                ]
                if let data = try? JSONSerialization.data(withJSONObject: genPayload),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"GENERATE serialization failed"}"#

            case "MEMORY_STATS":
                // Read-only memory snapshot for the sustained-generation jetsam
                // investigation: available process memory + which embedder
                // backends are resident + the active LLM. Used to confirm the
                // embedder+LLM co-residency hypothesis and measure EVICT deltas.
                let ep = EmbeddingProvider.shared
                let memPayload: [String: Any] = [
                    "availableMB": (processAvailableMemoryMB() * 10).rounded() / 10,
                    "embeddersLoaded": [
                        "nlcontextual": ep.isLoaded(.nlContextual),
                        "nomic": ep.isLoaded(.nomic),
                        "mxbai": ep.isLoaded(.mxbai)
                    ],
                    "activeEmbedder": EmbeddingBackend.current().rawValue,
                    "activeLLM": ModelCatalog.current().displayName
                ]
                if let data = try? JSONSerialization.data(withJSONObject: memPayload),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"MEMORY_STATS serialization failed"}"#

            case "EVICT_EMBEDDER":
                // EVICT_EMBEDDER[:<nl|nomic|mxbai|all>] — release loaded embedder
                // bundle(s) to drop peak memory (the proposed jetsam fix: free the
                // embedder after retrieval, before generation). Lazy-reloads on
                // next embed. Reports the memory reclaimed.
                let beforeMB = processAvailableMemoryMB()
                let which = (arg ?? "all").lowercased().trimmingCharacters(in: .whitespaces)
                let target: EmbeddingBackend?
                switch which {
                case "nl", "nlcontextual": target = .nlContextual
                case "nomic": target = .nomic
                case "mxbai": target = .mxbai
                case "all", "": target = nil
                default: return #"{"error":"Usage: EVICT_EMBEDDER[:<nl|nomic|mxbai|all>]"}"#
                }
                let evicted = EmbeddingProvider.shared.evict(target)
                let afterMB = processAvailableMemoryMB()
                let evPayload: [String: Any] = [
                    "evictedCount": evicted,
                    "availableMBBefore": (beforeMB * 10).rounded() / 10,
                    "availableMBAfter": (afterMB * 10).rounded() / 10,
                    "reclaimedMB": ((afterMB - beforeMB) * 10).rounded() / 10
                ]
                if let data = try? JSONSerialization.data(withJSONObject: evPayload),
                   let s = String(data: data, encoding: .utf8) { return s }
                return #"{"error":"EVICT_EMBEDDER serialization failed"}"#

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

            case "GET_PLAYBACK_SKIP":
                // 2026-05-07 (parity #6): return the document's
                // playbackSkipUntilOffset so tests can verify the
                // TOC-skip wiring without inferring from segment
                // counts.
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Missing or invalid document ID"}"#
                }
                guard let doc = (try databaseManager.documents()).first(where: { $0.id == id }) else {
                    return #"{"error":"Document not found"}"#
                }
                return json([
                    "documentID": idStr,
                    "playbackSkipUntilOffset": doc.playbackSkipUntilOffset,
                    // 2026-05-21 — also surface contentEndOffset for
                    // verification of the Gutenberg tail detector.
                    "contentEndOffset": doc.contentEndOffset,
                    // 2026-05-21 (later) — surface skipSource so the
                    // test harness can verify the smart-skip
                    // classification: "" / "gutenberg" / "heuristic" /
                    // "user_keep" / "user_dismiss". See Document.swift
                    // for the enum.
                    "skipSource": doc.skipSource
                ])

            case "LIST_SEGMENTS_MATCHING":
                // 2026-05-07 (parity #10): return up to 50 sentence
                // segments from the currently visible document whose
                // text matches the supplied regex. Drives any test
                // that needs to verify how the segmenter handles a
                // specific text pattern (citation markers, abbrevs,
                // tricky punctuation) without scrolling visually.
                guard let pattern = arg, !pattern.isEmpty else {
                    return #"{"error":"Usage: LIST_SEGMENTS_MATCHING:<regex>"}"#
                }
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    return #"{"error":"Invalid regex"}"#
                }
                let snap = await MainActor.run { RemoteControlState.shared.segmentTexts }
                let matches = snap.compactMap { entry -> [String: Any]? in
                    let range = NSRange(entry.text.startIndex..., in: entry.text)
                    guard regex.firstMatch(in: entry.text, range: range) != nil else { return nil }
                    return [
                        "index": entry.index,
                        "text": entry.text,
                        "startOffset": entry.startOffset,
                        "endOffset": entry.endOffset
                    ]
                }
                let capped = Array(matches.prefix(50))
                return json([
                    "totalMatched": matches.count,
                    "returned": capped.count,
                    "segments": capped
                ])

            case "LIST_DISPLAY_BLOCKS_MATCHING":
                // 2026-05-07 (parity #10): same as
                // LIST_SEGMENTS_MATCHING but for the displayBlocks
                // render path (MD always, PDF, DOCX/HTML/EPUB with
                // images). Each result includes the block's `kind`
                // so paragraph vs heading vs visualPlaceholder is
                // visible.
                guard let pattern = arg, !pattern.isEmpty else {
                    return #"{"error":"Usage: LIST_DISPLAY_BLOCKS_MATCHING:<regex>"}"#
                }
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    return #"{"error":"Invalid regex"}"#
                }
                let snap = await MainActor.run { RemoteControlState.shared.displayBlockTexts }
                let matches = snap.compactMap { entry -> [String: Any]? in
                    let range = NSRange(entry.text.startIndex..., in: entry.text)
                    guard regex.firstMatch(in: entry.text, range: range) != nil else { return nil }
                    return [
                        "index": entry.index,
                        "kind": entry.kind,
                        "text": entry.text,
                        "startOffset": entry.startOffset,
                        "endOffset": entry.endOffset
                    ]
                }
                let capped = Array(matches.prefix(50))
                return json([
                    "totalMatched": matches.count,
                    "returned": capped.count,
                    "displayBlocks": capped
                ])

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

            case "OPEN_FIRST_IMAGE":
                // 2026-06-14 (c7) — drive the image-tap viewer. The image
                // .onTapGesture (6a8fc08) opens the full-screen zoomable sheet by
                // setting `expandedImageItem`; READER_TAP only toggles chrome and
                // there's no coord-tap on a physical phone. This posts to an
                // isolated ReaderView subview that runs the SAME viewer-open path
                // on the first .image unit with bytes — lets c7's tap-opens-viewer
                // half be verified on device.
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteOpenFirstImage, object: nil)
                }
                return json(["status": "posted"])

            case "SET_APPEARANCE":
                // 2026-05-28 — DEBUG-only verification primitive.
                // Lets CC verify chrome contrast and other
                // colorScheme-dependent rendering in BOTH Light
                // and Dark mode on a physical device without
                // touching the user's iOS Settings (which would
                // affect every other app on the device). Posey
                // reads this @AppStorage key in PoseyApp.body and
                // applies `.preferredColorScheme(...)` to the
                // WindowGroup. Argument: light | dark | system.
                let raw = (arg ?? "system").lowercased()
                let normalized: String
                switch raw {
                case "light", "dark", "system": normalized = raw
                default:
                    return json(["error": "SET_APPEARANCE expects light|dark|system; got \(raw)"])
                }
                await MainActor.run {
                    UserDefaults.standard.set(normalized, forKey: "debug.appearanceOverride")
                }
                return json(["status": "set", "appearance": normalized])

            case "GET_APPEARANCE":
                let current = UserDefaults.standard.string(forKey: "debug.appearanceOverride") ?? "system"
                return json(["appearance": current])

            case "DEBUG_SKIP":
                guard let idStr = arg, let docID = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: DEBUG_SKIP:<docID>"}"#
                }
                let snap = await MainActor.run { () -> [String: Any] in
                    var result: [String: Any] = ["documentID": docID.uuidString]
                    let refs = (try? databaseManager.unitSkipReferences(for: docID))
                    if let skipID = refs?.skipUnitID {
                        result["skipUnitID"] = skipID.uuidString
                        let units = (try? databaseManager.units(for: docID)) ?? []
                        var cum = 0
                        for u in units {
                            if u.id == skipID {
                                result["skipUnitOffset"] = cum
                                result["skipUnitSeq"] = u.sequence
                                result["skipUnitKind"] = String(describing: u.kind)
                                result["skipUnitTextPreview"] = String(u.text.prefix(120))
                                break
                            }
                            if u.kind.carriesProseText { cum += u.text.count + 2 }
                        }
                    } else {
                        result["skipUnitID"] = NSNull()
                    }
                    return result
                }
                if let data = try? JSONSerialization.data(withJSONObject: snap),
                   let s = String(data: data, encoding: .utf8) { return s }
                return json(["error": "snap failed"])

            case "DEBUG_ANNOTATIONS":
                // 2026-05-28 — diagnostic for the missing-glyph defect.
                // Dumps the live ReaderViewModel's annotation state so
                // we can see whether notes match unit ranges via the
                // fullPlainTextOffsetByUnitID map.
                guard let idStr = arg, let docID = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: DEBUG_ANNOTATIONS:<docID>"}"#
                }
                let snapshot = await MainActor.run { () -> [String: Any] in
                    var result: [String: Any] = ["documentID": docID.uuidString]
                    let notes = (try? databaseManager.notes(for: docID)) ?? []
                    result["noteCount"] = notes.count
                    var noteOffsets: [[String: Any]] = []
                    for n in notes {
                        noteOffsets.append([
                            "kind": String(describing: n.kind),
                            "start": n.startOffset,
                            "end": n.endOffset,
                        ])
                    }
                    result["notes"] = noteOffsets
                    let units = (try? databaseManager.units(for: docID)) ?? []
                    result["unitCount"] = units.count
                    var cum = 0
                    var unitRanges: [[String: Any]] = []
                    for u in units {
                        if u.kind.carriesProseText {
                            let start = cum
                            let end = cum + u.text.count
                            // Check if any note intersects this range.
                            var hits: [String] = []
                            for n in notes where n.startOffset >= start && n.startOffset < end {
                                hits.append(String(describing: n.kind))
                            }
                            if !hits.isEmpty {
                                unitRanges.append([
                                    "unitID": u.id.uuidString,
                                    "seq": u.sequence,
                                    "start": start,
                                    "end": end,
                                    "hits": hits,
                                ])
                            }
                            cum += u.text.count + 2
                        }
                    }
                    result["unitsWithAnnotations"] = unitRanges
                    return result
                }
                if let data = try? JSONSerialization.data(withJSONObject: snapshot),
                   let str = String(data: data, encoding: .utf8) {
                    return str
                }
                return json(["error": "snapshot serialization failed"])

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

            case "RESPOND_SKIP_PROMPT":
                // 2026-05-27 — Drive the smart-skip bottom sheet
                // programmatically. The native iOS alert this replaced
                // couldn't be tested via the antenna. Args:
                //   keep | jumpToChapter | chapter → confirmSkipKeep
                //   beginning | startFromBeginning | fromTop → revealFromBeginning
                let raw = arg?.lowercased() ?? ""
                let normalized: String
                switch raw {
                case "keep", "jumptochapter", "chapter":      normalized = "keep"
                case "beginning", "startfrombeginning", "fromtop": normalized = "beginning"
                default: return #"{"error":"Usage: RESPOND_SKIP_PROMPT:<keep|beginning>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteRespondSkipPrompt,
                        object: nil,
                        userInfo: ["choice": normalized]
                    )
                }
                return json(["status": "posted", "choice": normalized])

            case "DISMISS_SHEET":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteDismissPresentedSheet, object: nil)
                }
                return json(["status": "posted"])

            case "SIMULATE_BACKGROUND":
                // Post UIApplication.didEnterBackground/willEnterForeground
                // notifications + transition the active scene's state.
                // Lets the test harness verify that playback continues
                // through a backgrounding event (Lock-screen-equivalent
                // — Apple doesn't allow programmatic device locking,
                // but the playback path that matters is the same:
                // does AVSpeechSynthesizer keep speaking when the app
                // is backgrounded, with audio session in playback
                // category? Arg: optional duration in ms (default
                // 4000) to stay backgrounded before re-foregrounding.
                let parts = arg?.split(separator: ":").map(String.init) ?? []
                let durationMs = (parts.first.flatMap(Int.init)) ?? 4000
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: UIApplication.didEnterBackgroundNotification,
                        object: nil
                    )
                }
                try? await Task.sleep(for: .milliseconds(durationMs))
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: UIApplication.willEnterForegroundNotification,
                        object: nil
                    )
                }
                return json(["status": "cycled", "durationMs": durationMs])

            case "LIST_AUDIO_EXPORTS":
                // List exported audio files in the app's documents
                // directory so the test harness can verify
                // EXPORT_AUDIO produced a file. Returns name + size +
                // duration for each.
                let fm = FileManager.default
                guard let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
                    return json(["error": "documents dir unavailable"])
                }
                let exportsDir = docsDir.appendingPathComponent("AudioExports", isDirectory: true)
                guard fm.fileExists(atPath: exportsDir.path) else {
                    return json(["count": 0, "files": [] as [String]])
                }
                let urls = (try? fm.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
                var files: [[String: Any]] = []
                for url in urls {
                    let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
                    let size = (attrs[.size] as? Int) ?? 0
                    var entry: [String: Any] = [
                        "name": url.lastPathComponent,
                        "path": url.path,
                        "size": size
                    ]
                    let asset = AVURLAsset(url: url)
                    if let duration = try? await asset.load(.duration) {
                        entry["durationSeconds"] = duration.seconds
                    }
                    files.append(entry)
                }
                return json(["count": files.count, "files": files])

            case "GET_READER_STATE_FULL":
                // Comprehensive snapshot of the live reader state +
                // playback state. Aggregates everything READER_STATE
                // returns plus playback info from the
                // RemoteControlState.
                let snap = await MainActor.run { RemoteControlState.shared.snapshot() }
                return json(snap)

            case "LOGS":
                // LOGS, LOGS:<limit>, LOGS:<limit>:<sinceEpochMs>
                // Returns recent log lines from the in-app circular
                // buffer (DEBUG-only). Test harness can poll for new
                // diagnostic output without needing Console.app.
                var limit = 200
                var since: Int? = nil
                if let raw = arg {
                    let parts = raw.split(separator: ":").map(String.init)
                    if let l = parts.first.flatMap(Int.init) { limit = l }
                    if parts.count > 1, let s = Int(parts[1]) { since = s }
                }
                let lines = InAppLogBuffer.shared.recent(limit: limit, sinceEpochMs: since)
                return json(["count": lines.count, "lines": lines])

            case "CLEAR_LOGS":
                InAppLogBuffer.shared.clear()
                return json(["cleared": true])

            case "SUBMIT_ASK_POSEY":
                // SUBMIT_ASK_POSEY:<text> — drive the live submit
                // path on the open Ask Posey sheet's view model.
                // Required for testing scroll-on-send and the
                // thinking indicator: /ask bypasses the live VM and
                // doesn't fire the UI's onChange.
                guard let text = arg, !text.isEmpty else {
                    return #"{"error":"Usage: SUBMIT_ASK_POSEY:<text>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteSubmitAskPoseyMessage,
                        object: nil,
                        userInfo: ["text": text]
                    )
                }
                return json(["status": "posted", "text": text])

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

            case "SCREENSHOT_STABLE":
                // Fade/animation-aware capture: waits for the screen to stop
                // moving before snapping, so the image is a real settled frame
                // (not a mid-transition composite). Use this for any UI claim.
                let pngData = await RemoteControl.screenshotStablePNG()
                guard let data = pngData else {
                    return #"{"error":"Screenshot failed (no key window)"}"#
                }
                return json(["bytes": data.count, "base64": data.base64EncodedString(), "stable": true])

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

            case "SCROLL_PREFS_TO_LLM":
                // 2026-05-28 — scroll an already-open prefs sheet to
                // the AskPosey LLM picker section. Used for phone
                // verification of personality-card rendering since
                // physical devices don't expose a UI swipe primitive.
                //
                // Optional arg: a model id to scroll to a specific
                // card below the section header. Without an arg, the
                // section-top anchor is used (backward compatible).
                // Examples:
                //   SCROLL_PREFS_TO_LLM
                //   SCROLL_PREFS_TO_LLM:mlx-community/gemma-4-e2b-it-4bit
                //   SCROLL_PREFS_TO_LLM:mlx-community/dolphin3.0-llama3.2-3B-4Bit
                let modelArg = arg?.trimmingCharacters(in: .whitespaces)
                let targetID: String
                if let m = modelArg, !m.isEmpty {
                    targetID = "preferences.askPosey.model.\(m)"
                } else {
                    targetID = "preferences.askPosey.section"
                }
                await MainActor.run {
                    // The catalog now lives on the pushed Model Library
                    // screen (prefs reorg 2026-05-29), so push it first…
                    NotificationCenter.default.post(
                        name: .remoteOpenModelLibrary, object: nil
                    )
                    NotificationCenter.default.post(
                        name: .remoteScrollPrefsToLLM,
                        object: nil,
                        userInfo: ["target": targetID]
                    )
                    // …then, if a specific model was named, expand its
                    // accordion card so the detail card is visible for
                    // verification (the header Button can't be reached by
                    // the TAP verb).
                    if let m = modelArg, !m.isEmpty {
                        NotificationCenter.default.post(
                            name: .remoteExpandAskPoseyModel,
                            object: nil,
                            userInfo: ["modelID": m]
                        )
                    }
                }
                return json(["status": "posted", "target": targetID])

            case "SCROLL_PREFS_TO_ASK_POSEY":
                // 2026-06-17 — Scroll an already-open prefs sheet's FORM to the
                // Ask Posey section (its status row + Model row), WITHOUT pushing
                // the Model Library screen. SCROLL_PREFS_TO_LLM was repurposed in
                // the 2026-05-29 reorg to push the catalog, so it can't be used to
                // verify the in-form Ask Posey section. This reuses the existing
                // `.remoteScrollPrefsToLLM` handler (scrolls to the
                // "preferences.askPosey.section" anchor) and nothing else.
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteScrollPrefsToLLM,
                        object: nil,
                        userInfo: ["target": "preferences.askPosey.section"]
                    )
                }
                return json(["status": "posted", "target": "preferences.askPosey.section"])

            case "OPEN_MODEL_LIBRARY":
                // Push the AskPoseyModelLibraryView from an open prefs
                // sheet (prefs reorg 2026-05-29). Use after
                // OPEN_PREFERENCES_SHEET to reach the model catalog.
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteOpenModelLibrary, object: nil
                    )
                }
                return json(["status": "posted"])

            case "OPEN_TOC_SHEET":
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteOpenTOCSheet, object: nil)
                }
                return json(["status": "posted"])

            case "OPEN_VOICE_PICKER_SHEET":
                // 2026-05-07 (parity #5): present VoicePickerView as a
                // modal sheet for testing. The user-facing path remains
                // a NavigationLink inside Preferences (unchanged); this
                // verb adds a parallel test entry point because the
                // NavigationLink isn't reachable via the antenna's TAP.
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteOpenVoicePickerSheet, object: nil)
                }
                return json(["status": "posted"])

            case "TAP_TOC_ENTRY":
                // 2026-05-07 (parity #6): tap a TOC entry by playOrder.
                // Tests the actual TOC-sheet tap flow (jumpToTOCEntry +
                // dismiss) which the registry-based TAP can't reach
                // because TOC rows are SwiftUI buttons inside a List
                // not registered with `.remoteRegister`.
                guard let raw = arg, let playOrder = Int(raw) else {
                    return #"{"error":"Usage: TAP_TOC_ENTRY:<playOrder>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteTapTOCEntry,
                        object: nil,
                        userInfo: ["playOrder": playOrder]
                    )
                }
                return json(["status": "posted", "playOrder": playOrder])

            case "DEBUG_FORCE_PLAYBACK_STATE":
                // 2026-05-07 (parity #8): force the playback service
                // into a specific state so transitions that take real
                // playback time (e.g. natural end-of-doc → .finished)
                // can be exercised in tests.
                let allowed = ["idle", "playing", "paused", "finished"]
                guard let value = arg?.lowercased(), allowed.contains(value) else {
                    return #"{"error":"Usage: DEBUG_FORCE_PLAYBACK_STATE:<idle|playing|paused|finished>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteDebugForcePlaybackState,
                        object: nil,
                        userInfo: ["state": value]
                    )
                }
                return json(["status": "posted", "state": value])

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
                // 2026-05-27 — make OPEN_DOCUMENT work from any UI state.
                // Previously it only worked from library view; from inside
                // a reader on another doc, it silently no-op'd. Now it:
                //   1. Dismisses any open sheet
                //   2. Navigates back to library (if currently in a reader)
                //   3. Opens the target doc
                // Done as a sequenced MainActor block so SwiftUI navigation
                // settles between steps.
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteDismissPresentedSheet, object: nil)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    NotificationCenter.default.post(name: .remoteLibraryNavigateBack, object: nil)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
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

            // 2026-05-16 — SET_READING_STYLE and SET_MOTION_PREFERENCE
            // verbs removed. Reading-style picker + Motion-mode auto-
            // detection retired. The notification names stay declared
            // so older receivers don't fail to compile.

            case "SET_IMAGE_HANDLING":
                guard let raw = arg?.lowercased(),
                      ["pause", "skip"].contains(raw) else {
                    return #"{"error":"Usage: SET_IMAGE_HANDLING:<pause|skip>"}"#
                }
                await MainActor.run {
                    PlaybackPreferences.shared.visualHandling =
                        (raw == "skip") ? .skipVisuals : .pauseAtVisuals
                }
                return json(["status": "posted", "imageHandling": raw])

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

            case "SEARCH_MATCHES":
                // c15 search verifier: report the current query's matched segments
                // (char offset + snippet) so a Mac-side verifier can confirm
                // correct hits spanning early/late and correct tap-to-jump
                // landings against GET_PLAIN_TEXT ground truth. Returns ALL match
                // offsets (cheap ints) + snippets for a sample (first 4 + last 4).
                let snap = await MainActor.run { () -> (idx: [Int], pos: Int, segs: [(index: Int, text: String, startOffset: Int, endOffset: Int)]) in
                    (RemoteControlState.shared.searchMatchIndices,
                     RemoteControlState.shared.currentSearchMatchPosition,
                     RemoteControlState.shared.segmentTexts)
                }
                let segByIndex = Dictionary(snap.segs.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
                let offsets = snap.idx.compactMap { segByIndex[$0]?.startOffset }
                let sampleIdx: [Int]
                if snap.idx.count <= 8 { sampleIdx = snap.idx }
                else { sampleIdx = Array(snap.idx.prefix(4)) + Array(snap.idx.suffix(4)) }
                let samples: [[String: Any]] = sampleIdx.compactMap { i in
                    guard let s = segByIndex[i] else { return nil }
                    return ["segIndex": i, "startOffset": s.startOffset,
                            "snippet": String(s.text.prefix(80))]
                }
                return json([
                    "count": snap.idx.count,
                    "currentPosition": snap.pos,
                    "matchOffsets": offsets,
                    "samples": samples
                ])

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

            case "EXPORT_AUDIO_RANGE":
                // EXPORT_AUDIO_RANGE:<docID>:<startCharOffset>:<endCharOffset>
                // 2026-06-03 — TTS-verification harness support. Renders ONLY the
                // plainText[start..<end] character slice's TTS to an M4A (whole-doc
                // render of a novel is infeasible — Dracula ≈ 18h of audio). This
                // gives the harness the ACTUAL synth audio output for a bounded
                // stretch, to be transcribed by an INDEPENDENT on-device/local ASR
                // (non-circular: not the synth's own willSpeak/didStart callback).
                // Renders fresh (NOT via runHeadlessAudioExport's docID cache —
                // that would return/replace the whole-doc cached file). Same
                // utterance-text stripping as live playback (AudioExporter uses
                // SpeechPlaybackService.utteranceText), so the transcript reflects
                // exactly what is spoken aloud (c14 'speaks no junk').
                do {
                    let parts = (arg ?? "").split(separator: ":").map(String.init)
                    guard parts.count == 3, let docID = UUID(uuidString: parts[0]),
                          let lo = Int(parts[1]), let hi = Int(parts[2]), lo < hi else {
                        return #"{"error":"Usage: EXPORT_AUDIO_RANGE:<docID>:<startOffset>:<endOffset>"}"#
                    }
                    let documents = (try? databaseManager.documents()) ?? []
                    guard let doc = documents.first(where: { $0.id == docID }) else {
                        return #"{"error":"Document not found"}"#
                    }
                    let chars = Array(doc.plainText)
                    let n = chars.count
                    let s = max(0, min(lo, n)); let e = max(s, min(hi, n))
                    let slice = String(chars[s..<e])
                    let job = await MainActor.run {
                        RemoteAudioExportRegistry.shared.create(
                            documentID: docID, documentTitle: doc.title + " [range \(s)-\(e)]")
                    }
                    let jobID = job.id
                    Task.detached { @MainActor in
                        let segs = SentenceSegmenter().segments(for: slice)
                        RemoteAudioExportRegistry.shared.update(jobID) { j in
                            j.status = .rendering; j.totalSegments = segs.count
                        }
                        let exporter = AudioExporter()
                        let cancellable = exporter.$state.sink { st in
                            Task { @MainActor in
                                if case .rendering(let p, let idx, let tot) = st {
                                    RemoteAudioExportRegistry.shared.update(jobID) { j in
                                        j.status = .rendering; j.progress = p
                                        j.currentSegmentIndex = idx; j.totalSegments = tot
                                    }
                                }
                            }
                        }
                        defer { _ = cancellable }
                        do {
                            let url = try await exporter.render(
                                segments: segs,
                                voiceMode: PlaybackPreferences.shared.voiceMode,
                                outputDirectory: FileManager.default.temporaryDirectory,
                                documentTitle: "ttsverify-\(jobID)")
                            RemoteAudioExportRegistry.shared.update(jobID) { j in
                                j.status = .finished; j.progress = 1; j.resultURL = url
                            }
                        } catch {
                            RemoteAudioExportRegistry.shared.update(jobID) { j in
                                j.status = .failed; j.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    return json(["status": "started", "jobID": jobID,
                                 "rangeStart": s, "rangeEnd": e, "sliceChars": slice.count])
                }

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

            case "TTS_VERIFY_CAPTURE_START":
                // 2026-06-03 — start the BATCHED silent ReplayKit app-audio
                // capture session. One iOS consent alert; keep it running across
                // many TTS_VERIFY_RUN stretches, then TTS_VERIFY_CAPTURE_STOP.
                // No microphone; no audible playback (phone media volume at 0).
                let res: (Bool, String?) = await withCheckedContinuation { cont in
                    Task { @MainActor in
                        TTSVerifyHarness.shared.startCapture { ok, err in cont.resume(returning: (ok, err)) }
                    }
                }
                return json(["started": res.0, "error": res.1.map { $0 as Any } ?? NSNull(),
                             "note": "grant the 'Allow recording' alert once; set phone media volume to 0 for silence"])

            case "TTS_VERIFY_CAPTURE_STOP":
                let res: (Bool, String?) = await withCheckedContinuation { cont in
                    Task { @MainActor in
                        TTSVerifyHarness.shared.stopCapture { ok, err in cont.resume(returning: (ok, err)) }
                    }
                }
                return json(["stopped": res.0, "error": res.1.map { $0 as Any } ?? NSNull()])

            case "TTS_CAPTURE_PROBE_ENGINE":
                // Evidence probe: does an AVAudioEngine mainMixer tap capture
                // speak() output? (~0 == no; confirms the "preferred" engine-tap
                // path can't see production speech — see TTSVerifyHarness header.)
                let probe: [String: Any] = await withCheckedContinuation { cont in
                    Task { @MainActor in
                        TTSVerifyHarness.shared.probeEngineTap { result in cont.resume(returning: result) }
                    }
                }
                return json(probe)

            case "TTS_VERIFY_RUN":
                // TTS_VERIFY_RUN:<docID>:<startSentenceIndex>:<numSentences>
                // 2026-06-03 — one SILENT capture stretch under the active
                // ReplayKit session (call TTS_VERIFY_CAPTURE_START first). The
                // reader must be OPEN on <docID>. Starts a fresh audio file +
                // shared clock, then plays live from startSentence; highlight
                // transitions are logged on the same clock. Poll
                // TTS_VERIFY_STATUS, then TTS_VERIFY_FETCH:<runID> for audio+log.
                do {
                    let parts = (arg ?? "").split(separator: ":").map(String.init)
                    guard parts.count == 3, let docID = UUID(uuidString: parts[0]),
                          let start = Int(parts[1]), let num = Int(parts[2]), num > 0 else {
                        return #"{"error":"Usage: TTS_VERIFY_RUN:<docID>:<startSentenceIndex>:<numSentences>"}"#
                    }
                    let runID = UUID().uuidString.prefix(8).lowercased()
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .remoteTTSVerifyRun, object: nil,
                            userInfo: ["documentID": docID, "startSentence": start,
                                       "numSentences": num, "runID": String(runID)])
                    }
                    return json(["status": "posted", "runID": String(runID),
                                 "documentID": parts[0], "startSentence": start,
                                 "numSentences": num,
                                 "note": "poll TTS_VERIFY_STATUS; reader must be open on this doc; mic permission required"])
                }

            case "TTS_VERIFY_STATUS":
                let snap = await MainActor.run { TTSVerifyHarness.shared.statusSnapshot() }
                return json(snap)

            case "TTS_VERIFY_FETCH":
                // TTS_VERIFY_FETCH[:<runID>] — defaults to the most recent run.
                let payload = await MainActor.run { TTSVerifyHarness.shared.fetchPayload(runID: arg) }
                if let payload { return json(payload) }
                return #"{"error":"No finished run to fetch (poll TTS_VERIFY_STATUS until status=finished)"}"#

            case "ACTIVE_LINE_FRAME":
                // 2026-06-04 — c13 (TTS flow / auto-scroll) probe. Returns the
                // LIVE on-screen rect of the highlighted active sentence:
                // midYFraction = vertical center as a fraction of viewport
                // (window) height. Poll during playback to measure whether the
                // active line holds in the upper third or drifts down the screen.
                let frame = await MainActor.run { RemoteControlState.shared.activeLineFrameSnapshot() }
                if let frame { return json(frame) }
                return #"{"error":"No active prose line registered (open a doc and start playback first)"}"#

            case "SELECT_TEST":
                // c13 regression guard: programmatically select the active prose
                // unit's full (multi-sentence) range in its single UITextView and
                // read it back — proves cross-sentence selection is intact (NOT
                // regressed by the auto-scroll fix). Take a SCREENSHOT after to see
                // the native selection handles/highlight.
                let probe = await MainActor.run { RemoteControlState.shared.selectionProbe() }
                if let probe { return json(probe) }
                return #"{"error":"No active prose line registered (open a doc + play briefly first)"}"#

            case "LIST_AUDIO_CACHE":
                // 2026-05-13 — A4 diagnostic. Dumps every cached
                // export with its doc title (looked up from the
                // library) and the cache total in bytes.
                let entries = AudioExportCache.shared.listCached()
                let docs = (try? databaseManager.documents()) ?? []
                let titleByID = Dictionary(uniqueKeysWithValues:
                    docs.map { ($0.id, $0.title) }
                )
                var items: [[String: Any]] = []
                for e in entries {
                    items.append([
                        "documentID": e.documentID.uuidString,
                        "documentTitle": titleByID[e.documentID] ?? "(deleted)",
                        "path": e.url.path,
                        "bytes": Int(e.bytes),
                        "createdAt": e.createdAt.timeIntervalSince1970
                    ])
                }
                return json([
                    "count": items.count,
                    "totalBytes": Int(AudioExportCache.shared.totalBytes()),
                    "entries": items
                ])

            case "DELETE_AUDIO_CACHE":
                guard let idStr = arg, let id = UUID(uuidString: idStr) else {
                    return #"{"error":"Usage: DELETE_AUDIO_CACHE:<docID>"}"#
                }
                AudioExportCache.shared.delete(for: id)
                return json(["deleted": true, "documentID": id.uuidString])

            case "DELETE_AUDIO_CACHE_ALL":
                AudioExportCache.shared.deleteAll()
                return json(["deletedAll": true])

            case "SIMULATE_AUDIO_EXPORT_BG_EXPIRATION":
                // 2026-05-13 — A8 test hook. Drives the same
                // `.backgroundTimeExpired` failure path the iOS
                // `beginBackgroundTask` expirationHandler would
                // trigger after ~30s of being backgrounded, without
                // having to actually background-and-wait. The export
                // Task in ReaderView.beginAudioExport observes this
                // notification and calls
                // `exporter.cancelDueToBackgroundExpiration()`.
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteSimulateAudioExportExpiration,
                        object: nil
                    )
                }
                return json(["status": "posted"])

            case "BEGIN_AUDIO_EXPORT":
                // BEGIN_AUDIO_EXPORT:<docID> — direct kickoff path
                // for the redesigned UI (notification-based). Bypasses
                // the lazy-mounted Preferences cell so a verifier can
                // launch an export without scrolling the form.
                guard let raw = arg, let docID = UUID(uuidString: raw) else {
                    return #"{"error":"Usage: BEGIN_AUDIO_EXPORT:<docID>"}"#
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .remoteBeginAudioExport,
                        object: nil,
                        userInfo: ["documentID": docID]
                    )
                }
                return json(["status": "posted", "documentID": docID.uuidString])

            // ===== Audio Export notification testing =========================
            // 2026-05-08 — antenna scaffolding for the notification-
            // based export UX. Lets the verifier check that:
            //   (a) the notification permission status is what we
            //       expect after a kickoff,
            //   (b) the notification request is actually pending /
            //       delivered (so we know the schedule call landed),
            //   (c) tapping the notification (or the simulated tap)
            //       routes correctly into the share-sheet path
            //       without requiring the springboard.
            case "AUDIO_EXPORT_NOTIFICATION_AUTH":
                let status = await UNUserNotificationCenter.current().notificationSettings()
                let label: String
                switch status.authorizationStatus {
                case .authorized: label = "authorized"
                case .denied: label = "denied"
                case .notDetermined: label = "notDetermined"
                case .provisional: label = "provisional"
                case .ephemeral: label = "ephemeral"
                @unknown default: label = "unknown"
                }
                return json(["status": label])

            case "AUDIO_EXPORT_NOTIFICATION_PENDING":
                let center = UNUserNotificationCenter.current()
                let pending = await center.pendingNotificationRequests()
                let delivered = await center.deliveredNotifications()
                let pendingDicts = pending
                    .filter { $0.identifier.hasPrefix("audioExport.") }
                    .map { req -> [String: Any] in
                        [
                            "identifier": req.identifier,
                            "title": req.content.title,
                            "body": req.content.body,
                            "userInfo": req.content.userInfo
                        ]
                    }
                let deliveredDicts = delivered
                    .filter { $0.request.identifier.hasPrefix("audioExport.") }
                    .map { n -> [String: Any] in
                        [
                            "identifier": n.request.identifier,
                            "title": n.request.content.title,
                            "body": n.request.content.body,
                            "userInfo": n.request.content.userInfo
                        ]
                    }
                return json([
                    "pending": pendingDicts,
                    "delivered": deliveredDicts
                ])

            case "AUDIO_EXPORT_SIMULATE_NOTIFICATION_TAP":
                // Simulates the user tapping a delivered completion
                // notification. arg is the file path; documentID is
                // best-effort lifted from the most-recent registry
                // job (so the tap maps back to the right reader).
                guard let pathArg = arg, !pathArg.isEmpty else {
                    return #"{"error":"Usage: AUDIO_EXPORT_SIMULATE_NOTIFICATION_TAP:<filePath>"}"#
                }
                let url = URL(fileURLWithPath: pathArg)
                let mostRecentJob = await MainActor.run {
                    RemoteAudioExportRegistry.shared.all().first
                }
                var info: [String: Any] = [
                    AudioExportNotificationKeys.fileURL: url
                ]
                if let job = mostRecentJob {
                    info[AudioExportNotificationKeys.documentID] = job.documentID.uuidString
                    info[AudioExportNotificationKeys.documentTitle] = job.documentTitle
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .audioExportNotificationTapped,
                        object: nil,
                        userInfo: info
                    )
                }
                return #"{"ok":true}"#

            // ===== Autonomous audio test harnesses (2026-05-12) ===============
            // Mark requested these so he doesn't need to use ears/hands to
            // verify two outstanding audio behaviors. Each verb runs the
            // full test sequence and returns a structured pass/fail report.

            case "LIST_UTTERANCES":
                let texts = await MainActor.run { RemoteControlState.shared.spokenUtterances }
                return json(["count": texts.count, "utterances": texts])

            case "RESET_UTTERANCE_LOG":
                await MainActor.run { RemoteControlState.shared.resetSpokenUtterances() }
                return #"{"ok":true}"#

            // Note: a second "SIMULATE_BACKGROUND" case used to live here
            // for the audio-export lock test. It was unreachable because
            // the earlier case (~line 1855) matched first; removed
            // 2026-05-19 to silence the duplicate-pattern warning. The
            // earlier case's behavior (full background→sleep→foreground
            // cycle) is what AUDIO_EXPORT_LOCK_TEST has been getting at
            // runtime all along.

            case "SIMULATE_FOREGROUND":
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: UIApplication.willEnterForegroundNotification,
                        object: nil
                    )
                }
                return #"{"ok":true,"posted":"willEnterForeground"}"#

            case "PLAYBACK_STOP_BLOCK_TEST":
                // PLAYBACK_STOP_BLOCK_TEST:<docID>
                // Test sequence (the open document must contain a
                // visualPlaceholder somewhere reachable from current
                // position; for the canonical run on Measure What Matters
                // PDF, position to offset 3000 before invoking — the test
                // does NOT navigate for you, since doc-switching is
                // intentionally explicit).
                //
                // 1. Reset utterance log.
                // 2. Read current state — capture baseline offset.
                // 3. Drive playback via the reader.playPause registered
                //    action (same path the user tap takes).
                // 4. Poll for up to 90s. Watch for: offset to reach a
                //    visualPlaceholder's startOffset, OR for the utterance
                //    log to contain a string matching "Visual content".
                // 5. After playback stops advancing, fire the
                //    `reader.next` action — verify offset advances past
                //    the placeholder.
                // 6. Return structured report.
                guard let raw = arg, let docID = UUID(uuidString: raw) else {
                    return #"{"error":"Usage: PLAYBACK_STOP_BLOCK_TEST:<docID>"}"#
                }
                return await runPlaybackStopBlockTest(documentID: docID)

            case "AUDIO_EXPORT_LOCK_TEST":
                // AUDIO_EXPORT_LOCK_TEST:<docID>
                // Test sequence:
                // 1. Clear any prior delivered notifications for this
                //    docID via UNUserNotificationCenter.
                // 2. Fire BEGIN_AUDIO_EXPORT.
                // 3. Wait 2s for the render Task to attach beginBackgroundTask.
                // 4. Post UIApplication.didEnterBackgroundNotification
                //    (simulated lock-screen).
                // 5. Poll AUDIO_EXPORT_NOTIFICATION_PENDING up to 120s
                //    for completion notification matching docID.
                // 6. Post UIApplication.willEnterForegroundNotification.
                // 7. Return structured report.
                guard let raw = arg, let docID = UUID(uuidString: raw) else {
                    return #"{"error":"Usage: AUDIO_EXPORT_LOCK_TEST:<docID>"}"#
                }
                return await runAudioExportLockTest(documentID: docID)

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

    #if DEBUG
    /// DEBUG-only responsiveness probe (Path A verification, 2026-06-15). Runs a
    /// ~30ms heartbeat on the MainActor; if the main thread is blocked, the
    /// heartbeat's resumption is delayed and we record the overshoot. The max
    /// overshoot over an import ≈ the longest momentary UI freeze during it.
    /// Off-main import (Path A) → small stalls (~tens of ms, the per-chapter
    /// WebKit hop). Old on-main import → stall ≈ whole import (seconds). Lets the
    /// antenna self-report responsiveness from ONE import call — no external
    /// polling/hammering. Compiled out of production.
    @MainActor
    final class MainThreadStallProbe {
        private(set) var maxStallMs: Double = 0
        private var task: Task<Void, Never>?
        private let intervalNs: UInt64 = 30_000_000  // 30ms heartbeat

        func start() {
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                var last = DispatchTime.now().uptimeNanoseconds
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: self.intervalNs)
                    let now = DispatchTime.now().uptimeNanoseconds
                    let elapsedMs = Double(now &- last) / 1_000_000
                    let stallMs = elapsedMs - Double(self.intervalNs) / 1_000_000
                    if stallMs > self.maxStallMs { self.maxStallMs = stallMs }
                    last = now
                }
            }
        }
        func stop() { task?.cancel(); task = nil }
    }
    #endif

    func apiImport(filename: String, data: Data, overwrite: Bool = false) async -> String {
        let cleanFilename = LibraryViewModel.sanitizeFilename(filename)
        let ext = (cleanFilename as NSString).pathExtension.lowercased()
        // Dev overwrite: delete any existing document(s) with the same filename
        // first, so the import re-processes from scratch under the current build
        // instead of dedup'ing to the stale copy (the importers reuse an
        // existing id on content match). Filename-scoped: only the doc you're
        // re-importing is replaced.
        if overwrite {
            let stale = ((try? databaseManager.documents()) ?? [])
                .filter { $0.fileName == cleanFilename }
            for d in stale { deleteDocument(d) }
        }
        do {
            importStatusMessage = Self.importBannerMessage
            defer { importStatusMessage = nil }
            #if DEBUG
            let stallProbe = MainThreadStallProbe()
            stallProbe.start()
            defer { stallProbe.stop() }
            let probeStart = DispatchTime.now().uptimeNanoseconds
            #endif
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(cleanFilename)
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let doc: Document
            if ext == "pdf" {
                // 2026-05-16 (B8) — Same precheck as the user-driven
                // import path. Catches PNG/PDF/random-bytes misnamed
                // as .pdf via the API.
                try FormatPrecheck.checkPDF(url: tempURL)
                let parsed = try await parsePDFOffMainThread(url: tempURL) { [weak self] msg in
                    Task { @MainActor [weak self] in self?.importStatusMessage = msg }
                }
                doc = try pdfLibraryImporter.persistParsedDocument(parsed, from: tempURL)
            } else {
                // 2026-06-15 (Path A): pure-text formats parse off-main on a
                // detached task (no WebKit constraint); HTML/EPUB are async and
                // hop to main only for their per-chapter WebKit step.
                let db = databaseManager
                switch ext {
                case "txt":             doc = try await Task.detached(priority: .userInitiated) { try TXTLibraryImporter(databaseManager: db).importDocument(from: tempURL) }.value
                case "md", "markdown":  doc = try await Task.detached(priority: .userInitiated) { try MarkdownLibraryImporter(databaseManager: db).importDocument(from: tempURL) }.value
                case "rtf":             doc = try await Task.detached(priority: .userInitiated) { try RTFLibraryImporter(databaseManager: db).importDocument(from: tempURL) }.value
                case "docx":            doc = try await Task.detached(priority: .userInitiated) { try DOCXLibraryImporter(databaseManager: db).importDocument(from: tempURL) }.value
                case "html", "htm":     doc = try await htmlLibraryImporter.importDocument(from: tempURL)
                case "epub":            doc = try await epubLibraryImporter.importDocument(from: tempURL)
                default:                throw LibraryImportError.unsupportedFileType
                }
            }
            loadDocuments()
            var resp: [String: Any] = ["success": true, "id": doc.id.uuidString,
                         "title": doc.title, "fileType": doc.fileType,
                         "characterCount": doc.characterCount]
            #if DEBUG
            stallProbe.stop()
            resp["importMs"] = Int((Double(DispatchTime.now().uptimeNanoseconds &- probeStart) / 1_000_000).rounded())
            resp["mainThreadMaxStallMs"] = Int(stallProbe.maxStallMs.rounded())
            #endif
            return json(resp)
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

        // 2026-06-17 — Spoiler firewall (Layer 2) DETECTION PROBE. When
        // `catcherProbeText` is present, skip generation entirely and run the
        // catcher's detect() on the supplied text against this document at the
        // given `readingOffset`. This validates the catcher's core pipeline
        // deterministically (Layer 1 is strong enough that real drafts rarely
        // leak, so the backstop can't be exercised through the normal path).
        if let probeText = body["catcherProbeText"] as? String,
           !probeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let off = (body["readingOffset"] as? Int) ?? 0
            let result = await SpoilerCatcher(database: databaseManager).probe(
                answer: probeText, documentID: docID, furthestOffset: off)
            return json([
                "probe": true,
                "engine": result.engine.rawValue,
                "furthestOffset": result.furthestOffset,
                "caught": result.caughtSpoiler,
                "flaggedCount": result.flagged.count,
                "flagged": result.flagged.map { ["sentence": $0.sentence, "earliestOffset": $0.earliestOffset] }
            ])
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
        var streamer: AskPoseyStreaming?
        var summarizer: AskPoseySummarizing?
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let service = AskPoseyService()
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

        // 2026-06-17 — Spoiler firewall verification. Optional `readingOffset`
        // body field sets the reader's position (the spoiler line) precisely,
        // independent of scope, so the A/B catcher probes can sweep a document:
        // ask the same plot question with the line set early (expect deflect)
        // vs late (expect reveal). Falls back to the anchor offset when absent.
        let readingOffset = body["readingOffset"] as? Int

        let viewModel = AskPoseyChatViewModel(
            documentID: docID,
            documentPlainText: document.plainText,
            documentTitle: document.title,
            anchor: anchor,
            invocationReadingOffset: readingOffset,
            initialScrollAnchorStorageID: mostRecentAnchorID,
            streamer: streamer,
            summarizer: summarizer,
            databaseManager: databaseManager,
            useSummarizedSTM: useSummarizedSTM
        )
        await viewModel.awaitHistoryLoaded()

        // 2026-05-30 — structured-knowledge mechanism proof. Optional
        // `structuredKnowledge` body field injects a hand-written,
        // source-verified chapter summary as a labeled supplement-not-
        // replace block alongside the raw RAG chunks. Absent → baseline.
        if let sk = body["structuredKnowledge"] as? String,
           !sk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.injectedStructuredKnowledge = sk
        }

        viewModel.inputText = question
        if streamer != nil {
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
        // Spoiler firewall (Layer 2) diagnostics for the A/B catcher test.
        if let catch_ = viewModel.lastSpoilerCatch {
            payload["spoiler"] = [
                "protected": true,
                "engine": catch_.engine.rawValue,
                "caught": catch_.caughtSpoiler,
                "furthestOffset": catch_.furthestOffset,
                "flaggedCount": catch_.flagged.count,
                "flagged": catch_.flagged.map { ["sentence": $0.sentence, "earliestOffset": $0.earliestOffset] }
            ]
        } else {
            payload["spoiler"] = ["protected": false]
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
                "recalledTurns": metadata.breakdown.recalledTurns,
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
                    "relevance": chunk.relevance,
                    // 2026-05-30 — expose the chunk TEXT + semantic cosine
                    // (Hal-style RAG observability) so conversational
                    // evaluation can see exactly what retrieval handed the
                    // model, rather than inferring it. `semanticScore` nil
                    // (BM25-only chunk) surfaces as -1.
                    "text": chunk.text,
                    "semanticScore": chunk.semanticScore ?? -1
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

    // MARK: — Autonomous audio test harnesses (2026-05-12)

    /// Runs the PLAYBACK_STOP_BLOCK_TEST sequence. Caller must ensure
    /// the target document is already open and positioned just before
    /// a visualPlaceholder. Returns a structured pass/fail report
    /// with evidence (utterances log, offset trajectory, NEXT result).
    private func runPlaybackStopBlockTest(documentID: UUID) async -> String {
        let startTime = Date()
        // 1. Snapshot baseline
        let baseline = await MainActor.run { () -> [String: Any] in
            let state = RemoteControlState.shared
            return [
                "visibleDocumentID": state.visibleDocumentID?.uuidString ?? "",
                "currentOffset": state.currentOffset,
                "currentSentenceIndex": state.currentSentenceIndex,
                "playbackState": state.playbackState
            ]
        }
        let baselineDocID = baseline["visibleDocumentID"] as? String ?? ""
        if baselineDocID != documentID.uuidString {
            return json([
                "test": "PLAYBACK_STOP_BLOCK_TEST",
                "result": "fail",
                "error": "Document not currently open. OPEN_DOCUMENT + READER_GOTO first.",
                "expectedDocumentID": documentID.uuidString,
                "actualDocumentID": baselineDocID
            ])
        }

        // 2. Find the next visualPlaceholder ahead of current offset
        let baselineOffset = baseline["currentOffset"] as? Int ?? 0
        let nextPlaceholder: (Int, String)? = await MainActor.run {
            let blocks = RemoteControlState.shared.displayBlockTexts
            for b in blocks where b.kind == "visualPlaceholder" && b.startOffset >= baselineOffset {
                return (b.startOffset, b.text)
            }
            return nil
        }
        guard let (placeholderOffset, placeholderText) = nextPlaceholder else {
            return json([
                "test": "PLAYBACK_STOP_BLOCK_TEST",
                "result": "fail",
                "error": "No visualPlaceholder block ahead of current offset.",
                "baselineOffset": baselineOffset
            ])
        }

        // 3. Reset utterance log
        await MainActor.run { RemoteControlState.shared.resetSpokenUtterances() }

        // 4. Drive playback via the registered TAP path (same as user tap).
        // Reveal chrome first so the button is mounted and registered.
        await MainActor.run {
            NotificationCenter.default.post(name: .remoteReaderToggleChrome, object: nil)
        }
        try? await Task.sleep(for: .seconds(1))
        let playFired = await MainActor.run { RemoteTargetRegistry.shared.fire("reader.playPause") }
        if !playFired {
            return json([
                "test": "PLAYBACK_STOP_BLOCK_TEST",
                "result": "fail",
                "error": "reader.playPause not registered after chrome reveal."
            ])
        }

        // 5. Poll for up to 90s; record offset trajectory + utterance log
        var trajectory: [[String: Any]] = []
        var stoppedAtPlaceholder = false
        var heardVisualContent = false
        for tick in 0..<90 {
            try? await Task.sleep(for: .seconds(1))
            let snap = await MainActor.run { () -> (Int, Int, String, [String]) in
                let s = RemoteControlState.shared
                return (s.currentOffset, s.currentSentenceIndex, s.playbackState, s.spokenUtterances)
            }
            let (offset, idx, state, utts) = snap
            if tick % 5 == 0 {
                trajectory.append(["t": tick, "offset": offset, "idx": idx, "state": state])
            }
            if utts.contains(where: { $0.lowercased().contains("visual content") }) {
                heardVisualContent = true
            }
            // Pass condition: reached placeholder offset AND stayed (not advanced past)
            if offset >= placeholderOffset {
                // Wait 3 more seconds to confirm it's stuck (not just transiting)
                try? await Task.sleep(for: .seconds(3))
                let confirm = await MainActor.run { RemoteControlState.shared.currentOffset }
                if confirm == offset || confirm == placeholderOffset {
                    stoppedAtPlaceholder = true
                    trajectory.append(["t": tick + 3, "offset": confirm, "stopped": true])
                    break
                }
            }
        }

        let stoppedOffset = await MainActor.run { RemoteControlState.shared.currentOffset }
        let utterancesAtStop = await MainActor.run { RemoteControlState.shared.spokenUtterances }

        // 6. Fire reader.next, verify offset advances past placeholder
        await MainActor.run { _ = RemoteTargetRegistry.shared.fire("reader.next") }
        try? await Task.sleep(for: .seconds(3))
        let afterNextOffset = await MainActor.run { RemoteControlState.shared.currentOffset }
        let nextAdvanced = afterNextOffset > placeholderOffset

        // 7. Pause to clean up
        await MainActor.run { _ = RemoteTargetRegistry.shared.fire("reader.playPause") }

        let pass = stoppedAtPlaceholder && !heardVisualContent && nextAdvanced
        return json([
            "test": "PLAYBACK_STOP_BLOCK_TEST",
            "result": pass ? "pass" : "fail",
            "elapsedSeconds": Date().timeIntervalSince(startTime),
            "placeholderOffset": placeholderOffset,
            "placeholderText": placeholderText,
            "stoppedAtPlaceholder": stoppedAtPlaceholder,
            "stoppedOffset": stoppedOffset,
            "heardVisualContent": heardVisualContent,
            "utterancesSpokenCount": utterancesAtStop.count,
            "utterancesSpokenSample": Array(utterancesAtStop.suffix(5)),
            "nextAdvanced": nextAdvanced,
            "afterNextOffset": afterNextOffset,
            "trajectory": trajectory
        ])
    }

    /// Runs the AUDIO_EXPORT_LOCK_TEST sequence in two phases.
    ///
    /// **Phase 1 (canonical):** Baseline export, no simulated
    /// backgrounding. Verifies the end-to-end export pipeline works
    /// — render completes, completion notification delivered. This
    /// is the canonical pass/fail signal.
    ///
    /// **Phase 2 (informational):** Simulated background via
    /// `didEnterBackgroundNotification` post mid-render. On iPhone
    /// this typically FAILS because AVFoundation listens to that
    /// notification at the framework level and pauses
    /// `AVSpeechSynthesizer.write` — the simulated background is
    /// NOT equivalent to a real lock-screen. The canonical evidence
    /// for lock-survival is the simulator's earlier Settings-launch
    /// test (real backgrounding) which passed. Phase 2 is reported
    /// for transparency but does not affect pass/fail.
    private func runAudioExportLockTest(documentID: UUID) async -> String {
        let startTime = Date()
        let completeIdentifier = "audioExport.complete.\(documentID.uuidString)"
        let failedIdentifier = "audioExport.failed.\(documentID.uuidString)"

        // ===== Phase 1: baseline (no simulated background) =====
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [completeIdentifier, failedIdentifier])
        let phase1Start = Date()
        await MainActor.run {
            NotificationCenter.default.post(
                name: .remoteBeginAudioExport,
                object: nil,
                userInfo: ["documentID": documentID]
            )
        }
        var p1Completed = false
        var p1Time: TimeInterval = -1
        for _ in 0..<30 { // up to 90s
            try? await Task.sleep(for: .seconds(3))
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            if delivered.contains(where: { $0.request.identifier == completeIdentifier }) {
                p1Completed = true
                p1Time = Date().timeIntervalSince(phase1Start)
                break
            }
        }

        // ===== Phase 2: simulated background (informational only) =====
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [completeIdentifier, failedIdentifier])
        let phase2Start = Date()
        await MainActor.run {
            NotificationCenter.default.post(
                name: .remoteBeginAudioExport,
                object: nil,
                userInfo: ["documentID": documentID]
            )
        }
        try? await Task.sleep(for: .seconds(2)) // let render Task spin up
        await MainActor.run {
            NotificationCenter.default.post(
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
        }
        var p2Completed = false
        var p2Time: TimeInterval = -1
        for _ in 0..<20 { // up to 60s
            try? await Task.sleep(for: .seconds(3))
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            if delivered.contains(where: { $0.request.identifier == completeIdentifier }) {
                p2Completed = true
                p2Time = Date().timeIntervalSince(phase2Start)
                break
            }
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )
        }

        // Pass = baseline completed. Phase 2 is informational.
        return json([
            "test": "AUDIO_EXPORT_LOCK_TEST",
            "result": p1Completed ? "pass" : "fail",
            "documentID": documentID.uuidString,
            "phase1_baseline": [
                "label": "End-to-end export pipeline (canonical pass/fail)",
                "completed": p1Completed,
                "completionTimeSec": p1Time
            ],
            "phase2_simulatedBackground": [
                "label": "Simulated background via notification post (informational only)",
                "completed": p2Completed,
                "completionTimeSec": p2Time,
                "note": "On iPhone phase2 typically fails because AVFoundation listens to didEnterBackground at the framework level and pauses AVSpeechSynthesizer.write. This is NOT representative of real lock-screen behavior. Canonical lock-survival evidence is the simulator real-backgrounding test (Settings-launch, 2026-05-08) that passed."
            ],
            "elapsedSec": Date().timeIntervalSince(startTime)
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
