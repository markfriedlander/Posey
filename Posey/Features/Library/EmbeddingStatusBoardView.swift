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
    /// id → title, refreshed on the timer so per-doc stage rows can name the book.
    @State private var titles: [UUID: String] = [:]

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section("Now") { activityContent }
                Section("Backfill control") { backfillControl }
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

    // MARK: - Now (full pipeline: backfill + embedding + RAPTOR + queue)

    @ViewBuilder
    private var activityContent: some View {
        let embeds = indexing.indexingProgress.sorted { $0.key.uuidString < $1.key.uuidString }
        let raptors = indexing.reReadingProgress.sorted { $0.key.uuidString < $1.key.uuidString }
        let queuedCount = indexing.embedQueuePositions.count
        let backfillActive = isBackfillRunning

        // Nothing anywhere → idle.
        if !backfillActive && embeds.isEmpty && raptors.isEmpty && queuedCount == 0 && !backfillTerminal {
            Label("Idle — nothing in the pipeline right now", systemImage: "moon.zzz")
                .foregroundStyle(.secondary)
        }

        // 1) Backfill (inactive-backend fill).
        switch backfill.phase {
        case .running(let backend, let processed, let total):
            activityRow(title: "Backfilling \(displayName(backend))",
                        systemImage: "square.stack.3d.up", processed: processed,
                        total: total, showRate: true)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        case .refusedSwapInProgress:
            Label("Backfill paused — a backend swap is in progress", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .done(let filled):
            let n = filled.values.reduce(0, +)
            Label("Backfill complete — \(n) embedded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .idle:
            EmptyView()
        }

        // 2) Embedding (per in-flight document — "Reading ahead").
        ForEach(embeds, id: \.key) { id, prog in
            activityRow(title: "Reading ahead — \(title(id))",
                        systemImage: "book", processed: prog.processed,
                        total: prog.total, showRate: false)
        }

        // 3) RAPTOR (per in-flight document — "Studying up").
        ForEach(raptors, id: \.key) { id, frac in
            let pct = Int((frac * 100).rounded())
            stageRow(title: "Studying up (RAPTOR) — \(title(id))",
                     systemImage: "brain", fraction: frac, detail: "\(pct)%")
        }

        // 4) Queue depth (waiting to embed).
        if queuedCount > 0 {
            Label("\(queuedCount) document\(queuedCount == 1 ? "" : "s") queued to embed",
                  systemImage: "tray.full").foregroundStyle(.secondary).font(.callout)
        }
    }

    /// A stage row with a fractional bar (0…1) and a free-text detail.
    private func stageRow(title: String, systemImage: String, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.callout.weight(.medium))
            ProgressView(value: max(0, min(1, fraction)))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Backfill control (Start / Stop — Mark's "like the eject Stop")

    @ViewBuilder
    private var backfillControl: some View {
        if isBackfillRunning {
            Button(role: .destructive) {
                EmbeddingBackfillCoordinator.shared.cancel()
            } label: {
                Label("Stop backfill", systemImage: "stop.circle.fill")
            }
            .accessibilityIdentifier("board.stopBackfill")
            .remoteRegister("board.stopBackfill") { EmbeddingBackfillCoordinator.shared.cancel() }
        } else {
            Button {
                startBackfill()
            } label: {
                Label("Start backfill (fill other embedders)", systemImage: "play.circle.fill")
            }
            .disabled(EmbeddingBackend.isSwapInProgress || allInactiveComplete)
            .accessibilityIdentifier("board.startBackfill")
            .remoteRegister("board.startBackfill") { startBackfill() }
            if allInactiveComplete {
                Text("All other embedders are already complete.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if EmbeddingBackend.isSwapInProgress {
                Text("A backend swap is in progress — backfill is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var allInactiveComplete: Bool {
        let active = EmbeddingBackend.current()
        let inactive = coverage.filter { $0.backend != active }
        return !inactive.isEmpty && inactive.allSatisfy { $0.isComplete }
    }

    private func startBackfill() {
        let targets = EmbeddingBackend.allCases.filter { $0 != EmbeddingBackend.current() }
        guard !targets.isEmpty else { return }
        EmbeddingBackfillCoordinator.shared.begin(targets: targets, database: databaseManager)
    }

    private var isBackfillRunning: Bool {
        if case .running = backfill.phase { return true }
        return false
    }

    private var backfillTerminal: Bool {
        switch backfill.phase {
        case .done, .error, .refusedSwapInProgress: return true
        default: return false
        }
    }

    private func title(_ id: UUID) -> String { titles[id] ?? "a document" }

    private func activityRow(title: String, systemImage: String, processed: Int, total: Int, showRate: Bool) -> some View {
        let frac = total > 0 ? Double(processed) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.callout.weight(.medium))
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
        // Title lookup for per-doc stage rows (cheap; refreshed each tick so a
        // newly-imported doc names correctly).
        if let docs = try? databaseManager.documents() {
            titles = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0.title) })
        }
        // Rate from the backfill's processed delta (timer fires every 2s). Use
        // the RAW delta (no exponential smoothing): a stalled/frozen processed
        // count must read 0/s, not decay toward a tiny non-zero that produces an
        // absurd, eventually Int-overflowing ETA (the 51,889h crash, 2026-06-19).
        if case .running(_, let processed, _) = backfill.phase {
            if lastProcessed >= 0, processed >= lastProcessed {
                rate = Double(processed - lastProcessed) / 2.0
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
        let secsD = Double(remaining) / rate
        // Overflow/sanity guard: never convert a non-finite or astronomically
        // large Double to Int (Swift TRAPS → crash). Cap at ~115 days.
        guard secsD.isFinite, secsD < 10_000_000 else { return "a while" }
        let secs = Int(secsD)
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
