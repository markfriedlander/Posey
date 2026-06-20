import SwiftUI
import Combine

// ========== BLOCK 01: EMBEDDING STATUS BOARD - START ==========

/// 2026-06-19 (Mark) — on-phone transparency into embedding work. Opened by a
/// button next to the antenna. Answers "what's happening / how much done / how
/// far to go" at a glance: the current backfill (or indexing) activity with a
/// live rate + ETA, per-backend corpus coverage bars, and the device thermal
/// state. Reads in-app live state directly (no antenna round-trip):
/// `EmbeddingBackfillCoordinator.phase` (@Published), `IndexingTracker`
/// (per-doc embed progress), `embeddingCoverage()` (refreshed on a timer).
/// DEBUG-only, like the antenna it sits beside.
struct EmbeddingStatusBoardView: View {
    let databaseManager: DatabaseManager

    @ObservedObject private var backfill = EmbeddingBackfillCoordinator.shared
    @ObservedObject private var indexing = IndexingTracker.sharedForChat
    @Environment(\.dismiss) private var dismiss

    @State private var coverage: [DatabaseManager.EmbeddingBackendCoverage] = []
    @State private var thermal: String = "—"
    /// Rate estimation across refreshes (chunks/sec) for the active backfill.
    @State private var lastProcessed: Int = -1
    @State private var rate: Double = 0

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section("Now") { activityContent }
                Section("Embedding coverage") {
                    if coverage.isEmpty {
                        Text("Reading…").foregroundStyle(.secondary)
                    } else {
                        ForEach(coverage, id: \.backend.rawValue) { coverageRow($0) }
                    }
                }
                Section("Device") {
                    LabeledContent("Thermal", value: thermal)
                    LabeledContent("Live reader (active embedder)",
                                   value: EmbeddingBackend.current().displayName)
                }
            }
            .navigationTitle("Embedding status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onReceive(timer) { _ in refresh() }
            .onAppear { refresh() }
        }
    }

    // MARK: - Now (current activity)

    @ViewBuilder
    private var activityContent: some View {
        // Backfill (inactive-backend fill) takes the headline when running.
        switch backfill.phase {
        case .running(let backend, let processed, let total):
            activityRow(
                title: "Backfilling \(displayName(backend))",
                processed: processed, total: total, showRate: true)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        case .refusedSwapInProgress:
            Label("Paused — a backend swap is in progress", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .done(let filled):
            let n = filled.values.reduce(0, +)
            Label("Backfill complete — \(n) embedded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .idle:
            indexingOrIdle
        }
    }

    /// When the backfill isn't running, show any live document indexing
    /// (import / reindex / launch-resume), else "Idle".
    @ViewBuilder
    private var indexingOrIdle: some View {
        if let id = indexing.currentIndexingDocumentID, indexing.isIndexing(id) {
            let pct = Int(((indexing.unifiedProgress(for: id) ?? 0) * 100).rounded())
            VStack(alignment: .leading, spacing: 6) {
                Text("Indexing a document").font(.callout.weight(.medium))
                ProgressView(value: Double(pct), total: 100)
                Text("\(pct)%").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Label("Idle — nothing embedding right now", systemImage: "moon.zzz")
                .foregroundStyle(.secondary)
        }
    }

    private func activityRow(title: String, processed: Int, total: Int, showRate: Bool) -> some View {
        let frac = total > 0 ? Double(processed) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            ProgressView(value: frac)
            HStack {
                Text("\(processed) / \(total)  (\(Int((frac * 100).rounded()))%)")
                Spacer()
                if showRate, rate > 0 {
                    Text("\(String(format: "%.0f", rate))/s · \(etaString(remaining: total - processed))")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Coverage row

    private func coverageRow(_ c: DatabaseManager.EmbeddingBackendCoverage) -> some View {
        let frac = c.total > 0 ? Double(c.filled) / Double(c.total) : 0
        let isActive = c.backend == EmbeddingBackend.current()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(c.backend.displayName).font(.callout.weight(isActive ? .semibold : .regular))
                if isActive {
                    Text("live").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.green.opacity(0.2)).clipShape(Capsule())
                }
                Spacer()
                if c.isComplete {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            ProgressView(value: frac)
                .tint(c.isComplete ? .green : (isActive ? .green : .blue))
            Text("\(c.filled) / \(c.total)  (\(Int((frac * 100).rounded()))%)  ·  \(c.missing) to go")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Refresh + helpers

    private func refresh() {
        coverage = (try? databaseManager.embeddingCoverage()) ?? coverage
        thermal = thermalDescription()
        // Rate from the backfill's processed delta (timer fires every 2s).
        if case .running(_, let processed, _) = backfill.phase {
            if lastProcessed >= 0, processed >= lastProcessed {
                let delta = Double(processed - lastProcessed) / 2.0
                // Smooth a little so the readout doesn't jitter.
                rate = rate == 0 ? delta : (rate * 0.6 + delta * 0.4)
            }
            lastProcessed = processed
        } else {
            lastProcessed = -1; rate = 0
        }
    }

    private func thermalDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious — paced"
        case .critical: return "Critical — paused"
        @unknown default: return "—"
        }
    }

    private func displayName(_ raw: String) -> String {
        EmbeddingBackend(rawValue: raw)?.displayName ?? raw
    }

    private func etaString(remaining: Int) -> String {
        guard rate > 0, remaining > 0 else { return "—" }
        let secs = Int(Double(remaining) / rate)
        if secs >= 3600 { return "\(secs / 3600)h \((secs % 3600) / 60)m" }
        if secs >= 60 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs)s"
    }
}

// ========== BLOCK 01: EMBEDDING STATUS BOARD - END ==========

// ========== BLOCK 02: PRESENTATION MODIFIER - START ==========

/// Presents the board as a sheet. Kept as a modifier (rather than an inline
/// `.sheet`) so the LibraryView body's modifier chain stays unconditional and
/// type-checks fast; the binding is `.constant(false)` in RELEASE, so the board
/// never presents there (it's a DEBUG dev-transparency surface).
struct EmbeddingBoardSheet: ViewModifier {
    @Binding var isPresented: Bool
    let databaseManager: DatabaseManager

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            EmbeddingStatusBoardView(databaseManager: databaseManager)
        }
    }
}

// ========== BLOCK 02: PRESENTATION MODIFIER - END ==========
