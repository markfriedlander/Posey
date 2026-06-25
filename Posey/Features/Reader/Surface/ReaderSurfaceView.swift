#if DEBUG
import SwiftUI
import UIKit
import Combine
import QuartzCore
import AVFoundation

// ========== BLOCK 01: READER SURFACE VIEW (DEBUG, STAGE B) - START ==========

/// DEBUG-only host for the rebuilt one-surface reader, opened via the antenna verb
/// `OPEN_DOCUMENT_SURFACE:<docID>` as a separate full-screen cover. It does NOT touch
/// the shipping reader or its antenna verbs — it exists so we can render REAL Posey
/// documents through the new surface and measure resident memory on the phone (the
/// Stage-B gate that decides whether windowing is needed). Risk-first: open GEB +
/// the biggest EPUB.
struct ReaderSurfaceView: View {
    let document: Document
    let databaseManager: DatabaseManager
    var onClose: () -> Void = {}

    @StateObject private var loader = ReaderSurfaceLoader()

    var body: some View {
        ZStack(alignment: .top) {
            if let surface = loader.surface {
                SurfaceTextViewRep(textView: surface.textView)
                    // Respect the top + horizontal safe area so the notch / Dynamic
                    // Island never obscures text in landscape (Mark, 2026-06-21);
                    // extend under the bottom home-indicator only. Letting SwiftUI
                    // size the view within the safe area also gives it a clean
                    // re-layout on rotation (re-flow to the new width).
                    .ignoresSafeArea(edges: .bottom)
                    // Re-pin the margin glyphs after a re-flow (rotation / size change).
                    .background(GeometryReader { geo in
                        Color.clear.onChange(of: geo.size) { _, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                surface.rebuildGlyphs()
                            }
                        }
                    })
            } else {
                ProgressView("Building surface…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            hud
        }
        .background(Color(.systemBackground))
        .task { loader.load(document: document, databaseManager: databaseManager) }
        .onAppear {
            // Re-measure layout + memory AFTER the text view has real on-screen
            // width — forcing layout before that gives a bogus (near-zero) time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { loader.measureAfterDisplay() }
        }
        .sheet(item: $loader.editingNote) { note in
            NoteEditorSheet(note: note,
                            isUnsure: loader.editingNoteIsUnsure,
                            onSave: { loader.saveNoteBody(note, body: $0) },
                            onReconfirm: { loader.reconfirmNote(note) },
                            onMoveIt: { loader.beginMove(note) },
                            onDelete: { loader.deleteNote(note) })
                .presentationDetents([.medium])
        }
        .overlay(alignment: .bottom) {
            if loader.pendingReanchorNote != nil {
                HStack(spacing: 12) {
                    Image(systemName: "hand.point.up.left.fill")
                    Text("Select the correct text for this note, then tap “Move note here.”")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Button("Cancel") { loader.cancelMove() }.font(.footnote.weight(.bold))
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12).padding(.bottom, 24)
                .transition(.move(edge: .bottom))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteScrollSurface)) { note in
            if let f = note.userInfo?["fraction"] as? Double { loader.scrollTo(fraction: CGFloat(f)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteSetSurfaceFont)) { note in
            if let pt = note.userInfo?["pointSize"] as? Double { loader.setBodyPointSize(CGFloat(pt)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteAnnotateSurface)) { note in
            if let phrase = note.userInfo?["phrase"] as? String {
                let kind: AnnotationKind = (note.userInfo?["kind"] as? String) == "bookmark" ? .bookmark : .note
                loader.annotatePhrase(phrase, kind: kind)
            }
        }
    }

    private var hud: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loader.stats)
                if loader.unsureAnchorCount > 0 {
                    Text("⚠︎ \(loader.unsureAnchorCount) note(s) need a quick look (text changed)")
                        .foregroundStyle(.orange)
                }
            }
                .font(.system(size: 11, weight: .semibold).monospaced())
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("reader.surface.hud")
            Spacer()
            VStack(spacing: 6) {
                Button("Close") { onClose() }
                    .font(.caption.weight(.bold)).padding(8)
                    .background(.regularMaterial, in: Capsule())
                Button("▶︎ Read") { loader.play() }
                    .font(.caption.weight(.bold)).padding(8)
                    .background(.regularMaterial, in: Capsule())
                Button("Stop") { loader.stop() }
                    .font(.caption.weight(.bold)).padding(8)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(10)
    }
}

/// Hosts the surface's own UITextView (it owns its scrolling).
private struct SurfaceTextViewRep: UIViewRepresentable {
    let textView: UITextView
    func makeUIView(context: Context) -> UITextView { textView }
    func updateUIView(_ uiView: UITextView, context: Context) {}
}

/// Minimal note/bookmark editor (E2). A note edits its body; a bookmark is bodyless.
/// When the note is on an UNSURE placement (the text changed under it), the editor
/// surfaces what was highlighted and offers the confirm/counter pair: **Keep it here**
/// (lock the best-guess spot) vs **Move it** (re-pick the spot). Both can be deleted.
private struct NoteEditorSheet: View {
    let note: Note
    let isUnsure: Bool
    let onSave: (String) -> Void
    let onReconfirm: () -> Void
    let onMoveIt: () -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(note: Note, isUnsure: Bool, onSave: @escaping (String) -> Void,
         onReconfirm: @escaping () -> Void, onMoveIt: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.note = note
        self.isUnsure = isUnsure
        self.onSave = onSave
        self.onReconfirm = onReconfirm
        self.onMoveIt = onMoveIt
        self.onDelete = onDelete
        _draft = State(initialValue: note.body ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if isUnsure {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("The text here changed since you made this note",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                            if let a = note.anchorText, !a.isEmpty {
                                Text("You highlighted: “\(a)”")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Text("This is our best guess at where it belongs.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button { onReconfirm(); dismiss() } label: {
                            Label("Keep it here", systemImage: "checkmark.circle.fill")
                        }
                        .accessibilityIdentifier("surface.note.keephere")
                        Button { onMoveIt() } label: {
                            Label("Move it — I’ll pick the spot", systemImage: "hand.point.up.left.fill")
                        }
                        .accessibilityIdentifier("surface.note.moveit")
                    }
                }
                if note.kind == .note {
                    Section("Note") {
                        TextField("Write a note…", text: $draft, axis: .vertical)
                            .lineLimit(4...10)
                            .accessibilityIdentifier("surface.note.draft")
                    }
                } else {
                    Section { Label("Bookmark", systemImage: "bookmark.fill") }
                }
                Section {
                    Button("Delete", role: .destructive) { onDelete(); dismiss() }
                        .accessibilityIdentifier("surface.note.delete")
                }
            }
            .navigationTitle(note.kind == .bookmark ? "Bookmark" : "Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(draft); dismiss() }
                        .accessibilityIdentifier("surface.note.done")
                }
            }
        }
    }
}

