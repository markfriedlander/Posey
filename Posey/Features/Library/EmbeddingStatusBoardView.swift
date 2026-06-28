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
    /// Storage + memory diagnostics, refreshed on the timer (all cheap reads).
    @State private var dbBytes: Int64 = 0
    @State private var availMB: Double = 0
    @State private var footprintMB: Double = 0
    /// Master "Allow background preparation" switch — persisted; mirrors the
    /// queue's gate. Toggling calls `DocumentIndexingQueue.setBackgroundPrep`
    /// (syncs the actor flag + resumes). Default ON preserves prior behavior.
    @AppStorage(DocumentIndexingQueue.backgroundPrepDefaultsKey) private var backgroundPrepEnabled = true

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            // ScrollViewReader so the antenna can scroll the board to any section
            // for capture/verification (TAP board.scroll*) — see scroll actions below.
            ScrollViewReader { proxy in
            List {
                Section {
                    activityContent
                } header: {
                    Text("Now — live activity, per document")
                } footer: {
                    Text("Each title moves through 3 steps:  1 Chunking  →  2 Embedding (\u{201C}reading ahead\u{201D})  →  3 Summary tree (\u{201C}studying up\u{201D} / RAPTOR).  PDFs add a prep OCR pass before step 1.")
                }
                .id("board.top")
                Section {
                    Toggle("Allow background preparation", isOn: $backgroundPrepEnabled)
                        .onChange(of: backgroundPrepEnabled) { _, on in
                            Task { await DocumentIndexingQueue.shared.setBackgroundPrep(on) }
                        }
                        .accessibilityIdentifier("board.bgPrepToggle")
                } header: {
                    Text("Controls")
                } footer: {
                    Text("ON: Posey works through the queue in the background, paced by the phone's temperature (it won't overheat). OFF: the queue still SHOWS what's waiting, but nothing RUNS until you switch it back on — including after a relaunch. (In-flight work stops after the current document.)")
                }
                Section("Backfill control") { backfillControl }
                Section {
                    if coverage.isEmpty {
                        Text("Reading…").foregroundStyle(.secondary)
                    } else {
                        ForEach(coverage, id: \.backend.rawValue) { coverageRow($0) }
                    }
                } header: {
                    Text("Embedding coverage — library-wide totals")
                } footer: {
                    Text("Totals across EVERY document in your library, summed per embedder — not one title. Step 2 (embedding) is what fills these.")
                }
                Section {
                    LabeledContent("Database on disk", value: formatBytes(dbBytes))
                    ForEach(coverage, id: \.backend.rawValue) { c in
                        let bytes = Int64(c.filled) * Int64(c.backend.dimension) * 4
                        LabeledContent("· \(c.backend.displayName)",
                                       value: "\(formatBytes(bytes))  ·  \(c.filled) × \(c.backend.dimension)d")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("The database holds chunk text + ALL three embedders' vectors + RAPTOR summaries. Per-embedder estimate = embedded chunks × dimension × 4 bytes — the real cost of keeping every embedder around.")
                }
                .id("board.storage")
                Section {
                    LabeledContent("Free to allocate (headroom)",
                                   value: availMB.isFinite ? "\(Int(availMB)) MB" : "—")
                    LabeledContent("This app is using",
                                   value: footprintMB > 0 ? "\(Int(footprintMB)) MB" : "—")
                    LabeledContent("Device RAM",
                                   value: formatBytes(Int64(ProcessInfo.processInfo.physicalMemory)))
                } header: {
                    Text("Memory")
                } footer: {
                    Text("\u{201C}Free to allocate\u{201D} is how much MORE this app can use before iOS force-quits it (jetsam) — the number that matters for not overloading the phone. Per-feature CPU/memory isn't available on iOS, so these are app-wide.")
                }
                .id("board.memory")
                Section("Device") {
                    LabeledContent("Thermal", value: thermal)
                    LabeledContent("Active embedder", value: EmbeddingBackend.current().displayName)
                }
                .id("board.device")
            }
            .navigationTitle("Preparation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onReceive(timer) { _ in refresh() }
            .onAppear { refresh() }
            // Antenna scroll affordances (capture/verify any section): TAP these ids.
            .remoteRegister("board.scrollTop") { withAnimation { proxy.scrollTo("board.top", anchor: .top) } }
            .remoteRegister("board.scrollStorage") { withAnimation { proxy.scrollTo("board.storage", anchor: .top) } }
            .remoteRegister("board.scrollMemory") { withAnimation { proxy.scrollTo("board.memory", anchor: .top) } }
            .remoteRegister("board.scrollBottom") { withAnimation { proxy.scrollTo("board.device", anchor: .bottom) } }
            // Antenna control of the master switch (toggles can't be TAP'd reliably).
            .remoteRegister("board.bgPrepOn") {
                backgroundPrepEnabled = true
                Task { await DocumentIndexingQueue.shared.setBackgroundPrep(true) }
            }
            .remoteRegister("board.bgPrepOff") {
                backgroundPrepEnabled = false
                Task { await DocumentIndexingQueue.shared.setBackgroundPrep(false) }
            }
            }
        }
    }

    // MARK: - Now (full pipeline: backfill + embedding + RAPTOR + queue)

    @ViewBuilder
    private var activityContent: some View {
        let ocr = indexing.ocrProgress.sorted { $0.key.uuidString < $1.key.uuidString }
        let chunking = indexing.chunkingDocumentIDs.sorted { $0.uuidString < $1.uuidString }
        let embeds = indexing.indexingProgress.sorted { $0.key.uuidString < $1.key.uuidString }
        let raptors = indexing.reReadingProgress.sorted { $0.key.uuidString < $1.key.uuidString }
        let queuedCount = indexing.embedQueuePositions.count
        let backfillActive = isBackfillRunning

        // Nothing anywhere → idle.
        if !backfillActive && ocr.isEmpty && chunking.isEmpty && embeds.isEmpty
            && raptors.isEmpty && queuedCount == 0 && !backfillTerminal {
            Label("Idle — nothing in the pipeline right now", systemImage: "moon.zzz")
                .foregroundStyle(.secondary)
        }

        // Pipeline order: OCR (prep, PDF only) → 1 chunking → 2 embedding → 3 RAPTOR.
        // The "Step N of 3" prefix tells Mark where a given title is at a glance.
        // 0) Tier-2 Vision OCR (PDF page-image rescue) — a PREP pass before step 1.
        ForEach(ocr, id: \.key) { id, frac in
            let pct = Int((frac * 100).rounded())
            stageRow(title: "Prep · Reading the page images (OCR) — \(title(id))",
                     systemImage: "doc.viewfinder", fraction: frac, detail: "\(pct)%")
        }
        // 1) Chunking (string-split) — brief, no %.
        ForEach(chunking, id: \.self) { id in
            Label("Step 1 of 3 · Chunking (splitting into chunks) — \(title(id))", systemImage: "scissors")
                .font(.callout.weight(.medium))
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
            activityRow(title: "Step 2 of 3 · Embedding (reading ahead) — \(title(id))",
                        systemImage: "book", processed: prog.processed,
                        total: prog.total, showRate: false)
        }

        // 3) RAPTOR (per in-flight document — "Studying up").
        ForEach(raptors, id: \.key) { id, frac in
            let pct = Int((frac * 100).rounded())
            stageRow(title: "Step 3 of 3 · Summary tree (studying up / RAPTOR) — \(title(id))",
                     systemImage: "brain", fraction: frac, detail: "\(pct)%")
        }

        // 4) Queue (waiting to start step 2) — show the actual titles + position,
        //    not just a count, so Mark can see WHICH titles are waiting.
        let queued = indexing.embedQueuePositions.sorted { $0.value < $1.value }
        if !queued.isEmpty {
            Label("\(queued.count) title\(queued.count == 1 ? "" : "s") queued — waiting for step 2 (embedding)",
                  systemImage: "tray.full").foregroundStyle(.secondary).font(.callout.weight(.medium))
            ForEach(queued, id: \.key) { id, pos in
                Text("·  #\(pos)  \(title(id))")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        dbBytes = databaseManager.databaseFileBytes()
        availMB = processAvailableMemoryMB()
        footprintMB = processFootprintMB()
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

    /// MB under 1 GB, else GB with two decimals. Dev-board readability.
    private func formatBytes(_ b: Int64) -> String {
        let mb = Double(b) / (1024.0 * 1024.0)
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024.0) : String(format: "%.0f MB", mb)
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
