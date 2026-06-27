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
    /// Tap on an image / table → open the full-screen zoomable viewer (restored cutover behavior).
    let onOpenImage: (String) -> Void

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
        /// UUID-keyed map back to the conversation's storage id (the owning anchor row id,
        /// a String; the surface marker id is a UUID, so we round-trip through this). A
        /// document-scope conversation has no anchor → no entry here (opens unscoped).
        private var conversationStorageByMarkerID: [UUID: String] = [:]
        /// Every conversation marker id currently rendered — both anchor glyphs AND cited-
        /// passage glyphs (bidirectional). A marker tap routes to the conversation path when
        /// its id is in here; the storage-id map above is consulted for WHICH thread.
        private var conversationMarkerIDs: Set<UUID> = []
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
            surface.tuning.readAlongGranularity = vm.readAlongGranularity   // honor saved dial
            builtContentToken = Self.contentToken(vm)
            builtFontSize = vm.fontSize

            wireCallbacks(vm)
            subscribeReadAlong(vm)
            applyMarkers(vm, force: true)
            applyBand(vm, force: true)
        }

        private func wireCallbacks(_ vm: ReaderViewModel) {
            surface.onTap = { [weak vm, weak self] offset in
                guard let self, let vm else { return }
                self.parent.onReveal()
                let layout = self.surface.content.layout
                // Image / table tap → open the full-screen viewer (restored 2026-06-26;
                // the old per-row onTapGesture did this before the cutover). Checked FIRST
                // because a rasterized table also carries a (pinned) sentence range.
                if let uid = layout.unitID(atSurfaceOffset: offset),
                   let unit = vm.units.first(where: { $0.id == uid }),
                   unit.kind == .image || unit.kind == .table,
                   let imageID = unit.metadata.imageID, vm.imageData(for: imageID) != nil {
                    self.parent.onOpenImage(imageID)
                    return
                }
                if let seg = layout.segment(atSurfaceOffset: offset) {
                    vm.jumpToSentenceID(seg.sentenceID)
                }
            }
            // Dragging to scroll re-reveals the auto-fading chrome WITHOUT moving the
            // reading position (a tap would). Restores the old reader's scroll-to-reveal,
            // which died when the SwiftUI ScrollView was replaced by the surface.
            surface.onUserScroll = { [weak self] in self?.parent.onReveal() }
            surface.onOpenMarker = { [weak self] id in
                guard let self else { return }
                self.parent.onReveal()
                if self.noteMarkerIDs.contains(id) {
                    self.parent.onOpenNote(id)
                } else if self.conversationMarkerIDs.contains(id) {
                    // Anchor glyph or cited-passage glyph — both reopen the same thread.
                    // Storage id may be nil (document-scope) → opens the unscoped thread.
                    self.parent.onOpenConversation(self.conversationStorageByMarkerID[id])
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
            // Antenna test hooks, re-pointed from the retired toy cover to the real reader.
            NotificationCenter.default.publisher(for: .remoteScrollSurface)
                .receive(on: RunLoop.main)
                .sink { [weak self] note in
                    guard let self, let f = note.userInfo?["fraction"] as? Double else { return }
                    self.scrollToFraction(CGFloat(f))
                }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: .remoteSimulateSurfaceDrag)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.surface.onUserScroll?() }   // same path a real drag fires
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: .remoteSetReadAlongLevel)
                .receive(on: RunLoop.main)
                .sink { [weak self] note in
                    guard let self, let lvl = note.userInfo?["level"] as? String,
                          let g = ReaderTuning.ReadAlongGranularity(rawValue: lvl) else { return }
                    // Drive the user preference (not just the surface) so the antenna verb,
                    // the Preferences picker, and persistence share one source of truth; the
                    // VM's didSet persists it and the next sync applies it to the surface.
                    self.parent.viewModel.readAlongGranularity = g
                }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: .remoteSurfaceTapImage)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    let layout = self.surface.content.layout
                    // Tap the first image/table with bytes — exercises the REAL onTap path
                    // (offset → image-detect → onOpenImage → viewer), not a shortcut.
                    for unit in self.parent.viewModel.units where unit.kind == .image || unit.kind == .table {
                        guard let imageID = unit.metadata.imageID,
                              self.parent.viewModel.imageData(for: imageID) != nil,
                              let r = layout.unitRange(unit.id) else { continue }
                        self.surface.onTap?(r.location)
                        break
                    }
                }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: .remoteTapAt)
                .receive(on: RunLoop.main)
                .sink { [weak self] note in
                    guard let self,
                          let x = note.userInfo?["x"] as? Double,
                          let y = note.userInfo?["y"] as? Double else { return }
                    let tv = self.surface.textView
                    let local = tv.convert(CGPoint(x: x, y: y), from: nil)   // window → textView space
                    // A glyph / count button under the point → fire it (opens the marker).
                    if let btn = tv.hitTest(local, with: nil) as? UIButton {
                        btn.sendActions(for: .touchUpInside)
                        return
                    }
                    // Otherwise a text / image tap at that point.
                    if let idx = self.surface.charIndex(at: local) {
                        self.surface.onTap?(idx)
                    }
                }
                .store(in: &cancellables)
        }

        /// Scroll the surface to a fraction (0…1) of its content — antenna capture framing
        /// (SCROLL_SURFACE), so any part of the page can be reliably positioned for a shot.
        private func scrollToFraction(_ f: CGFloat) {
            let tv = surface.textView
            tv.layoutManager.ensureLayout(for: tv.textContainer)
            let maxOff = max(0, tv.contentSize.height - tv.bounds.height)
            tv.setContentOffset(CGPoint(x: 0, y: maxOff * max(0, min(1, f))), animated: true)
        }

        /// Apply every per-update diff: rebuild on content/font change, move the
        /// read-along band, refresh annotation glyphs, follow search.
        func sync(with vm: ReaderViewModel) {
            let token = Self.contentToken(vm)
            if token != builtContentToken || vm.fontSize != builtFontSize {
                build(from: vm)                 // structural change → full rebuild + re-apply
                return
            }
            // Read-along dial can change without a rebuild (Preferences picker / antenna);
            // the engine reads tuning live on the next spoken word, so this is enough.
            surface.tuning.readAlongGranularity = vm.readAlongGranularity
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
            conversationMarkerIDs.removeAll()
            conversationStorageByMarkerID.removeAll()
            // Anchors and citations are the SAME kind of thing — a pointer from a document
            // spot to this doc's one conversation (Mark, 2026-06-26). No special-casing, no
            // hiding: every pointer gets a bubble; where two land on one line the shared
            // count-badge fans them out, exactly like notes/bookmarks. The only thing we
            // skip is a LITERAL duplicate (same line + same target turn) — that's two doors
            // to the identical spot, pure noise, not distinct information.
            var seenConversationDoors: Set<String> = []

            func surfaceRange(forPlainOffset offset: Int) -> NSRange? {
                guard let idx = vm.segments.lastIndex(where: { $0.startOffset <= offset })
                        ?? (vm.segments.isEmpty ? nil : 0),
                      let seg = layout.segment(forPlaybackIndex: idx) else { return nil }
                return seg.range
            }

            // ONE placement system for every glyph (Mark, 2026-06-26): re-find each
            // mark's spot by its WORDS, not a raw character number, so it survives an
            // OCR/AFM rewrite. Built ONCE per pass (the only O(n) cost); each glyph's
            // fast path is a slice-equality at its stored offset — no search unless the
            // text actually drifted. Then the re-found offset snaps to its sentence via
            // the existing `surfaceRange(forPlainOffset:)` (display unchanged).
            let refinder = AnchorRefinder(plainText: vm.document.plainText)

            for note in vm.notes {
                let off = refinder.refine(near: note.startOffset, anchorText: note.anchorText,
                                          contextBefore: note.contextBefore, contextAfter: note.contextAfter)
                guard let r = surfaceRange(forPlainOffset: off) else { continue }
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

            // Helper: drop a conversation bubble at an ALREADY-RESOLVED offset, opening the
            // conversation at `storageID`. `label` is the fan-out menu title when this
            // bubble shares a line with others. (`rawOffset > docContentEnd` would have been
            // a document-scope sentinel — callers screen those before resolving.)
            func addConversationMarker(atOffset off: Int, storageID: String, label: String) {
                guard let r = surfaceRange(forPlainOffset: off) else { return }
                guard seenConversationDoors.insert("\(r.location)#\(storageID)").inserted else { return }
                let markerID = UUID()
                conversationMarkerIDs.insert(markerID)
                conversationStorageByMarkerID[markerID] = storageID
                markers.append(SurfaceMarker(
                    id: markerID, surfaceRange: r, unsure: false,
                    symbol: "bubble.left.fill",
                    label: label))
            }

            // The user's pointers: anchors. The stored offset is a RAW (non-durable) one, so
            // re-find the anchored passage by its WORDS — multi-slice, tolerant to an interior
            // word change. A document-scope conversation carries a sentinel offset
            // (> docContentEnd) and is skipped.
            for row in vm.conversationAnchorRows() {
                guard let raw = row.anchorOffset, raw >= 0, raw <= docContentEnd else { continue }
                let off = refinder.refinePassage(near: raw, passage: row.content)
                addConversationMarker(atOffset: off, storageID: row.id, label: "Conversation")
            }

            // The model's pointers: citations. `cited.offset` is already the DURABLE
            // unit-anchor resolution; the fingerprint just confirms/refines it by content.
            for cited in vm.conversationCitedPassages() {
                guard cited.offset >= 0, cited.offset <= docContentEnd else { continue }
                let off = refinder.refine(near: cited.offset, anchorText: cited.anchorText,
                                          contextBefore: nil, contextAfter: nil)
                addConversationMarker(atOffset: off, storageID: cited.turnStorageID, label: "Cited passage")
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
