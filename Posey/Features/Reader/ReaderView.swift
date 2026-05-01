import AVFoundation
import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ReaderView: View {
    @StateObject private var viewModel: ReaderViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let isTestMode: Bool
    @State private var isShowingNotesSheet = false
    @State private var isShowingPreferencesSheet = false
    @State private var isShowingTOCSheet = false
    @State private var isChromeVisible = true
    @State private var chromeFadeTask: Task<Void, Never>?
    @State private var expandedImageItem: ExpandedImageItem? = nil
    private let chromeTint = Color.white.opacity(0.9)
    private let chromeSecondaryTint = Color.white.opacity(0.62)

    init(
        document: Document,
        databaseManager: DatabaseManager,
        playbackMode: AppLaunchConfiguration.PlaybackMode = .system,
        isTestMode: Bool = false,
        shouldAutoPlayOnAppear: Bool = false,
        shouldAutoCreateNoteOnAppear: Bool = false,
        shouldAutoCreateBookmarkOnAppear: Bool = false,
        automationNoteBody: String = "Automated smoke note"
    ) {
        self.isTestMode = isTestMode
        _viewModel = StateObject(
            wrappedValue: ReaderViewModel(
                document: document,
                databaseManager: databaseManager,
                playbackService: SpeechPlaybackService(
                    mode: playbackMode == .simulated ? .simulated(stepInterval: 0.15) : .system,
                    voiceMode: PlaybackPreferences.shared.voiceMode
                ),
                shouldAutoPlayOnAppear: shouldAutoPlayOnAppear,
                shouldAutoCreateNoteOnAppear: shouldAutoCreateNoteOnAppear,
                shouldAutoCreateBookmarkOnAppear: shouldAutoCreateBookmarkOnAppear,
                automationNoteBody: automationNoteBody
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.usesDisplayBlocks {
                        ForEach(viewModel.displayBlocks) { block in
                            Group {
                                if block.kind == .visualPlaceholder {
                                    visualPlaceholder(block: block)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(viewModel.displayText(for: block))
                                        .textSelection(.enabled)
                                        .font(viewModel.font(for: block))
                                        .fontWeight(viewModel.fontWeight(for: block))
                                        .foregroundStyle(viewModel.foregroundStyle(for: block))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(blockBackground(block))
                            )
                            .id(block.id)
                            .accessibilityIdentifier("reader.segment.\(block.id)")
                        }
                    } else {
                        ForEach(viewModel.segments) { segment in
                            Text(segment.text)
                                .textSelection(.enabled)
                                .font(.system(size: viewModel.fontSize))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(segmentBackground(segment))
                            )
                            .id(segment.id)
                            .accessibilityIdentifier("reader.segment.\(segment.id)")
                        }
                    }
                }
                .padding(.vertical)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                revealChrome()
            }
            .navigationTitle(viewModel.document.title)
            .navigationBarTitleDisplayMode(.inline)
            // Centering strategy:
            //   • Bottom transport and top chrome BOTH float as overlays —
            //     they don't claim layout space.
            //   • Only the search bar uses safeAreaInset(.top), and only
            //     while it's active (search bar is interactive input, not
            //     translucent chrome — content can't scroll under typing).
            //   • Result: scroll content area = (nav bar bottom → home
            //     indicator top) which IS what the user perceives as the
            //     reading area when chrome is faded (the dominant state).
            //   • anchor: .center then puts the active sentence at the
            //     true perceived center, in both portrait and landscape,
            //     across all chrome states. The chrome capsules briefly
            //     overlay the top/bottom edges of the reading region
            //     when visible, but they're translucent and the active
            //     sentence (at center) is well clear of them in both
            //     orientations.
            .safeAreaInset(edge: .top) {
                if viewModel.isSearchActive {
                    SearchBarView(
                        query: Binding(
                            get: { viewModel.searchQuery },
                            set: { viewModel.updateSearchQuery($0) }
                        ),
                        matchCount: viewModel.searchMatchCount,
                        currentMatchPosition: viewModel.currentSearchMatchPosition,
                        onPrevious: { viewModel.goToPreviousSearchMatch() },
                        onNext: { viewModel.goToNextSearchMatch() },
                        onDismiss: {
                            viewModel.deactivateSearch()
                            revealChrome()
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if !viewModel.isSearchActive {
                    HStack {
                        Spacer()
                        topControls
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                    .opacity(isChromeVisible ? 1 : 0)
                    .allowsHitTesting(isChromeVisible)
                    .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
                }
            }
            .overlay(alignment: .bottom) {
                controls
                    .opacity(isChromeVisible ? 1 : 0)
                    .offset(y: isChromeVisible ? 0 : 20)
                    .allowsHitTesting(isChromeVisible)
                    .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isSearchActive)
            .onChange(of: viewModel.searchScrollSignal) { _, _ in
                viewModel.scrollToSearchMatch(with: proxy)
            }
            .overlay(alignment: .topLeading) {
                if isTestMode {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TEST MODE")
                            .fontWeight(.semibold)
                        Text(viewModel.playbackStateText)
                            .accessibilityIdentifier("reader.playbackState")
                        Text("\(viewModel.currentSentenceIndex)")
                            .accessibilityIdentifier("reader.currentSentenceIndex")
                        Text(viewModel.document.title)
                            .accessibilityIdentifier("reader.documentTitle")
                        Text("\(viewModel.notes.count)")
                            .accessibilityIdentifier("reader.noteCount")
                    }
                    .font(.caption2)
                    .padding(6)
                    .background(.thinMaterial)
                }
            }
            .onAppear {
                viewModel.handleAppear()
                revealChrome()
                // Defer the initial scroll past the first layout pass so the
                // LazyVStack has time to realize rows up to the saved sentence
                // position. Calling scrollTo before that happens silently
                // no-ops because the target row doesn't yet exist in layout —
                // which is why pressing Play after open used to "fix" the
                // scroll: the on-change handler triggered realization.
                // Two nudges: one for the typical case, a second after a
                // longer pause for documents where the first scroll only
                // partially advanced the lazy realization.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                    try? await Task.sleep(for: .milliseconds(180))
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                }
            }
            .onDisappear {
                chromeFadeTask?.cancel()
                viewModel.persistPosition()
                viewModel.stopPlayback()
            }
            .onChange(of: viewModel.currentSentenceIndex) { _, _ in
                viewModel.scrollToCurrentSentence(with: proxy, animated: true)
            }
            .onChange(of: viewModel.focusedDisplayBlockID) { _, _ in
                viewModel.scrollToCurrentSentence(with: proxy, animated: true)
            }
            .onChange(of: scenePhase) { _, newValue in
                if newValue == .background || newValue == .inactive {
                    viewModel.persistPosition()
                }
            }
            .alert("Reader Error", isPresented: $viewModel.isShowingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .sheet(isPresented: $isShowingNotesSheet) {
                NotesSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $isShowingPreferencesSheet) {
                ReaderPreferencesSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $isShowingTOCSheet) {
                TOCSheet(viewModel: viewModel)
            }
            .sheet(item: $expandedImageItem) { item in
                ExpandedImageSheet(imageID: item.id, viewModel: viewModel)
            }
        }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            Button {
                revealChrome()
                viewModel.isSearchActive = true
                chromeFadeTask?.cancel()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("reader.search")

            if !viewModel.tocEntries.isEmpty {
                Button {
                    revealChrome()
                    isShowingTOCSheet = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.headline)
                        .foregroundStyle(chromeTint)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("reader.toc")
            }

            Button {
                revealChrome()
                isShowingPreferencesSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("reader.preferences")

            Button {
                revealChrome()
                viewModel.prepareForNotesEntry()
                isShowingNotesSheet = true
            } label: {
                Image(systemName: "note.text")
                    .font(.headline)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("reader.notes")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                revealChrome()
                viewModel.goToPreviousMarker()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("reader.previous")

            Spacer(minLength: 24)

            Button {
                revealChrome()
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.playPauseImageName)
                    .font(.title3)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("reader.playPause")

            Spacer(minLength: 24)

            Button {
                revealChrome()
                viewModel.goToNextMarker()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("reader.next")

            Spacer(minLength: 24)

            Button {
                revealChrome()
                viewModel.restartFromBeginning()
            } label: {
                Image(systemName: "gobackward")
                    .font(.title3)
                    .foregroundStyle(chromeSecondaryTint)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("reader.restart")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private func visualPlaceholder(block: DisplayBlock) -> some View {
        Group {
            if let imageID = block.imageID,
               let data = viewModel.imageData(for: imageID),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .onTapGesture { expandedImageItem = ExpandedImageItem(id: imageID) }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                    }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Visual Element", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                    Text(block.text)
                        .font(.body)
                    Text("Playback pauses here so you can inspect this visual before continuing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func segmentBackground(_ segment: TextSegment) -> Color {
        if viewModel.isCurrentSearchMatch(segment: segment) {
            return Color.primary.opacity(0.28)
        } else if viewModel.isSearchMatch(segment: segment) {
            return Color.primary.opacity(0.10)
        } else if viewModel.isActive(segment: segment) {
            return Color.primary.opacity(0.14)
        }
        return Color.clear
    }

    private func blockBackground(_ block: DisplayBlock) -> Color {
        if viewModel.isCurrentSearchMatch(block: block) {
            return Color.primary.opacity(0.28)
        } else if viewModel.isSearchMatch(block: block) {
            return Color.primary.opacity(0.10)
        } else if viewModel.isActive(block: block) {
            return Color.primary.opacity(0.14)
        }
        return Color.clear
    }

    private func revealChrome() {
        chromeFadeTask?.cancel()
        isChromeVisible = true
        chromeFadeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard Task.isCancelled == false else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                isChromeVisible = false
            }
        }
    }
}

// ========== BLOCK P1: READER PREFERENCES SHEET - START ==========
private struct ReaderPreferencesSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    /// Draft rate percentage shown live while the slider is dragged.
    /// Committed to the viewModel only on drag end to avoid rapid re-enqueue.
    @State private var draftRatePercentage: Float = 100.0

    private var isCustomMode: Bool {
        if case .custom = viewModel.voiceMode { return true }
        return false
    }

    private var currentVoiceIdentifier: String {
        if case .custom(let id, _) = viewModel.voiceMode { return id }
        return ""
    }

    var body: some View {
        NavigationStack {
            Form {
                // Reading section
                Section("Reading") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(Int(viewModel.fontSize))")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $viewModel.fontSize, in: 14...44, step: 1)
                            .accessibilityIdentifier("preferences.fontSize")
                    }
                }

                // Playback section
                Section("Playback") {
                    Picker("Voice Mode", selection: Binding(
                        get: { isCustomMode },
                        set: { viewModel.setVoiceMode(isCustom: $0) }
                    )) {
                        Text("Best Available").tag(false)
                        Text("Custom").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("preferences.voiceMode")

                    if isCustomMode {
                        NavigationLink {
                            VoicePickerView(
                                selectedIdentifier: Binding(
                                    get: { currentVoiceIdentifier },
                                    set: { viewModel.setCustomVoice(identifier: $0) }
                                )
                            )
                        } label: {
                            HStack {
                                Text("Voice")
                                Spacer()
                                Text(viewModel.customVoiceDisplayName)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityIdentifier("preferences.voicePicker")

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Speed")
                                Spacer()
                                Text("\(Int(draftRatePercentage))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            // Rate applies on drag-end only to avoid rapid stop/re-enqueue.
                            Slider(value: $draftRatePercentage, in: 75...150, step: 5) { editing in
                                if !editing {
                                    viewModel.setCustomRate(percentage: draftRatePercentage)
                                }
                            }
                            .accessibilityIdentifier("preferences.rateSlider")
                        }
                    } else {
                        Text("Using the highest-quality voice on your device. Adjust speed and voice in Settings > Accessibility > Spoken Content.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Reader Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                draftRatePercentage = viewModel.customRatePercentage
            }
            .onChange(of: viewModel.voiceMode) { _, _ in
                draftRatePercentage = viewModel.customRatePercentage
            }
        }
    }
}
// ========== BLOCK P1: READER PREFERENCES SHEET - END ==========

private struct NotesSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Current Position") {
                    Text(viewModel.currentSentencePreview)
                        .font(.body)
                        .accessibilityIdentifier("notes.currentSentence")
                    TextField("Add a note for this sentence", text: $viewModel.noteDraft, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("notes.draft")

                    Button("Save Note") {
                        viewModel.saveDraftNoteForCurrentSentence()
                    }
                    .disabled(viewModel.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("notes.save")

                    Button("Bookmark Here") {
                        viewModel.addBookmarkForCurrentSentence()
                    }
                    .accessibilityIdentifier("notes.bookmark")
                }

                Section("Saved Annotations") {
                    if viewModel.notes.isEmpty {
                        Text("No notes or bookmarks yet.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("notes.empty")
                    } else {
                        ForEach(viewModel.notes) { note in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(note.kind == .bookmark ? "Bookmark" : "Note", systemImage: note.kind == .bookmark ? "bookmark.fill" : "note.text")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Button("Jump") {
                                        viewModel.jump(to: note)
                                        dismiss()
                                    }
                                    .accessibilityIdentifier("notes.jump.\(note.id.uuidString)")
                                }

                                if let body = note.body, body.isEmpty == false {
                                    Text(body)
                                        .font(.body)
                                }

                                Text(viewModel.previewText(for: note))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .accessibilityIdentifier("notes.row.\(note.id.uuidString)")
                        }
                    }
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var fontSize: CGFloat = PlaybackPreferences.shared.fontSize {
        didSet { PlaybackPreferences.shared.fontSize = fontSize }
    }
    @Published private(set) var currentSentenceIndex: Int = 0
    @Published private(set) var playbackState: SpeechPlaybackService.PlaybackState = .idle
    @Published private(set) var focusedDisplayBlockID: Int?
    @Published var isShowingError = false
    @Published var errorMessage = ""
    @Published var noteDraft = ""
    @Published private(set) var notes: [Note] = []
    @Published private(set) var voiceMode: SpeechPlaybackService.VoiceMode = .bestAvailable

    // ========== BLOCK VM-SEARCH: SEARCH STATE - START ==========
    @Published var searchQuery: String = ""
    @Published var isSearchActive: Bool = false
    @Published private(set) var searchMatchIndices: [Int] = []
    @Published private(set) var currentSearchMatchPosition: Int? = nil
    /// Emitted each time the view should scroll to a search match.
    /// Uses a counter so repeated navigation to the same index still fires onChange.
    @Published private(set) var searchScrollSignal: SearchScrollSignal? = nil

    struct SearchScrollSignal: Equatable {
        let segmentIndex: Int
        let id: Int
    }
    private var searchScrollCounter = 0

    var searchMatchCount: Int { searchMatchIndices.count }
    // ========== BLOCK VM-SEARCH: SEARCH STATE - END ==========

    let document: Document
    let segments: [TextSegment]
    let displayBlocks: [DisplayBlock]
    /// Table of contents entries for this document. Empty if not available.
    private(set) var tocEntries: [StoredTOCEntry] = []

    private let databaseManager: DatabaseManager
    private let playbackService: SpeechPlaybackService
    private let shouldAutoPlayOnAppear: Bool
    private let shouldAutoCreateNoteOnAppear: Bool
    private let shouldAutoCreateBookmarkOnAppear: Bool
    private let automationNoteBody: String
    private let visualPauseBlockIDsBySentenceIndex: [Int: Int]
    private var cancellables: Set<AnyCancellable> = []
    private var didRunAutomationActions = false
    private var acknowledgedVisualBlockIDs: Set<Int> = []

    init(
        document: Document,
        databaseManager: DatabaseManager,
        playbackService: SpeechPlaybackService? = nil,
        shouldAutoPlayOnAppear: Bool = false,
        shouldAutoCreateNoteOnAppear: Bool = false,
        shouldAutoCreateBookmarkOnAppear: Bool = false,
        automationNoteBody: String = "Automated smoke note"
    ) {
        self.document = document
        self.databaseManager = databaseManager
        let persistedMode = PlaybackPreferences.shared.voiceMode
        self.voiceMode = persistedMode
        self.playbackService = playbackService ?? SpeechPlaybackService(voiceMode: persistedMode)
        self.shouldAutoPlayOnAppear = shouldAutoPlayOnAppear
        self.shouldAutoCreateNoteOnAppear = shouldAutoCreateNoteOnAppear
        self.shouldAutoCreateBookmarkOnAppear = shouldAutoCreateBookmarkOnAppear
        self.automationNoteBody = automationNoteBody
        self.segments = SentenceSegmenter().segments(for: document.plainText)
        let rawBlocks: [DisplayBlock]
        if document.fileType == "md" || document.fileType == "markdown" {
            rawBlocks = MarkdownParser().parse(markdown: document.displayText).blocks
        } else if document.fileType == "pdf" {
            rawBlocks = PDFDisplayParser().parse(displayText: document.displayText).blocks
        } else if document.fileType == "epub" {
            rawBlocks = EPUBDisplayParser().parse(displayText: document.displayText)
        } else {
            rawBlocks = []
        }
        // Split each paragraph block into per-TTS-segment rows so that
        // highlight and scroll always target exactly the utterance being spoken.
        self.displayBlocks = Self.splitParagraphBlocks(rawBlocks, segments: self.segments)
        self.visualPauseBlockIDsBySentenceIndex = ReaderViewModel.buildVisualPauseIndexMap(
            displayBlocks: self.displayBlocks,
            segments: self.segments
        )
        self.tocEntries = (try? databaseManager.tocEntries(for: document.id)) ?? []
    }

    var usesDisplayBlocks: Bool {
        displayBlocks.isEmpty == false
    }

    var playPauseImageName: String {
        switch playbackState {
        case .playing:
            return "pause.fill"
        case .paused, .idle, .finished:
            return "play.fill"
        }
    }

    var playbackStateText: String {
        switch playbackState {
        case .idle:
            return "idle"
        case .playing:
            return "playing"
        case .paused:
            return "paused"
        case .finished:
            return "finished"
        }
    }

    var currentSentencePreview: String {
        currentSegment?.text ?? document.plainText
    }

    var capturedNotesContextPreview: String {
        notesCaptureText()
    }

    func handleAppear() {
        do {
            let position = try databaseManager.readingPosition(for: document.id) ?? .initial(for: document.id)
            currentSentenceIndex = restoreSentenceIndex(from: position)
            playbackService.prepare(at: currentSentenceIndex)
            loadNotes()
            observePlayback()
            runAutomationIfNeeded()
        } catch {
            present(error)
        }
    }

    func togglePlayback() {
        switch playbackState {
        case .playing:
            playbackState = .paused
            playbackService.pause()
            persistPosition()
        case .paused:
            focusedDisplayBlockID = nil
            playbackState = .playing
            playbackService.play(segments: segments, startingAt: currentSentenceIndex)
        case .idle, .finished:
            focusedDisplayBlockID = nil
            playbackState = .playing
            playbackService.play(segments: segments, startingAt: currentSentenceIndex)
        }
    }

    func goToPreviousMarker() {
        jumpToMarker(direction: -1)
    }

    func goToNextMarker() {
        jumpToMarker(direction: 1)
    }

    func restartFromBeginning() {
        focusedDisplayBlockID = nil
        currentSentenceIndex = 0
        playbackService.stop()
        playbackService.prepare(at: currentSentenceIndex)
        persistPosition()
    }

    func prepareForNotesEntry() {
        if playbackState == .playing {
            playbackService.pause()
            persistPosition()
        }

        let capture = notesCaptureText()
        noteDraft = capture
        copyToClipboard(capture)
    }

    func saveDraftNoteForCurrentSentence() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let segment = currentSegment else {
            return
        }

        saveAnnotation(kind: .note, body: trimmed, segment: segment)
        noteDraft = ""
    }

    func addBookmarkForCurrentSentence() {
        guard let segment = currentSegment else {
            return
        }

        saveAnnotation(kind: .bookmark, body: nil, segment: segment)
    }

    func jump(to note: Note) {
        if let index = segments.firstIndex(where: { segment in
            note.startOffset >= segment.startOffset && note.startOffset < segment.endOffset
        }) {
            currentSentenceIndex = index
            playbackService.prepare(at: currentSentenceIndex)
            persistPosition()
        }
    }

    func persistPosition() {
        guard let segment = currentSegment else {
            return
        }

        let position = ReadingPosition(
            documentID: document.id,
            updatedAt: .now,
            characterOffset: segment.startOffset,
            sentenceIndex: currentSentenceIndex
        )

        do {
            try databaseManager.upsertReadingPosition(position)
        } catch {
            present(error)
        }
    }

    func stopPlayback() {
        playbackService.stop()
    }

    // ========== BLOCK VM-VOICE: VOICE MODE CONTROLS - START ==========

    /// Switch between Best Available and Custom mode.
    ///
    /// Switching to Custom picks the best voice available on the device as the default.
    /// Switching back to Best Available preserves the custom settings for if the user returns.
    func setVoiceMode(isCustom: Bool) {
        if isCustom {
            // If already in custom, keep existing settings.
            if case .custom = voiceMode { return }
            // Restore last persisted custom settings, or fall back to sensible defaults.
            let restoredMode = PlaybackPreferences.shared.lastCustomVoiceMode
                ?? .custom(
                    voiceIdentifier: bestAvailableVoiceIdentifier(),
                    rate: AVSpeechUtteranceDefaultSpeechRate
                )
            applyAndPersist(restoredMode)
        } else {
            // Persist custom settings before leaving so they restore correctly on return.
            applyAndPersist(.bestAvailable)
        }
    }

    /// Update the voice identifier within Custom mode.
    func setCustomVoice(identifier: String) {
        guard case .custom(_, let rate) = voiceMode else { return }
        applyAndPersist(.custom(voiceIdentifier: identifier, rate: rate))
    }

    /// Update the playback rate within Custom mode.
    /// Accepts a percentage (75–200); converts to AVSpeech rate internally.
    func setCustomRate(percentage: Float) {
        guard case .custom(let identifier, _) = voiceMode else { return }
        let avRate = (percentage / 100.0) * AVSpeechUtteranceDefaultSpeechRate
        applyAndPersist(.custom(voiceIdentifier: identifier, rate: avRate))
    }

    /// Current rate as a percentage label for the preferences UI (returns 100 for bestAvailable).
    var customRatePercentage: Float {
        guard case .custom(_, let rate) = voiceMode else { return 100.0 }
        return (rate / AVSpeechUtteranceDefaultSpeechRate) * 100.0
    }

    /// Display name for the currently selected custom voice.
    var customVoiceDisplayName: String {
        guard case .custom(let identifier, _) = voiceMode,
              let voice = AVSpeechSynthesisVoice(identifier: identifier)
        else { return "None" }
        return voice.name
    }

    private func applyAndPersist(_ newMode: SpeechPlaybackService.VoiceMode) {
        voiceMode = newMode
        playbackService.applyVoiceMode(newMode)
        PlaybackPreferences.shared.voiceMode = newMode
    }

    private func bestAvailableVoiceIdentifier() -> String {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let preferred = voices.first(where: { $0.quality == .premium })
            ?? voices.first(where: { $0.quality == .enhanced })
            ?? voices.first
        return preferred?.identifier ?? ""
    }

    // ========== BLOCK VM-VOICE: VOICE MODE CONTROLS - END ==========

    // ========== BLOCK VM-SEARCH: SEARCH METHODS - START ==========

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchMatchIndices = []
            currentSearchMatchPosition = nil
            searchScrollSignal = nil
            return
        }
        searchMatchIndices = segments.indices.filter {
            segments[$0].text.localizedCaseInsensitiveContains(trimmed)
        }
        if searchMatchIndices.isEmpty {
            currentSearchMatchPosition = nil
            searchScrollSignal = nil
        } else {
            currentSearchMatchPosition = 0
            emitSearchScroll(to: searchMatchIndices[0])
        }
    }

    func goToNextSearchMatch() {
        guard !searchMatchIndices.isEmpty else { return }
        let next = ((currentSearchMatchPosition ?? -1) + 1) % searchMatchIndices.count
        currentSearchMatchPosition = next
        emitSearchScroll(to: searchMatchIndices[next])
    }

    func goToPreviousSearchMatch() {
        guard !searchMatchIndices.isEmpty else { return }
        let prev = ((currentSearchMatchPosition ?? 0) - 1 + searchMatchIndices.count) % searchMatchIndices.count
        currentSearchMatchPosition = prev
        emitSearchScroll(to: searchMatchIndices[prev])
    }

    func deactivateSearch() {
        isSearchActive = false
        searchQuery = ""
        searchMatchIndices = []
        currentSearchMatchPosition = nil
        searchScrollSignal = nil
    }

    func scrollToSearchMatch(with proxy: ScrollViewProxy) {
        guard let signal = searchScrollSignal else { return }
        let idx = signal.segmentIndex
        guard segments.indices.contains(idx) else { return }
        let scrollID: Int
        if usesDisplayBlocks {
            let seg = segments[idx]
            scrollID = displayBlocks.first(where: {
                seg.startOffset < $0.endOffset && seg.endOffset > $0.startOffset
            })?.id ?? idx
        } else {
            scrollID = idx
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(scrollID, anchor: .center)
        }
    }

    func isSearchMatch(segment: TextSegment) -> Bool {
        !searchMatchIndices.isEmpty && searchMatchIndices.contains(segment.id)
    }

    func isCurrentSearchMatch(segment: TextSegment) -> Bool {
        guard let pos = currentSearchMatchPosition,
              searchMatchIndices.indices.contains(pos) else { return false }
        return segment.id == searchMatchIndices[pos]
    }

    func isSearchMatch(block: DisplayBlock) -> Bool {
        guard !searchMatchIndices.isEmpty else { return false }
        return searchMatchIndices.contains { idx in
            guard segments.indices.contains(idx) else { return false }
            let seg = segments[idx]
            return seg.startOffset < block.endOffset && seg.endOffset > block.startOffset
        }
    }

    func isCurrentSearchMatch(block: DisplayBlock) -> Bool {
        guard let pos = currentSearchMatchPosition,
              searchMatchIndices.indices.contains(pos) else { return false }
        let idx = searchMatchIndices[pos]
        guard segments.indices.contains(idx) else { return false }
        let seg = segments[idx]
        return seg.startOffset < block.endOffset && seg.endOffset > block.startOffset
    }

    private func emitSearchScroll(to segmentIndex: Int) {
        searchScrollCounter += 1
        searchScrollSignal = SearchScrollSignal(segmentIndex: segmentIndex, id: searchScrollCounter)
    }

    // ========== BLOCK VM-SEARCH: SEARCH METHODS - END ==========

    func isActive(segment: TextSegment) -> Bool {
        segment.id == currentSentenceIndex
    }

    func isActive(block: DisplayBlock) -> Bool {
        if focusedDisplayBlockID == block.id {
            return true
        }

        guard let segment = currentSegment else {
            return false
        }

        return segment.startOffset < block.endOffset && segment.endOffset > block.startOffset
    }

    func annotationSymbol(for segment: TextSegment) -> String? {
        let segmentNotes = notes.filter { note in
            note.startOffset >= segment.startOffset && note.startOffset < segment.endOffset
        }

        if segmentNotes.contains(where: { $0.kind == .note }) {
            return "note.text"
        }

        if segmentNotes.contains(where: { $0.kind == .bookmark }) {
            return "bookmark.fill"
        }

        return nil
    }

    func annotationSymbol(for block: DisplayBlock) -> String? {
        let blockNotes = notes.filter { note in
            note.startOffset >= block.startOffset && note.startOffset < block.endOffset
        }

        if blockNotes.contains(where: { $0.kind == .note }) {
            return "note.text"
        }

        if blockNotes.contains(where: { $0.kind == .bookmark }) {
            return "bookmark.fill"
        }

        return nil
    }

    func displayText(for block: DisplayBlock) -> String {
        if let displayPrefix = block.displayPrefix {
            return "\(displayPrefix) \(block.text)"
        }

        return block.text
    }

    func font(for block: DisplayBlock) -> Font {
        switch block.kind {
        case .heading(let level):
            let size = max(fontSize + CGFloat(10 - level), fontSize + 2)
            return .system(size: size)
        default:
            return .system(size: fontSize)
        }
    }

    func fontWeight(for block: DisplayBlock) -> Font.Weight {
        switch block.kind {
        case .heading:
            return .bold
        default:
            return .regular
        }
    }

    func foregroundStyle(for block: DisplayBlock) -> Color {
        switch block.kind {
        case .quote:
            return .secondary
        case .visualPlaceholder:
            return .primary
        default:
            return .primary
        }
    }

    func previewText(for note: Note) -> String {
        guard let index = segments.firstIndex(where: { segment in
            note.startOffset >= segment.startOffset && note.startOffset < segment.endOffset
        }) else {
            return document.title
        }

        return segments[index].text
    }

    func scrollToCurrentSentence(with proxy: ScrollViewProxy, animated: Bool) {
        let scrollTargetID: Int

        if let blockID = currentDisplayBlockID {
            scrollTargetID = blockID
        } else if segments.isEmpty == false {
            scrollTargetID = currentSentenceIndex
        } else {
            return
        }

        let action = {
            proxy.scrollTo(scrollTargetID, anchor: .center)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.25), action)
        } else {
            action()
        }
    }

    private var currentSegment: TextSegment? {
        guard segments.indices.contains(currentSentenceIndex) else {
            return nil
        }
        return segments[currentSentenceIndex]
    }

    private var currentDisplayBlockID: Int? {
        if let focusedDisplayBlockID {
            return focusedDisplayBlockID
        }

        guard let segment = currentSegment else {
            return nil
        }

        return displayBlocks.first(where: { block in
            segment.startOffset < block.endOffset && segment.endOffset > block.startOffset
        })?.id
    }

    private func boundedSentenceIndex(_ candidate: Int) -> Int {
        guard segments.isEmpty == false else {
            return 0
        }
        return min(max(candidate, 0), segments.count - 1)
    }

    private func restoreSentenceIndex(from position: ReadingPosition) -> Int {
        guard segments.isEmpty == false else {
            return 0
        }

        if let offsetMatch = segments.firstIndex(where: { segment in
            position.characterOffset >= segment.startOffset && position.characterOffset < segment.endOffset
        }) {
            return offsetMatch
        }

        return boundedSentenceIndex(position.sentenceIndex)
    }

    private func jumpToMarker(direction: Int) {
        guard direction != 0 else {
            return
        }

        if let targetIndex = markerSentenceIndex(direction: direction) {
            jump(toSentenceIndex: targetIndex, shouldRestartPlayback: playbackState == .playing)
        }
    }

    private func markerSentenceIndex(direction: Int) -> Int? {
        if usesDisplayBlocks,
           let currentBlockIndex = currentDisplayBlockIndex {
            var nextBlockIndex = currentBlockIndex + direction
            while displayBlocks.indices.contains(nextBlockIndex) {
                if let candidateIndex = sentenceIndex(forOffset: displayBlocks[nextBlockIndex].startOffset),
                   candidateIndex != currentSentenceIndex {
                    return candidateIndex
                }
                nextBlockIndex += direction
            }
            return nil
        }

        let nextSentenceIndex = currentSentenceIndex + direction
        guard segments.indices.contains(nextSentenceIndex) else {
            return nil
        }
        return nextSentenceIndex
    }

    private func sentenceIndex(forOffset offset: Int) -> Int? {
        segments.firstIndex(where: { segment in
            offset >= segment.startOffset && offset < segment.endOffset
        }) ?? segments.lastIndex(where: { segment in
            offset >= segment.startOffset
        })
    }

    private var currentDisplayBlockIndex: Int? {
        guard let blockID = currentDisplayBlockID else {
            return nil
        }

        return displayBlocks.firstIndex(where: { $0.id == blockID })
    }

    private func jump(toSentenceIndex sentenceIndex: Int, shouldRestartPlayback: Bool) {
        let boundedIndex = boundedSentenceIndex(sentenceIndex)
        focusedDisplayBlockID = nil
        currentSentenceIndex = boundedIndex
        if shouldRestartPlayback {
            playbackService.restart(segments: segments, startingAt: boundedIndex)
        } else {
            playbackService.prepare(at: boundedIndex)
        }
        persistPosition()
    }

    private func notesCaptureText() -> String {
        guard let currentSegment else {
            return document.plainText
        }

        var context: [String] = []

        let previousIndex = currentSentenceIndex - 1
        if segments.indices.contains(previousIndex) {
            context.append(segments[previousIndex].text)
        }

        context.append(currentSegment.text)

        return context.joined(separator: "\n\n")
    }

    private func observePlayback() {
        guard cancellables.isEmpty else {
            return
        }

        playbackService.$currentSentenceIndex
            .compactMap { $0 }
            .sink { [weak self] index in
                guard let self else { return }
                self.currentSentenceIndex = self.boundedSentenceIndex(index)
                self.pauseForVisualBlockIfNeeded(atSentenceIndex: self.currentSentenceIndex)
                self.persistPosition()
            }
            .store(in: &cancellables)

        playbackService.$state
            .sink { [weak self] state in
                self?.playbackState = state
            }
            .store(in: &cancellables)
    }

    private func pauseForVisualBlockIfNeeded(atSentenceIndex sentenceIndex: Int) {
        guard playbackService.state == .playing,
              let visualBlockID = visualPauseBlockIDsBySentenceIndex[sentenceIndex],
              acknowledgedVisualBlockIDs.contains(visualBlockID) == false else {
            return
        }

        guard let visualBlock = displayBlocks.first(where: { $0.id == visualBlockID }) else {
            focusedDisplayBlockID = nil
            return
        }

        acknowledgedVisualBlockIDs.insert(visualBlock.id)
        focusedDisplayBlockID = visualBlock.id
        playbackService.pause()
    }

    private static func buildVisualPauseIndexMap(displayBlocks: [DisplayBlock], segments: [TextSegment]) -> [Int: Int] {
        guard displayBlocks.isEmpty == false, segments.isEmpty == false else {
            return [:]
        }

        var mapping: [Int: Int] = [:]

        for (blockIndex, block) in displayBlocks.enumerated() where block.kind == .visualPlaceholder {
            var nextBlockIndex = blockIndex + 1
            while displayBlocks.indices.contains(nextBlockIndex) {
                let candidateBlock = displayBlocks[nextBlockIndex]
                if let sentenceIndex = sentenceIndex(forOffset: candidateBlock.startOffset, segments: segments) {
                    mapping[sentenceIndex] = block.id
                    break
                }
                nextBlockIndex += 1
            }
        }

        return mapping
    }

    private static func sentenceIndex(forOffset offset: Int, segments: [TextSegment]) -> Int? {
        segments.firstIndex(where: { segment in
            offset >= segment.startOffset && offset < segment.endOffset
        }) ?? segments.lastIndex(where: { segment in
            offset >= segment.startOffset
        })
    }

    // ========== BLOCK VM-SPLIT: PARAGRAPH BLOCK SPLITTING - START ==========

    /// Replaces each `.paragraph` DisplayBlock with one sub-block per TTS segment
    /// that starts within it.  Non-paragraph blocks (headings, images, bullets,
    /// quotes) pass through unchanged with reassigned sequential IDs.
    ///
    /// After splitting, `isActive(block:)` returns true only for the one block
    /// containing the active utterance — so highlight and auto-scroll target
    /// exactly what is being spoken rather than an entire paragraph.
    private static func splitParagraphBlocks(
        _ blocks: [DisplayBlock],
        segments: [TextSegment]
    ) -> [DisplayBlock] {
        var result: [DisplayBlock] = []
        for block in blocks {
            guard block.kind == .paragraph else {
                result.append(DisplayBlock(
                    id: result.count,
                    kind: block.kind,
                    text: block.text,
                    displayPrefix: block.displayPrefix,
                    startOffset: block.startOffset,
                    endOffset: block.endOffset,
                    imageID: block.imageID
                ))
                continue
            }

            // Segments that START within this paragraph's offset range.
            // Using startOffset (not overlap) ensures each segment maps to
            // exactly one block — no duplicates across paragraph boundaries.
            let inBlock = segments.filter { seg in
                seg.startOffset >= block.startOffset && seg.startOffset < block.endOffset
            }

            if inBlock.isEmpty {
                // Rare: paragraph too short to own a segment start (content is
                // absorbed into an adjacent segment by the tokenizer). Keep as-is.
                result.append(DisplayBlock(
                    id: result.count,
                    kind: .paragraph,
                    text: block.text,
                    displayPrefix: nil,
                    startOffset: block.startOffset,
                    endOffset: block.endOffset
                ))
            } else {
                for seg in inBlock {
                    result.append(DisplayBlock(
                        id: result.count,
                        kind: .paragraph,
                        text: seg.text,
                        displayPrefix: nil,
                        startOffset: seg.startOffset,
                        endOffset: seg.endOffset
                    ))
                }
            }
        }
        return result
    }

    // ========== BLOCK VM-SPLIT: PARAGRAPH BLOCK SPLITTING - END ==========

    private func loadNotes() {
        do {
            notes = try databaseManager.notes(for: document.id)
        } catch {
            present(error)
        }
    }

    private func saveAnnotation(kind: NoteKind, body: String?, segment: TextSegment) {
        let now = Date()
        let note = Note(
            id: UUID(),
            documentID: document.id,
            createdAt: now,
            updatedAt: now,
            kind: kind,
            startOffset: segment.startOffset,
            endOffset: segment.endOffset,
            body: body
        )

        do {
            try databaseManager.insertNote(note)
            loadNotes()
        } catch {
            present(error)
        }
    }

    private func runAutomationIfNeeded() {
        guard didRunAutomationActions == false else {
            return
        }

        didRunAutomationActions = true

        if shouldAutoCreateNoteOnAppear {
            noteDraft = automationNoteBody
            saveDraftNoteForCurrentSentence()
        }

        if shouldAutoCreateBookmarkOnAppear {
            addBookmarkForCurrentSentence()
        }

        if shouldAutoPlayOnAppear, playbackState == .idle, segments.isEmpty == false {
            togglePlayback()
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }

    // ========== BLOCK VM-IMAGE: IMAGE LOADING - START ==========

    private var imageCache: [String: Data] = [:]

    /// Returns PNG data for the given imageID, caching after the first load.
    func imageData(for imageID: String) -> Data? {
        if let cached = imageCache[imageID] { return cached }
        let data = try? databaseManager.imageData(for: imageID)
        if let data { imageCache[imageID] = data }
        return data
    }

    // ========== BLOCK VM-IMAGE: IMAGE LOADING - END ==========

    // ========== BLOCK VM-TOC: TABLE OF CONTENTS NAVIGATION - START ==========

    /// Jumps playback and scroll position to the sentence nearest to a TOC entry's
    /// plainTextOffset. Stops any active playback before jumping.
    func jumpToTOCEntry(_ entry: StoredTOCEntry) {
        guard entry.plainTextOffset >= 0 else { return }
        stopPlayback()
        let targetIndex = segments.lastIndex(where: { $0.startOffset <= entry.plainTextOffset })
            ?? 0
        currentSentenceIndex = targetIndex
        persistPosition()
    }

    // ========== BLOCK VM-TOC: TABLE OF CONTENTS NAVIGATION - END ==========
}

// ========== BLOCK P2: EXPANDED IMAGE SHEET - START ==========

/// Token passed to `.sheet(item:)` — the imageID is both key and payload.
struct ExpandedImageItem: Identifiable {
    let id: String   // imageID
}

private struct ExpandedImageSheet: View {
    let imageID: String
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let data = viewModel.imageData(for: imageID),
                   let uiImage = UIImage(data: data) {
                    ZoomableImageView(image: uiImage)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView(
                        "Image Unavailable",
                        systemImage: "photo.slash",
                        description: Text("This image could not be loaded.")
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// ========== BLOCK P2: EXPANDED IMAGE SHEET - END ==========

// ========== BLOCK P3: TABLE OF CONTENTS SHEET - START ==========

/// Sheet that lists a document's TOC entries. Tapping an entry jumps the reader
/// to that section and dismisses the sheet. Only shown when TOC data is available.
private struct TOCSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(viewModel.tocEntries, id: \.playOrder) { entry in
                Button {
                    viewModel.jumpToTOCEntry(entry)
                    dismiss()
                } label: {
                    Text(entry.title)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// ========== BLOCK P3: TABLE OF CONTENTS SHEET - END ==========
