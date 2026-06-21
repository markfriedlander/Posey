#if DEBUG
import SwiftUI
import UIKit
import Combine
import QuartzCore

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
    }

    private var hud: some View {
        HStack(alignment: .top) {
            Text(loader.stats)
                .font(.system(size: 11, weight: .semibold).monospaced())
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("reader.surface.hud")
            Spacer()
            Button("Close") { onClose() }
                .font(.caption.weight(.bold))
                .padding(8)
                .background(.regularMaterial, in: Capsule())
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

    func load(document: Document, databaseManager: DatabaseManager) {
        guard surface == nil else { return }
        let memBefore = MemoryProbe.residentMB()
        let units = (try? databaseManager.units(for: document.id)) ?? []
        let sentences = (try? databaseManager.sentences(for: document.id)) ?? []

        let t0 = CACurrentMediaTime()
        let content = SurfaceBuilder.build(
            units: units, sentences: sentences, bodyPointSize: 19,
            imageData: { (try? databaseManager.imageData(for: $0)) ?? nil })
        let buildMs = (CACurrentMediaTime() - t0) * 1000

        let surface = ReaderSurface(content: content)
        let memAfterBuild = MemoryProbe.residentMB()

        // Force the full first layout (the cost that would block on open) and time it.
        let t1 = CACurrentMediaTime()
        let lm = surface.textView.layoutManager
        lm.ensureLayout(for: surface.textView.textContainer)
        let height = lm.usedRect(for: surface.textView.textContainer).height
        let layoutMs = (CACurrentMediaTime() - t1) * 1000
        let memAfterLayout = MemoryProbe.residentMB()

        self.surface = surface
        self.stats = String(format:
            "%@\nunits %d · sent %d · chars %d\nbuild %.0fms · layout %.0fms · h %.0fpt\nmem %.0f→%.0f→%.0f MB (Δ+%.0f)",
            document.title, units.count, content.layout.segments.count, content.attributed.length,
            buildMs, layoutMs, height,
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
#endif