// ========== BLOCK 01: READER SURFACE VIEW (DEBUG, STAGE B) - END ==========

// ========== BLOCK 02: LOADER + MEMORY PROBE - START ==========

@MainActor
final class ReaderSurfaceLoader: ObservableObject {
    @Published var surface: ReaderSurface?
    @Published var stats = "loading…"
    /// The note/bookmark currently open in the editor sheet (E2). nil = closed.
    @Published var editingNote: Note?
    /// Whether the open note is on an UNSURE placement (offer re-confirm in the editor).
    @Published var editingNoteIsUnsure = false
    /// A note awaiting re-placement ("Move it"): the next text selection re-anchors it.
    @Published var pendingReanchorNote: Note?
    /// Count of annotations placed UNSURELY (the text under them changed, so we drew a
    /// best-guess spot rather than a verified one). Surfaced in the HUD; tapping such a
    /// note offers re-confirm. They are never hidden.
    @Published var unsureAnchorCount = 0
    /// Which notes are currently unsure — so a tap can route to the re-confirm flow.
    private var unsureNoteIDs: Set<UUID> = []
    private var engine: ReadAlongEngine?
    private var driver: SurfaceReadAlongDriver?
    private var databaseManager: DatabaseManager?
    private var documentID: UUID?
    /// Current body point size — a stored knob so SURFACE_FONT can rebuild at a new
    /// size (E2 Step-2 re-flow durability test).
    private var bodyPointSize: CGFloat = 19

