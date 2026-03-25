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
    @State private var isChromeVisible = true
    @State private var chromeFadeTask: Task<Void, Never>?
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
                    mode: playbackMode == .simulated ? .simulated(stepInterval: 0.15) : .system
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
                                    .fill(viewModel.isActive(block: block) ? Color.accentColor.opacity(0.18) : Color.clear)
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
                                    .fill(viewModel.isActive(segment: segment) ? Color.accentColor.opacity(0.18) : Color.clear)
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
            .safeAreaInset(edge: .bottom) {
                controls
                    .opacity(isChromeVisible ? 1 : 0)
                    .offset(y: isChromeVisible ? 0 : 20)
                    .allowsHitTesting(isChromeVisible)
                    .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
            }
            .overlay(alignment: .topTrailing) {
                topControls
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                    .opacity(isChromeVisible ? 1 : 0)
                    .offset(y: isChromeVisible ? 0 : -12)
                    .allowsHitTesting(isChromeVisible)
                    .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
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
                viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                revealChrome()
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
        }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 8) {
            Label("Visual Element", systemImage: "photo.on.rectangle.angled")
                .font(.headline)

            Text(block.text)
                .font(.body)

            Text("Playback pauses here by default so you can inspect the visual content before continuing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
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

private struct ReaderPreferencesSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Playback") {
                    Text("Posey uses your system Spoken Content voice. To change voices or download higher-quality voices, use Settings > Accessibility > Spoken Content > Voices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Reader Preferences")
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
    @Published var fontSize: CGFloat = 18
    @Published private(set) var currentSentenceIndex: Int = 0
    @Published private(set) var playbackState: SpeechPlaybackService.PlaybackState = .idle
    @Published private(set) var focusedDisplayBlockID: Int?
    @Published var isShowingError = false
    @Published var errorMessage = ""
    @Published var noteDraft = ""
    @Published private(set) var notes: [Note] = []

    let document: Document
    let segments: [TextSegment]
    let displayBlocks: [DisplayBlock]

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
        self.playbackService = playbackService ?? SpeechPlaybackService()
        self.shouldAutoPlayOnAppear = shouldAutoPlayOnAppear
        self.shouldAutoCreateNoteOnAppear = shouldAutoCreateNoteOnAppear
        self.shouldAutoCreateBookmarkOnAppear = shouldAutoCreateBookmarkOnAppear
        self.automationNoteBody = automationNoteBody
        self.segments = SentenceSegmenter().segments(for: document.plainText)
        if document.fileType == "md" || document.fileType == "markdown" {
            self.displayBlocks = MarkdownParser().parse(markdown: document.displayText).blocks
        } else if document.fileType == "pdf" {
            self.displayBlocks = PDFDisplayParser().parse(displayText: document.displayText).blocks
        } else {
            self.displayBlocks = []
        }
        self.visualPauseBlockIDsBySentenceIndex = ReaderViewModel.buildVisualPauseIndexMap(
            displayBlocks: self.displayBlocks,
            segments: self.segments
        )
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
}
