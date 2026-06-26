import SwiftUI
import UIKit
import Combine

// ========== BLOCK 01: SURFACE READER HOST (THE CUTOVER) - START ==========

/// The shipping reader's render layer. Replaces the old
/// `ScrollView → LazyVStack → ForEach(ContentUnit) { UnitRowView }` (N per-unit
/// UITextViews + a SwiftUI-reaches-into-UIKit scroll race) with ONE owned
/// `ReaderSurface` (a single UITextView that owns its own scroll).
///
/// It is driven entirely by the EXISTING `ReaderViewModel` — playback, search,
/// resume, TOC, annotations all stay where they are. The surface's `playbackIndex`
/// is built in the SAME `(unitSequence, sentenceIndex)` order as the ViewModel's
/// `segments`/`sentences`, so a sentence's surface position and its
/// `currentSentenceIndex` are the same number — every behavior reduces to a segment
/// index → a surface range. There is no second coordinate space.
///
/// Read-along is TRUE line-level: `SpeechPlaybackService.willSpeakRange` reports the
/// word being spoken, the `ReadAlongEngine` maps it to the visual line, and the line
/// glides to the focal point (Mark's "single point of gaze"). Annotations
/// (note / bookmark / conversation) render as margin glyphs in the right gutter.
struct SurfaceReaderHost: UIViewRepresentable {