    /// Stage C: start line-level read-along from ~1/3 into the doc (real body prose,
    /// past front matter). Drives the surface's ReadAlongEngine via willSpeakRange —
    /// the same mapping Posey's SpeechPlaybackService will use at cutover.
    func play() {
        guard let driver, let surface else { return }
        let start = max(0, surface.content.layout.segments.count / 3)
        driver.speak(fromPlaybackIndex: start)
    }

    func stop() { driver?.stop() }

    /// Stage D — tap-to-jump: a tap resolves to its sentence and starts read-along
    /// from there (the surface owns the hit-test; we own the playback meaning).
    func jumpTo(surfaceOffset: Int) {
        guard let seg = surface?.content.layout.segment(atSurfaceOffset: surfaceOffset) else { return }
        driver?.speak(fromPlaybackIndex: seg.playbackIndex)
    }

    // ----- Stage E2: inline annotations (create / render / open / edit / delete) -----

    /// Render all persisted notes/bookmarks as inline markers: canonical anchor →
    /// surface range → underline + glyph. A note whose anchor no longer resolves is
    /// skipped here (Step 1); Step 2 adds re-find-or-flag so it's never silently lost.
    func loadMarkers() {
        guard let surface, let db = databaseManager, let docID = documentID else { return }
        let notes = (try? db.notes(for: docID)) ?? []
        let layout = surface.content.layout
        let docLen = surface.content.attributed.length
        var markers: [SurfaceMarker] = []
        var unsure = 0
        unsureNoteIDs.removeAll()
        for note in notes {
            let canonical = NSRange(location: note.startOffset,
                                    length: max(0, note.endOffset - note.startOffset))
            // Resolve to a placement — exact / relocated (confident) or approximate
            // (unsure). A note is NEVER skipped: if even the surface range won't resolve
            // we drop a tiny visible marker so nothing is ever lost (the floor).
            let resolution = layout.resolveAnchor(canonicalRange: canonical, anchorText: note.anchorText,
                                                  contextBefore: note.contextBefore, contextAfter: note.contextAfter)
            var sr = layout.surfaceRange(forCanonicalRange: resolution.range) ?? NSRange(location: 0, length: 0)
            if sr.length == 0, docLen > 0 {
                sr = NSRange(location: max(0, min(sr.location, docLen - 1)), length: 1)
            }
            let isBookmark = note.kind == .bookmark
            let symbol = isBookmark ? "bookmark.fill" : "square.and.pencil"
            // Menu label for when several annotations share a gutter line: kind + snippet.
            let snippet = (note.anchorText ?? note.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let shortSnippet = snippet.count > 40 ? String(snippet.prefix(40)) + "…" : snippet
            let label = (isBookmark ? "Bookmark" : "Note") + (shortSnippet.isEmpty ? "" : " · \(shortSnippet)")
            markers.append(SurfaceMarker(id: note.id, surfaceRange: sr,
                                         unsure: resolution.isUnsure, symbol: symbol, label: label))
            if resolution.isUnsure { unsure += 1; unsureNoteIDs.insert(note.id) }
        }
        surface.setMarkers(markers)
        unsureAnchorCount = unsure
    }

    /// Selection → Note/Bookmark: convert the SURFACE selection to a canonical anchor
    /// and persist it, then re-render markers. For a note, open the editor immediately
    /// so the user can type the body.
    func createAnnotation(surfaceRange: NSRange, kind: AnnotationKind) {
        guard let canonical = surface?.content.layout.canonicalRange(forSurfaceRange: surfaceRange),
              let note = createFromCanonical(canonical, kind: kind) else { return }
        if kind == .note { editingNote = note }
    }

    /// Create an annotation from a CANONICAL range, capturing the R8 durable anchor
    /// (exact substring + context) so it can be re-found or flagged if a later text
    /// mutation drifts offsets. Shared by the selection menu and the test verb.
    @discardableResult
    func createFromCanonical(_ canonical: NSRange, kind: AnnotationKind) -> Note? {
        guard let surface, let db = databaseManager, let docID = documentID, canonical.length > 0 else { return nil }
        let layout = surface.content.layout
        let anchorText = layout.canonicalText(forCanonicalRange: canonical)
        let ctx = layout.canonicalContext(forCanonicalRange: canonical, window: 24)
        let now = Date()
        let note = Note(id: UUID(), documentID: docID, createdAt: now, updatedAt: now,
                        kind: kind == .bookmark ? .bookmark : .note,
                        startOffset: canonical.location, endOffset: NSMaxRange(canonical), body: nil,
                        anchorText: anchorText, contextBefore: ctx.before, contextAfter: ctx.after)
        guard (try? db.insertNote(note)) != nil else { return nil }
        loadMarkers()
        return note
    }

    /// TEST (E2 R8): annotate the first occurrence of `phrase` in the canonical text —
    /// lets the antenna create a real R8-anchored annotation without an interactive
    /// text selection, so the full re-find/flag cycle is autonomously verifiable.
    @discardableResult
    func annotatePhrase(_ phrase: String, kind: AnnotationKind) -> Bool {
        guard let surface, !phrase.isEmpty else { return false }
        let full = surface.content.layout.fullCanonicalText()
        guard let r = full.range(of: phrase) else { return false }
        let start = full.distance(from: full.startIndex, to: r.lowerBound)
        let len = full.distance(from: r.lowerBound, to: r.upperBound)
        return createFromCanonical(NSRange(location: start, length: len), kind: kind) != nil
    }

    /// Underline tap → open the note/bookmark in the editor sheet (flagging whether it's
    /// on an unsure placement, so the editor can offer re-confirm).
    func openMarker(id: UUID) {
        guard let db = databaseManager, let docID = documentID else { return }
        let notes = (try? db.notes(for: docID)) ?? []
        if let n = notes.first(where: { $0.id == id }) {
            editingNoteIsUnsure = unsureNoteIDs.contains(id)
            editingNote = n
        }
    }

    /// Re-confirm an unsure note: the user says "yes, this spot is right." Re-capture the
    /// anchor (offsets + substring + context) at its current best-guess location so it
    /// resolves confidently from now on.
    func reconfirmNote(_ note: Note) {
        guard let surface, let db = databaseManager else { return }
        let layout = surface.content.layout
        let canonical = NSRange(location: note.startOffset, length: max(0, note.endOffset - note.startOffset))
        let placement = layout.resolveAnchor(canonicalRange: canonical, anchorText: note.anchorText,
                                             contextBefore: note.contextBefore, contextAfter: note.contextAfter).range
        let newText = layout.canonicalText(forCanonicalRange: placement)
        let ctx = layout.canonicalContext(forCanonicalRange: placement, window: 24)
        try? db.updateNoteAnchor(id: note.id, startOffset: placement.location, endOffset: NSMaxRange(placement),
                                 anchorText: newText, contextBefore: ctx.before, contextAfter: ctx.after)
        loadMarkers()
    }

    /// "Move it": arm the surface so the next text selection re-anchors THIS note.
    func beginMove(_ note: Note) {
        pendingReanchorNote = note
        surface?.awaitingMove = true
        editingNote = nil   // close the editor; the user now picks the spot
    }

    func cancelMove() {
        pendingReanchorNote = nil
        surface?.awaitingMove = false
    }

    /// The user picked the correct passage for the note being moved — re-anchor it there.
    func completeMove(toSurfaceRange surfaceRange: NSRange) {
        guard let note = pendingReanchorNote, let surface, let db = databaseManager,
              let canonical = surface.content.layout.canonicalRange(forSurfaceRange: surfaceRange),
              canonical.length > 0 else { cancelMove(); return }
        let layout = surface.content.layout
        let anchorText = layout.canonicalText(forCanonicalRange: canonical)
        let ctx = layout.canonicalContext(forCanonicalRange: canonical, window: 24)
        try? db.updateNoteAnchor(id: note.id, startOffset: canonical.location, endOffset: NSMaxRange(canonical),
                                 anchorText: anchorText, contextBefore: ctx.before, contextAfter: ctx.after)
        cancelMove()
        loadMarkers()
    }

    func saveNoteBody(_ note: Note, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        try? databaseManager?.updateNote(id: note.id, body: trimmed.isEmpty ? nil : trimmed)
        loadMarkers()
    }

    func deleteNote(_ note: Note) {
        try? databaseManager?.deleteNote(id: note.id)
        loadMarkers()
    }

    // ----- Verification tooling (antenna-driven): scroll + font re-flow -----

    /// Scroll to a fraction (0…1) of the content — lets the antenna frame any part of
    /// the surface (e.g. an annotation) for capture.
    func scrollTo(fraction: CGFloat) {
        guard let tv = surface?.textView else { return }
        tv.layoutManager.ensureLayout(for: tv.textContainer)
        let f = max(0, min(1, fraction))
        let maxOff = max(0, tv.contentSize.height - tv.bounds.height)
        tv.setContentOffset(CGPoint(x: 0, y: maxOff * f), animated: true)
    }

    /// Rebuild the surface at a new body point size and re-render annotations — the
    /// E2 Step-2 durability test: underlines must re-land on the EXACT same characters
    /// after the re-flow (canonical anchors re-resolve to the new surface ranges).
    /// Scroll position is preserved as a fraction across the re-flow.
    func setBodyPointSize(_ size: CGFloat) {
        guard let surface, let db = databaseManager, let docID = documentID else { return }
        bodyPointSize = max(10, min(48, size))
        surface.bodyPointSize = bodyPointSize   // margin glyph scales with the font
        let tv = surface.textView
        let oldMax = max(1, tv.contentSize.height - tv.bounds.height)
        let frac = oldMax > 1 ? tv.contentOffset.y / oldMax : 0

        let units = (try? db.units(for: docID)) ?? []
        let sentences = (try? db.sentences(for: docID)) ?? []
        let content = SurfaceBuilder.build(units: units, sentences: sentences,
                                           bodyPointSize: bodyPointSize,
                                           imageData: { (try? db.imageData(for: $0)) ?? nil })
        surface.reload(content: content)
        loadMarkers()

        tv.layoutManager.ensureLayout(for: tv.textContainer)
        let newMax = max(0, tv.contentSize.height - tv.bounds.height)
        tv.setContentOffset(CGPoint(x: 0, y: newMax * frac), animated: false)
    }

    private var title = ""
    private var units = 0
    private var sents = 0
    private var chars = 0
    private var buildMs = 0.0
    private var memBefore = 0.0
    private var memAfterBuild = 0.0

    func load(document: Document, databaseManager: DatabaseManager) {
        guard surface == nil else { return }
        memBefore = MemoryProbe.residentMB()
        let units = (try? databaseManager.units(for: document.id)) ?? []
        let sentences = (try? databaseManager.sentences(for: document.id)) ?? []

        let t0 = CACurrentMediaTime()
        let content = SurfaceBuilder.build(
            units: units, sentences: sentences, bodyPointSize: bodyPointSize,
            imageData: { (try? databaseManager.imageData(for: $0)) ?? nil })
        buildMs = (CACurrentMediaTime() - t0) * 1000

        let surface = ReaderSurface(content: content)
        surface.bodyPointSize = bodyPointSize   // margin glyph scales with the font
        let engine = ReadAlongEngine(surface: surface)
        self.engine = engine
        self.driver = SurfaceReadAlongDriver(content: content, engine: engine)
        self.databaseManager = databaseManager
        self.documentID = document.id
        surface.onTap = { [weak self] offset in self?.jumpTo(surfaceOffset: offset) }
        surface.onAnnotate = { [weak self] range, kind in self?.createAnnotation(surfaceRange: range, kind: kind) }
        surface.onOpenMarker = { [weak self] id in self?.openMarker(id: id) }
        surface.onMoveHere = { [weak self] range in self?.completeMove(toSurfaceRange: range) }
        memAfterBuild = MemoryProbe.residentMB()

        self.title = document.title
        self.units = units.count
        self.sents = content.layout.segments.count
        self.chars = content.attributed.length
        self.surface = surface
        loadMarkers()
        self.stats = String(format:
            "%@\nunits %d · sent %d · chars %d\nbuild %.0fms · mem %.0f→%.0f MB\n(measuring layout after display…)",
            title, self.units, sents, chars, buildMs, memBefore, memAfterBuild)
    }

    /// Run AFTER the text view has real on-screen width: force the full glyph layout
    /// (the true open-blocking cost), then read the post-display footprint. This is
    /// the number the on-device memory gate uses.
    func measureAfterDisplay() {
        guard let surface, surface.textView.bounds.width > 1 else { return }
        let t1 = CACurrentMediaTime()
        let lm = surface.textView.layoutManager
        lm.ensureLayout(for: surface.textView.textContainer)
        let height = lm.usedRect(for: surface.textView.textContainer).height
        let layoutMs = (CACurrentMediaTime() - t1) * 1000
        let memAfterLayout = MemoryProbe.residentMB()
        // Margin glyphs need real on-screen layout to position; load() ran pre-display.
        surface.rebuildGlyphs()
        self.stats = String(format:
            "%@\nunits %d · sent %d · chars %d\nbuild %.0fms · LAYOUT %.0fms · h %.0fpt\nmem %.0f→%.0f→%.0f MB (Δ+%.0f, post-display)",
            title, units, sents, chars, buildMs, layoutMs, height,
            memBefore, memAfterBuild, memAfterLayout, memAfterLayout - memBefore)
    }
}

enum MemoryProbe {
    static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576.0
    }
}

