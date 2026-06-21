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
                    .ignoresSafeArea()
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
    }

    private var hud: some View {
        HStack(alignment: .top) {
            Text(loader.stats)
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

// ========== BLOCK 01: READER SURFACE VIEW (DEBUG, STAGE B) - END ==========

// ========== BLOCK 02: LOADER + MEMORY PROBE - START ==========

@MainActor
final class ReaderSurfaceLoader: ObservableObject {
    @Published var surface: ReaderSurface?
    @Published var stats = "loading…"
    private var engine: ReadAlongEngine?
    private var driver: SurfaceReadAlongDriver?

    /// Stage C: start line-level read-along from ~1/3 into the doc (real body prose,
    /// past front matter). Drives the surface's ReadAlongEngine via willSpeakRange —
    /// the same mapping Posey's SpeechPlaybackService will use at cutover.
    func play() {
        guard let driver, let surface else { return }
        let start = max(0, surface.content.layout.segments.count / 3)
        driver.speak(fromPlaybackIndex: start, count: 25)
    }

    func stop() { driver?.stop() }

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
            units: units, sentences: sentences, bodyPointSize: 19,
            imageData: { (try? databaseManager.imageData(for: $0)) ?? nil })
        buildMs = (CACurrentMediaTime() - t0) * 1000

        let surface = ReaderSurface(content: content)
        let engine = ReadAlongEngine(surface: surface)
        self.engine = engine
        self.driver = SurfaceReadAlongDriver(content: content, engine: engine)
        memAfterBuild = MemoryProbe.residentMB()

        self.title = document.title
        self.units = units.count
        self.sents = content.layout.segments.count
        self.chars = content.attributed.length
        self.surface = surface
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

    init(content: ReaderSurfaceContent, engine: ReadAlongEngine) {
        self.content = content
        self.engine = engine
        super.init()
        synth.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func speak(fromPlaybackIndex start: Int, count: Int) {
        synth.stopSpeaking(at: .immediate)
        engine.reset()
        utterancePlaybackIndex.removeAll()
        for i in start..<(start + count) {
            guard let seg = content.layout.segment(forPlaybackIndex: i) else { break }
            let u = AVSpeechUtterance(string: seg.text)   // whole sentence → prosody
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
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