    @ObservedObject var viewModel: ReaderViewModel
    /// Open the note/bookmark editor for a tapped gutter glyph.
    let onOpenNote: (UUID) -> Void
    /// Open the Ask Posey sheet on a tapped conversation gutter glyph.
    let onOpenConversation: (String?) -> Void
    /// Any interaction with the page reveals the auto-fading chrome.
    let onReveal: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let coord = context.coordinator
        coord.build(from: viewModel)                       // first build (may be empty if still loading)
        return coord.surface.textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.sync(with: viewModel)
    }

    // ----- Coordinator: owns the surface + engine, applies ViewModel state diffs -----

    @MainActor
    final class Coordinator {
        private let parent: SurfaceReaderHost
        private(set) var surface: ReaderSurface
        private var engine: ReadAlongEngine
        private var cancellables: Set<AnyCancellable> = []

        // Diff state — only re-do expensive work when the input actually changed.
        private var builtContentToken = ""
        private var builtFontSize: CGFloat = 0
        private var lastBandSegmentIndex: Int = -1
        private var lastSearchActive = false
        private var lastMarkersToken = ""
        /// UUID-keyed map back to the conversation anchor's storage id (its row id is a
        /// String; the surface marker id is a UUID, so we round-trip through this).
        private var conversationStorageByMarkerID: [UUID: String] = [:]
        /// Note ids currently rendered, so a marker tap routes to the note vs conversation path.
        private var noteMarkerIDs: Set<UUID> = []

        init(_ parent: SurfaceReaderHost) {
            self.parent = parent
            self.surface = ReaderSurface(content: .empty)
            self.engine = ReadAlongEngine(surface: surface)
        }

        /// Build (or rebuild) the surface content from the ViewModel's OWN filtered
        /// arrays — this is the index-alignment guarantee. Re-wires callbacks + the
        /// word-level read-along subscription onto the (possibly new) surface.
        func build(from vm: ReaderViewModel) {
            let content = SurfaceBuilder.build(
                units: vm.units,
                sentences: vm.sentences,
                bodyPointSize: vm.fontSize,
                imageData: { vm.imageData(for: $0) }
            )
            surface.reload(content: content)
            surface.bodyPointSize = vm.fontSize
            builtContentToken = Self.contentToken(vm)
            builtFontSize = vm.fontSize

            wireCallbacks(vm)
            subscribeReadAlong(vm)
            applyMarkers(vm, force: true)
            applyBand(vm, force: true)
        }

        private func wireCallbacks(_ vm: ReaderViewModel) {
            surface.onTap = { [weak vm, weak self] offset in
                self?.parent.onReveal()
                guard let seg = self?.surface.content.layout.segment(atSurfaceOffset: offset) else { return }
                vm?.jumpToSentenceID(seg.sentenceID)
            }
            surface.onOpenMarker = { [weak self] id in
                guard let self else { return }
                self.parent.onReveal()
                if self.noteMarkerIDs.contains(id) {
                    self.parent.onOpenNote(id)
                } else if let storageID = self.conversationStorageByMarkerID[id] {
                    self.parent.onOpenConversation(storageID)
                }
            }
        }

        /// Subscribe to the real playback service's spoken-word signal (republished by
        /// the ViewModel). Each word maps to its visual line; the engine lights + glides
        /// it. This is what keeps the highlighted line in sync with the voice through a
        /// multi-line sentence.
        private func subscribeReadAlong(_ vm: ReaderViewModel) {
            cancellables.removeAll()
            vm.$spokenWord
                .receive(on: RunLoop.main)
                .sink { [weak self] word in
                    guard let self, let word else { return }
                    self.engine.onSpokenWord(playbackIndex: word.index, wordOffset: word.wordOffset)
                    self.lastBandSegmentIndex = word.index
                }
                .store(in: &cancellables)
        }

        /// Apply every per-update diff: rebuild on content/font change, move the
        /// read-along band, refresh annotation glyphs, follow search.
        func sync(with vm: ReaderViewModel) {
            let token = Self.contentToken(vm)
            if token != builtContentToken || vm.fontSize != builtFontSize {
                build(from: vm)                 // structural change → full rebuild + re-apply
                return
            }
            applyMarkers(vm, force: false)
            applyBand(vm, force: false)
        }

        /// Read-along / search band: while searching, follow the search hit; otherwise
        /// follow the spoken/active sentence. Pins the line and glides it to the focal
        /// point. Word-level motion during playback is driven by `subscribeReadAlong`;
        /// this covers pause / seek / search / initial position.
        private func applyBand(_ vm: ReaderViewModel, force: Bool) {
            let layout = surface.content.layout
            let targetSeg: SurfaceSegment?
            if vm.isSearchActive {
                targetSeg = vm.searchHighlightSentenceID.flatMap { layout.segment(forSentenceID: $0) }
            } else {
                targetSeg = layout.segment(forPlaybackIndex: vm.currentSentenceIndex)
            }
            guard let seg = targetSeg else {
                if vm.isSearchActive != lastSearchActive { engine.reset() }
                lastSearchActive = vm.isSearchActive
                return
            }
            let changed = force || seg.playbackIndex != lastBandSegmentIndex || vm.isSearchActive != lastSearchActive
            guard changed else { return }
            lastBandSegmentIndex = seg.playbackIndex
            lastSearchActive = vm.isSearchActive
            // Pin the sentence's first line (and glide). During active playback the
            // word-level subscription immediately refines this to the spoken line.
            if vm.isSearchActive {
                engine.onSpokenSentence(playbackIndex: seg.playbackIndex)
            } else if vm.playbackState != .playing {
                engine.onSpokenSentence(playbackIndex: seg.playbackIndex)
            }
        }

        /// Build the gutter markers from notes (note/bookmark) + Ask Posey anchor rows
        /// (conversation). Each annotation's plainText offset → segment index → surface
        /// range, so the glyph sits on the annotated line. Never throws away an
        /// annotation: an unresolved offset clamps to the nearest segment.
        private func applyMarkers(_ vm: ReaderViewModel, force: Bool) {
            let token = Self.markersToken(vm)
            guard force || token != lastMarkersToken else { return }
            lastMarkersToken = token

            let layout = surface.content.layout
            var markers: [SurfaceMarker] = []
            noteMarkerIDs.removeAll()
            conversationStorageByMarkerID.removeAll()

            func surfaceRange(forPlainOffset offset: Int) -> NSRange? {
                guard let idx = vm.segments.lastIndex(where: { $0.startOffset <= offset })
                        ?? (vm.segments.isEmpty ? nil : 0),
                      let seg = layout.segment(forPlaybackIndex: idx) else { return nil }
                return seg.range
            }

            for note in vm.notes {
                guard let r = surfaceRange(forPlainOffset: note.startOffset) else { continue }
                noteMarkerIDs.insert(note.id)
                let isBookmark = note.kind == .bookmark
                markers.append(SurfaceMarker(
                    id: note.id, surfaceRange: r, unsure: false,
                    symbol: isBookmark ? "bookmark.fill" : "square.and.pencil",
                    label: isBookmark ? "Bookmark" : "Note"))
            }

            // Document-scope conversations carry a sentinel offset (not tied to a passage),
            // so they have no margin position — skip them; only PASSAGE-anchored
            // conversations earn a gutter glyph. The single-bubble symbol is narrow
            // (square-ish) so it sits in the gutter like the note/bookmark marks instead of
            // the wide double-bubble that spilled into the highlighted text.
            let docContentEnd = vm.segments.last?.endOffset ?? Int.max
            for row in vm.conversationAnchorRows() {
                guard let off = row.anchorOffset, off >= 0, off <= docContentEnd,
                      let r = surfaceRange(forPlainOffset: off) else { continue }
                let markerID = UUID()
                conversationStorageByMarkerID[markerID] = row.id
                markers.append(SurfaceMarker(
                    id: markerID, surfaceRange: r, unsure: false,
                    symbol: "bubble.left.fill",
                    label: "Conversation"))
            }

            surface.setMarkers(markers)
        }

        /// A token that changes whenever the rendered DOCUMENT (not the reading
        /// position) changes — drives a full rebuild.
        private static func contentToken(_ vm: ReaderViewModel) -> String {
            "\(vm.document.id.uuidString)#u\(vm.units.count)#s\(vm.sentences.count)"
        }

        /// A token over the annotation inputs — drives a glyph refresh only when
        /// annotations actually change.
        private static func markersToken(_ vm: ReaderViewModel) -> String {
            let notes = vm.notes.map { "\($0.id.uuidString)\($0.startOffset)\($0.kind.rawValue)" }.joined()
            return "\(vm.unitAnnotationVersion)#\(notes)"
        }
    }
}

// ========== BLOCK 01: SURFACE READER HOST - END ==========