// ========== BLOCK 02: LOADER + MEMORY PROBE - END ==========

// ========== BLOCK 03: STAGE-C READ-ALONG DRIVER (DEBUG) - START ==========

/// Speaks consecutive sentences (each a WHOLE sentence → real prosody) and maps each
/// `willSpeakRange(word)` to the surface via the ReadAlongEngine. Stands in for
/// Posey's SpeechPlaybackService in the isolated cover; the engine/surface don't know
/// or care which source drives them, so the cutover swap is mechanical.
@MainActor
final class SurfaceReadAlongDriver: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let content: ReaderSurfaceContent
    private let engine: ReadAlongEngine
    /// utterance → the playback index of the sentence it speaks.
    private var utterancePlaybackIndex: [ObjectIdentifier: Int] = [:]
    /// How many sentences to queue per Read (a chunk — a few minutes of audio).
    /// The TRULY continuous, windowed read-through is the real SpeechPlaybackService's
    /// job at cutover; the rolling-window re-enqueue tried here caused repeats, so the
    /// stub stays on the proven batch queue (Mark, 2026-06-21).
    private let batchCount = 60

    init(content: ReaderSurfaceContent, engine: ReadAlongEngine) {
        self.content = content
        self.engine = engine
        super.init()
        synth.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Queue a batch of whole sentences from `start`. Uses the system "best available"
    /// (Siri-quality / Spoken Content) voice — the SAME path Posey's real
    /// SpeechPlaybackService uses for `VoiceMode.bestAvailable`. Device-confirmed it's
    /// the Siri voice AND that `willSpeakRange` fires on it (the keystone risk closed).
    func speak(fromPlaybackIndex start: Int) {
        synth.stopSpeaking(at: .immediate)
        engine.reset()
        utterancePlaybackIndex.removeAll()
        for i in start..<(start + batchCount) {
            guard let seg = content.layout.segment(forPlaybackIndex: i) else { break }
            let u = AVSpeechUtterance(string: seg.text)        // whole sentence → prosody
            u.prefersAssistiveTechnologySettings = true        // best-available system voice
            utterancePlaybackIndex[ObjectIdentifier(u)] = i
            synth.speak(u)
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        engine.reset()
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            guard let idx = utterancePlaybackIndex[ObjectIdentifier(utterance)] else { return }
            engine.onSpokenWord(playbackIndex: idx, wordOffset: characterRange.location)
        }
    }
}

// ========== BLOCK 03: STAGE-C READ-ALONG DRIVER (DEBUG) - END ==========
#endif
