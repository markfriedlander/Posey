// MLXModelDownloader.swift
// Posey
//
// Faithful port of Hal Universal/MLXModelDownloader.swift (2026-05-26).
// Rule 9 Part A diff: docs-internal/MLX-PORT-DIFF-2026-05-26.md
//
// Two cooperating classes, both singletons:
//
//   BackgroundDownloadCoordinator — the low-level transport. Owns one
//   foreground URLSession and one background URLSession; enqueues a
//   download task per file in a model's repo; migrates tasks between
//   the two sessions on app-lifecycle transitions; persists per-task
//   metadata so background-session callbacks delivered after a relaunch
//   can route correctly. Posts `.mlxModelDidDownload` when every file for
//   a model has landed.
//
//   MLXModelDownloader — the higher-level coordinator. Holds the
//   user-facing @Published `downloadStates` dict that the picker UI
//   binds to; manages a queue of downloads (one active, others
//   waiting); handles disk-space pre-flight; persists in-flight markers
//   so a download interrupted by termination resumes on next launch;
//   listens for the coordinator's completion notification and updates
//   `downloadedModelIDs` for the runtime "is this model present?" check.
//
// Posey-side substitutions vs Hal:
//   - halLog → dbgLog (Posey's in-app circular buffer; same printf shape)
//   - ModelCatalogService.shared.getModel(byID:) → ModelCatalog.model(id:)
//   - background session id → com.MarkFriedlander.Posey.modelDownload.v1
//   - HALDEBUG-* log tags → MLX-DL-* / MLX-DETECTION-* / MLX-CACHE-*
//   - Notification name kept as .mlxModelDidDownload (no collision)
//
// All behavior is faithfully ported. No silent reinterpretation. The
// load-bearing fix is Section 4 of the diff: download via the PUBLIC
// HF tree+resolve endpoints, then load via ModelConfiguration(directory:)
// — which fixes the auth-path failures on Qwen/Dolphin/Gemma.

import Foundation
import SwiftUI
import Combine
import UIKit


// ==== BLOCK 01: BACKGROUND DOWNLOAD COORDINATOR - START ====

// MARK: - Background Download Coordinator
//
// True iOS-style background downloader for HuggingFace MLX models. Replaces
// the auth'd HubApi.snapshot path with a `URLSessionConfiguration.background`
// session that uses the public HF tree+resolve endpoints (no auth required),
// fixing the 401/network failures that broke Qwen/Dolphin/Gemma in Posey's
// pre-port MLXService.
//
// Design overview:
//   - One URLSession with a fixed background identifier (process-wide singleton).
//   - For each model, we fetch the file list from the HF tree API, filter by
//     MLX-compatible patterns (*.safetensors, *.json, *.jinja — same set
//     mlx-swift-lm uses), and enqueue a download task per file.
//   - Per-task metadata (modelID, target path) is persisted in UserDefaults
//     so callbacks delivered after a relaunch can route correctly even
//     though the in-memory map was wiped by termination.
//   - When all files for a model land, we post `.mlxModelDidDownload`.
final class BackgroundDownloadCoordinator: NSObject, URLSessionDownloadDelegate, ObservableObject {
    static let shared = BackgroundDownloadCoordinator()

    /// Background URLSession identifier. Must be stable across app launches so
    /// iOS can reconnect us to in-flight downloads from a previous run.
    static let backgroundSessionID = "com.MarkFriedlander.Posey.modelDownload.v1"

    /// Completion handler passed in by `PoseyAppDelegate`. Invoked once all
    /// pending background events have been processed so iOS knows it's safe
    /// to suspend us again.
    var backgroundCompletionHandler: (() -> Void)?

    // MARK: - Per-Task Metadata (session-aware)
    //
    // Two storage backends:
    //   - Background tasks: persisted to UserDefaults. Background URLSession
    //     tasks survive app termination, so on relaunch we need to look up
    //     each reconnected task's modelID/filename/target to route delegate
    //     callbacks correctly.
    //   - Foreground tasks: in-memory only. Foreground URLSession tasks die
    //     with the app, so persistence would be pointless. Lighter weight.
    struct TaskContext: Codable {
        let modelID: String
        let filename: String
        let targetPath: String
    }

    private let taskContextDefaultsKey = "bgDownloadTaskContexts.v1"

    private var backgroundTaskContexts: [String: TaskContext] {
        get {
            guard let data = UserDefaults.standard.data(forKey: taskContextDefaultsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: TaskContext].self, from: data)) ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: taskContextDefaultsKey)
            }
        }
    }

    private var foregroundTaskContexts: [Int: TaskContext] = [:]

    private func contextLookup(session: SessionKind, taskID: Int) -> TaskContext? {
        switch session {
        case .foreground: return foregroundTaskContexts[taskID]
        case .background: return backgroundTaskContexts[String(taskID)]
        }
    }

    private func saveContext(_ context: TaskContext, session: SessionKind, taskID: Int) {
        switch session {
        case .foreground:
            foregroundTaskContexts[taskID] = context
        case .background:
            var contexts = backgroundTaskContexts
            contexts[String(taskID)] = context
            backgroundTaskContexts = contexts
        }
    }

    private func removeContext(session: SessionKind, taskID: Int) {
        switch session {
        case .foreground:
            foregroundTaskContexts.removeValue(forKey: taskID)
        case .background:
            var contexts = backgroundTaskContexts
            contexts.removeValue(forKey: String(taskID))
            backgroundTaskContexts = contexts
        }
    }

    // MARK: - Dual URLSessions
    //
    // foregroundSession — fast (~99 Mbps on a typical home connection),
    // active while app is in foreground, tasks die on suspend/terminate.
    //
    // backgroundSession — background mode, ~1.7 MB/s throttled by iOS but
    // survives suspension/lock/termination. Reconnects on relaunch.
    //
    // On didEnterBackground, foreground tasks migrate to background via
    // cancel-with-resume-data. On willEnterForeground, reverse. Matches
    // Apple's canonical pattern (App Store, Podcasts, Music).

    enum SessionKind { case foreground, background }

    struct TaskKey: Hashable {
        let session: SessionKind
        let id: Int
    }

    private lazy var foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        config.allowsCellularAccess = true
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    private func sessionKind(of session: URLSession) -> SessionKind {
        return session === foregroundSession ? .foreground : .background
    }

    private var lifecycleObservers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        dbgLog("MLX-DL: BackgroundDownloadCoordinator init; will lazily create URLSessions (fg + bg id=%@)", Self.backgroundSessionID)
        // Touch the lazy background session so iOS immediately replays any
        // pending events from a previous app instance.
        _ = backgroundSession
        setupLifecycleObservers()
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupLifecycleObservers() {
        let bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.migrateForegroundTasksToBackground() }
        }
        let fgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.migrateBackgroundTasksToForeground() }
        }
        lifecycleObservers = [bgObserver, fgObserver]
    }

    // MARK: - Public API

    /// Kick off a background download for every file in the repo that matches
    /// the MLX patterns. Returns immediately. Use `progress(for:)` /
    /// `isComplete(for:)` to track state. Posts `.mlxModelDidDownload` when
    /// ALL files for the model have finished landing.
    func startDownload(modelID: String, repoID: String) async throws {
        dbgLog("MLX-DL: startDownload modelID=%@ repoID=%@", modelID, repoID)

        // DEDUP: cancel any in-flight tasks for this model in EITHER session
        // before enqueuing fresh ones. Without this, repeat calls accumulate
        // duplicate tasks racing for the same bytes.
        var cancelledCount = 0
        for session in [foregroundSession, backgroundSession] {
            let kind = sessionKind(of: session)
            let snapshot = await session.allTasks
            for task in snapshot {
                guard let context = contextLookup(session: kind, taskID: task.taskIdentifier),
                      context.modelID == modelID else { continue }
                if task.state == .running || task.state == .suspended {
                    task.cancel()
                    cancelledCount += 1
                }
            }
        }
        if cancelledCount > 0 {
            dbgLog("MLX-DL: Cancelled %d stale in-flight task(s) for %@", cancelledCount, modelID)
        }

        // Fetch the file list (with HF sizes) from the tree API.
        let allFiles = try await fetchRepoFileList(repoID: repoID)
        let mlxFiles = allFiles.filter { Self.matchesMLXPattern($0.path) }
        if mlxFiles.isEmpty {
            dbgLog("MLX-DL: No MLX-compatible files in %@; aborting", repoID)
            throw NSError(domain: "BackgroundDownloadCoordinator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No MLX-compatible files found in repository \(repoID)."
            ])
        }
        let mlxFilenames = mlxFiles.map { $0.path }
        dbgLog("MLX-DL: Found %d MLX files for %@", mlxFiles.count, modelID)

        let modelDir = modelDirectory(for: modelID)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // 2026-06-17 — FIXED progress total. Sum the HF file sizes NOW so the
        // denominator is known from byte 0; the % climbs monotonically instead
        // of lurching as each task reports its expected size. Fall back to the
        // legacy dynamic accumulation only if HF gave us no sizes (total ≤ 0).
        let fixedTotal = mlxFiles.reduce(Int64(0)) { $0 + $1.size }
        if fixedTotal > 0 {
            bytesExpectedByModel[modelID] = fixedTotal
            modelsWithFixedExpected.insert(modelID)
            dbgLog("MLX-DL: fixed total for %@ = %lld bytes (%d files)", modelID, fixedTotal, mlxFiles.count)
        } else {
            bytesExpectedByModel[modelID] = 0
            modelsWithFixedExpected.remove(modelID)
            dbgLog("MLX-DL: no HF sizes for %@; falling back to dynamic expected", modelID)
        }
        bytesWrittenByModel[modelID] = 0
        filesPendingByModel[modelID] = Set(mlxFilenames)

        let appActive = await MainActor.run { UIApplication.shared.applicationState == .active }
        let chosenSession = appActive ? foregroundSession : backgroundSession
        let chosenKind: SessionKind = appActive ? .foreground : .background
        dbgLog("MLX-DL: Enqueuing on %@ session (app state: %@)",
               chosenKind == .foreground ? "FOREGROUND" : "BACKGROUND",
               appActive ? "active" : "inactive/background")

        for file in mlxFiles {
            let filename = file.path
            let targetURL = modelDir.appendingPathComponent(filename)
            if let existingSize = try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int64,
               existingSize > 0 {
                dbgLog("MLX-DL: %@ already present (%lld bytes); skipping", filename, existingSize)
                // Count the already-present bytes toward the fixed total so the
                // bar reflects real completion (skipped files never report via a
                // download task).
                if modelsWithFixedExpected.contains(modelID) {
                    bytesWrittenByModel[modelID, default: 0] += existingSize
                }
                var pending = filesPendingByModel[modelID] ?? []
                pending.remove(filename)
                filesPendingByModel[modelID] = pending
                continue
            }

            guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(filename)") else {
                dbgLog("MLX-DL: Could not build URL for %@; skipping", filename)
                continue
            }

            let task = chosenSession.downloadTask(with: url)
            let context = TaskContext(modelID: modelID, filename: filename, targetPath: targetURL.path)
            saveContext(context, session: chosenKind, taskID: task.taskIdentifier)
            task.resume()
            dbgLog("MLX-DL: Enqueued %@ task %d for %@",
                   chosenKind == .foreground ? "fg" : "bg",
                   task.taskIdentifier, filename)
        }

        if (filesPendingByModel[modelID] ?? []).isEmpty {
            await MainActor.run { self.notifyModelDownloadComplete(modelID: modelID) }
        }
    }

    // MARK: - Per-Model Progress Tracking

    @Published var bytesWrittenByModel: [String: Int64] = [:]
    @Published var bytesExpectedByModel: [String: Int64] = [:]
    private var filesPendingByModel: [String: Set<String>] = [:]
    /// Models whose `bytesExpectedByModel` is a FIXED total summed from HF file
    /// sizes (2026-06-17). For these, `didWriteData` must NOT mutate the
    /// expected total — that's what made the progress % lurch.
    private var modelsWithFixedExpected: Set<String> = []

    func progress(for modelID: String) -> Double {
        let expected = bytesExpectedByModel[modelID] ?? 0
        let written = bytesWrittenByModel[modelID] ?? 0
        guard expected > 0 else { return 0 }
        return min(1.0, Double(written) / Double(expected))
    }

    func isComplete(for modelID: String) -> Bool {
        return (filesPendingByModel[modelID] ?? []).isEmpty && (bytesExpectedByModel[modelID] ?? 0) > 0
    }

    // MARK: - HuggingFace Tree API
    //
    // GET https://huggingface.co/api/models/<repo>/tree/main
    // Returns a JSON array of {"type": "file"|"directory", "path": "...", "size": Int}
    // PUBLIC endpoint — no auth required.
    /// (path, size) per file in the repo. The `size` is the HF tree API's byte
    /// count — used to compute a FIXED download total up front (2026-06-17 fix),
    /// so the progress denominator is known from the start instead of being
    /// accumulated as tasks report (which made the % lurch — 99%→2%→… — badly
    /// for many-file repos like Qwen's 10-file multimodal build).
    private func fetchRepoFileList(repoID: String) async throws -> [(path: String, size: Int64)] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main") else {
            throw NSError(domain: "BackgroundDownloadCoordinator", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Bad repo ID: \(repoID)"
            ])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "BackgroundDownloadCoordinator", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "HF tree API returned status \(status) for \(repoID)"
            ])
        }
        struct TreeEntry: Decodable {
            let type: String
            let path: String
            let size: Int64?
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        return entries.filter { $0.type == "file" }.map { ($0.path, $0.size ?? 0) }
    }

    // MARK: - Pattern Matching
    //
    // Same set mlx-swift-lm's ModelFactory uses: *.safetensors, *.json, *.jinja.
    // The *.jinja is critical for modern chat-template models (Gemma 4 etc).
    private static func matchesMLXPattern(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".safetensors")
            || lower.hasSuffix(".json")
            || lower.hasSuffix(".jinja")
    }

    fileprivate func modelDirectory(for modelID: String) -> URL {
        // 2026-06-16 — models now live in the shared App Group container
        // (`SharedModelStore`) instead of purgeable Caches. Same
        // `huggingface/models/<id>` layout, just a different root.
        SharedModelStore.mlxModelDir(modelID)
    }

    // MARK: - Completion Notification

    @MainActor
    private func notifyModelDownloadComplete(modelID: String) {
        dbgLog("MLX-DL: Model %@ fully downloaded; posting .mlxModelDidDownload", modelID)
        MLXModelDownloader.shared.markModelAsDownloadedFromBackground(modelID: modelID)
        // 2026-06-16 — register this app's claim in the shared-store manifest so
        // a sibling app (Hal) deleting the model later only frees the files when
        // no app still claims it. `id` IS the repo path for MLX models.
        let cfg = ModelCatalog.all.first { $0.id == modelID }
        let sizeBytes = cfg?.sizeGB.map { Int64($0 * 1_073_741_824) }
        SharedModelStore.claim(modelID: modelID, repo: cfg?.repoID, sizeBytes: sizeBytes)
        // 2026-06-16 — auto-select the just-downloaded model when no usable MLX
        // model is selected yet (the picker still shows AFM/unselected). Makes
        // the model ACTIVE immediately — lights up the picker radio (selection is
        // `@AppStorage`-bound) AND makes the selection match what `answerModel()`
        // already falls through to. Only fills an EMPTY selection — never
        // overrides a model the user explicitly chose.
        let current = ModelCatalog.current()
        let hasUsableSelection = current.source == .mlx
            && MLXModelDownloader.shared.isModelDownloaded(current.id)
        if !hasUsableSelection {
            UserDefaults.standard.set(modelID, forKey: ModelCatalog.defaultsKey)
            dbgLog("MLX-DL: auto-selected %@ as the active answer model (no prior MLX selection).", modelID)
        }
        NotificationCenter.default.post(name: .mlxModelDidDownload, object: nil, userInfo: ["modelID": modelID])
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let kind = sessionKind(of: session)
        guard let context = contextLookup(session: kind, taskID: downloadTask.taskIdentifier) else {
            dbgLog("MLX-DL: didFinishDownloadingTo for unknown %@ task %d; ignoring",
                   kind == .foreground ? "fg" : "bg", downloadTask.taskIdentifier)
            return
        }

        // Synchronous move — iOS deletes `location` as soon as we return.
        let target = URL(fileURLWithPath: context.targetPath)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)
            dbgLog("MLX-DL: Moved %@ -> %@ (%@ task %d)",
                   context.filename, target.path,
                   kind == .foreground ? "fg" : "bg", downloadTask.taskIdentifier)
        } catch {
            dbgLog("MLX-DL: Move failed for %@: %@", context.filename, error.localizedDescription)
        }

        Task { @MainActor in
            var pending = self.filesPendingByModel[context.modelID] ?? []
            pending.remove(context.filename)
            self.filesPendingByModel[context.modelID] = pending
            if pending.isEmpty {
                self.notifyModelDownloadComplete(modelID: context.modelID)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let kind = sessionKind(of: session)
        guard let context = contextLookup(session: kind, taskID: downloadTask.taskIdentifier) else { return }
        let key = TaskKey(session: kind, id: downloadTask.taskIdentifier)
        Task { @MainActor in
            let prev = self.bytesWrittenByTask[key] ?? 0
            let delta = max(0, totalBytesWritten - prev)
            self.bytesWrittenByTask[key] = totalBytesWritten
            self.bytesWrittenByModel[context.modelID, default: 0] += delta

            // 2026-06-17 — only accumulate the expected total dynamically when we
            // DON'T already have a fixed total from the HF sizes. With a fixed
            // total, the denominator is constant and the % climbs smoothly; the
            // old per-task accumulation is what made it lurch.
            if totalBytesExpectedToWrite > 0,
               !self.modelsWithFixedExpected.contains(context.modelID) {
                let prevExpected = self.bytesExpectedByTask[key] ?? 0
                let expectedDelta = totalBytesExpectedToWrite - prevExpected
                if expectedDelta != 0 {
                    self.bytesExpectedByTask[key] = totalBytesExpectedToWrite
                    self.bytesExpectedByModel[context.modelID, default: 0] += expectedDelta
                }
            }

            // Throttled byte-flow logging (5-second cadence per task).
            let now = Date()
            let lastLog = self.lastByteLogTimeByTask[key] ?? .distantPast
            if now.timeIntervalSince(lastLog) >= 5.0 {
                let prevBytesAtLog = self.lastByteLogBytesByTask[key] ?? 0
                let bytesSinceLastLog = max(0, totalBytesWritten - prevBytesAtLog)
                let secondsSinceLastLog = lastLog == .distantPast ? 0 : now.timeIntervalSince(lastLog)
                let throughputMBs = secondsSinceLastLog > 0
                    ? Double(bytesSinceLastLog) / 1_048_576.0 / secondsSinceLastLog
                    : 0
                let writtenMB = Double(totalBytesWritten) / 1_048_576.0
                let expectedMB = totalBytesExpectedToWrite > 0
                    ? Double(totalBytesExpectedToWrite) / 1_048_576.0
                    : -1
                let pct = totalBytesExpectedToWrite > 0
                    ? Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
                    : -1
                let kindStr = kind == .foreground ? "fg" : "bg"
                if expectedMB > 0 {
                    dbgLog("MLX-DL-BYTES: %@ task %d (%@) %.1f/%.1f MB (%d%%) | %.2f MB/s",
                           kindStr, downloadTask.taskIdentifier, context.filename,
                           writtenMB, expectedMB, pct, throughputMBs)
                } else {
                    dbgLog("MLX-DL-BYTES: %@ task %d (%@) %.1f MB (expected unknown) | %.2f MB/s",
                           kindStr, downloadTask.taskIdentifier, context.filename,
                           writtenMB, throughputMBs)
                }
                self.lastByteLogTimeByTask[key] = now
                self.lastByteLogBytesByTask[key] = totalBytesWritten
            }
        }
    }

    private var bytesWrittenByTask: [TaskKey: Int64] = [:]
    private var bytesExpectedByTask: [TaskKey: Int64] = [:]
    private var lastByteLogTimeByTask: [TaskKey: Date] = [:]
    private var lastByteLogBytesByTask: [TaskKey: Int64] = [:]

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let kind = sessionKind(of: session)
        let key = TaskKey(session: kind, id: task.taskIdentifier)
        let kindStr = kind == .foreground ? "fg" : "bg"
        guard let context = contextLookup(session: kind, taskID: task.taskIdentifier) else { return }

        let isMigrationCancel = migratingTaskIDs.remove(key) != nil
        if let error = error as NSError? {
            if isMigrationCancel {
                dbgLog("MLX-DL: %@ task %d (%@) cancelled-for-migration (expected)",
                       kindStr, task.taskIdentifier, context.filename)
            } else if error.code == NSURLErrorCancelled {
                dbgLog("MLX-DL: %@ task %d (%@) cancelled",
                       kindStr, task.taskIdentifier, context.filename)
            } else {
                dbgLog("MLX-DL-ERROR: %@ task %d (%@) failed: %@ (domain=%@, code=%d)",
                       kindStr, task.taskIdentifier, context.filename,
                       error.localizedDescription, error.domain, error.code)
            }
        } else {
            dbgLog("MLX-DL: %@ task %d (%@) completed",
                   kindStr, task.taskIdentifier, context.filename)
        }
        removeContext(session: kind, taskID: task.taskIdentifier)
        Task { @MainActor in
            self.bytesWrittenByTask.removeValue(forKey: key)
            self.bytesExpectedByTask.removeValue(forKey: key)
            self.lastByteLogTimeByTask.removeValue(forKey: key)
            self.lastByteLogBytesByTask.removeValue(forKey: key)
        }
    }

    private var migratingTaskIDs: Set<TaskKey> = []

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        dbgLog("MLX-DL: urlSessionDidFinishEvents — invoking app delegate completion handler")
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    // MARK: - Helpers

    func hasActiveTasks(for modelID: String) async -> Bool {
        for session in [foregroundSession, backgroundSession] {
            let kind = sessionKind(of: session)
            let tasks = await session.allTasks
            for task in tasks {
                guard let context = contextLookup(session: kind, taskID: task.taskIdentifier),
                      context.modelID == modelID else { continue }
                if task.state == .running || task.state == .suspended {
                    return true
                }
            }
        }
        return false
    }

    func cancelDownload(modelID: String) async {
        dbgLog("MLX-DL: cancelDownload requested for %@", modelID)
        var cancelled = 0
        for session in [foregroundSession, backgroundSession] {
            let kind = sessionKind(of: session)
            let allTasks = await session.allTasks
            for task in allTasks {
                if let context = contextLookup(session: kind, taskID: task.taskIdentifier),
                   context.modelID == modelID {
                    task.cancel()
                    cancelled += 1
                }
            }
        }
        dbgLog("MLX-DL: Cancelled %d in-flight task(s) for %@", cancelled, modelID)
        await MainActor.run {
            self.filesPendingByModel.removeValue(forKey: modelID)
            self.bytesWrittenByModel.removeValue(forKey: modelID)
            self.bytesExpectedByModel.removeValue(forKey: modelID)
        }
    }

    // MARK: - Lifecycle Migration

    func migrateForegroundTasksToBackground() async {
        let snapshot = await foregroundSession.allTasks
        let downloadTasks = snapshot.compactMap { $0 as? URLSessionDownloadTask }
        guard !downloadTasks.isEmpty else { return }
        dbgLog("MLX-DL: migrateForegroundTasksToBackground: migrating %d task(s)", downloadTasks.count)

        for task in downloadTasks {
            guard task.state == .running || task.state == .suspended else { continue }
            guard let context = contextLookup(session: .foreground, taskID: task.taskIdentifier) else {
                continue
            }
            let oldKey = TaskKey(session: .foreground, id: task.taskIdentifier)
            migratingTaskIDs.insert(oldKey)

            let resumeData: Data? = await withCheckedContinuation { continuation in
                task.cancel(byProducingResumeData: { data in
                    continuation.resume(returning: data)
                })
            }

            await MainActor.run {
                self.bytesWrittenByTask.removeValue(forKey: oldKey)
                self.bytesExpectedByTask.removeValue(forKey: oldKey)
                self.lastByteLogTimeByTask.removeValue(forKey: oldKey)
                self.lastByteLogBytesByTask.removeValue(forKey: oldKey)
            }
            removeContext(session: .foreground, taskID: task.taskIdentifier)

            let newTask: URLSessionDownloadTask
            if let resumeData {
                newTask = backgroundSession.downloadTask(withResumeData: resumeData)
                dbgLog("MLX-DL: migrate fg->bg %@ with %d bytes resume data; new bg task %d",
                       context.filename, resumeData.count, newTask.taskIdentifier)
            } else if let url = task.originalRequest?.url {
                newTask = backgroundSession.downloadTask(with: url)
                dbgLog("MLX-DL: migrate fg->bg %@ WITHOUT resume data; restart from 0; new bg task %d",
                       context.filename, newTask.taskIdentifier)
            } else {
                continue
            }
            saveContext(context, session: .background, taskID: newTask.taskIdentifier)
            newTask.resume()
        }
    }

    func migrateBackgroundTasksToForeground() async {
        let snapshot = await backgroundSession.allTasks
        let downloadTasks = snapshot.compactMap { $0 as? URLSessionDownloadTask }
        guard !downloadTasks.isEmpty else { return }
        dbgLog("MLX-DL: migrateBackgroundTasksToForeground: migrating %d task(s)", downloadTasks.count)

        for task in downloadTasks {
            guard task.state == .running || task.state == .suspended else { continue }
            guard let context = contextLookup(session: .background, taskID: task.taskIdentifier) else {
                continue
            }
            let oldKey = TaskKey(session: .background, id: task.taskIdentifier)
            migratingTaskIDs.insert(oldKey)

            let resumeData: Data? = await withCheckedContinuation { continuation in
                task.cancel(byProducingResumeData: { data in
                    continuation.resume(returning: data)
                })
            }

            await MainActor.run {
                self.bytesWrittenByTask.removeValue(forKey: oldKey)
                self.bytesExpectedByTask.removeValue(forKey: oldKey)
                self.lastByteLogTimeByTask.removeValue(forKey: oldKey)
                self.lastByteLogBytesByTask.removeValue(forKey: oldKey)
            }
            removeContext(session: .background, taskID: task.taskIdentifier)

            let newTask: URLSessionDownloadTask
            if let resumeData {
                newTask = foregroundSession.downloadTask(withResumeData: resumeData)
                dbgLog("MLX-DL: migrate bg->fg %@ with %d bytes resume data; new fg task %d",
                       context.filename, resumeData.count, newTask.taskIdentifier)
            } else if let url = task.originalRequest?.url {
                newTask = foregroundSession.downloadTask(with: url)
                dbgLog("MLX-DL: migrate bg->fg %@ WITHOUT resume data; restart from 0; new fg task %d",
                       context.filename, newTask.taskIdentifier)
            } else {
                continue
            }
            saveContext(context, session: .foreground, taskID: newTask.taskIdentifier)
            newTask.resume()
        }
    }
}

// ==== BLOCK 01: BACKGROUND DOWNLOAD COORDINATOR - END ====


// ==== BLOCK 02: MLX MODEL DOWNLOADER - START ====

// MARK: - MLX Model Downloader (Singleton)
final class MLXModelDownloader: ObservableObject {
    static let shared = MLXModelDownloader()

    struct DownloadState {
        var isDownloading: Bool
        var progress: Double
        var message: String
        var error: String?
        var localPath: URL?
    }

    struct QueuedDownload {
        let modelID: String
        let repoID: String
        let sizeGB: Double?
    }

    @Published var downloadStates: [String: DownloadState] = [:]

    @AppStorage("downloadedModelIDs") private var downloadedModelIDsData: Data = Data() {
        didSet {
            objectWillChange.send()
        }
    }

    private var downloadedModelIDs: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: downloadedModelIDsData)) ?? []
        }
        set {
            downloadedModelIDsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private func modelPath(for modelID: String) -> URL {
        // 2026-06-16 — shared App Group container (see modelDirectory).
        SharedModelStore.mlxModelDir(modelID)
    }

    // MARK: - Download Queue

    private var downloadQueue: [QueuedDownload] = []
    private var currentDownloadTask: Task<Void, Never>?
    private var currentDownloadModelID: String?

    // MARK: - In-Flight Persistence (Background-Resume Support)
    @AppStorage("inFlightDownloadIDs") private var inFlightDownloadIDsData: Data = Data()

    private var inFlightDownloadIDs: Set<String> {
        get { (try? JSONDecoder().decode(Set<String>.self, from: inFlightDownloadIDsData)) ?? [] }
        set { inFlightDownloadIDsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    private func markInFlight(_ modelID: String, repoID: String, sizeGB: Double?) {
        var ids = inFlightDownloadIDs
        ids.insert(modelID)
        inFlightDownloadIDs = ids
        var meta = (UserDefaults.standard.dictionary(forKey: "inFlightDownloadMeta") as? [String: [String: Any]]) ?? [:]
        meta[modelID] = ["repoID": repoID, "sizeGB": sizeGB ?? 0.0]
        UserDefaults.standard.set(meta, forKey: "inFlightDownloadMeta")
    }

    private func clearInFlight(_ modelID: String) {
        var ids = inFlightDownloadIDs
        ids.remove(modelID)
        inFlightDownloadIDs = ids
        var meta = (UserDefaults.standard.dictionary(forKey: "inFlightDownloadMeta") as? [String: [String: Any]]) ?? [:]
        meta.removeValue(forKey: modelID)
        UserDefaults.standard.set(meta, forKey: "inFlightDownloadMeta")
    }

    private func resumeInFlightDownloadsIfAny() async {
        let pending = inFlightDownloadIDs
        guard !pending.isEmpty else {
            dbgLog("MLX-DL: resumeInFlightDownloadsIfAny: no pending markers")
            return
        }
        let meta = (UserDefaults.standard.dictionary(forKey: "inFlightDownloadMeta") as? [String: [String: Any]]) ?? [:]
        dbgLog("MLX-DL: resumeInFlightDownloadsIfAny: found %d in-flight marker(s)", pending.count)

        // Settle delay so BGDL's auto-reconnect and any pending migration
        // tasks finish before we evaluate hasActiveTasks.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        for modelID in pending {
            // 2026-05-27 — clear in-flight markers that no longer
            // correspond to a known catalog model. F6 swapped the
            // broken `Qwen2.5-2B-Instruct-4bit` ID for the working
            // `Qwen3.5-2B-MLX-4bit`, but the prior marker persisted
            // and the downloader auto-resumed a download against a
            // nonexistent repo on every launch. Catalog membership
            // is the source of truth for "is this model a thing we
            // care about" — if it's gone from the catalog, the
            // marker is stale by definition.
            if ModelCatalog.model(id: modelID) == nil {
                clearInFlight(modelID)
                dbgLog("MLX-DL: %@ no longer in catalog; clearing stale marker", modelID)
                continue
            }
            if isModelDownloaded(modelID) {
                clearInFlight(modelID)
                dbgLog("MLX-DL: %@ already downloaded; clearing in-flight marker", modelID)
                continue
            }

            let bgdlAlreadyActive = await BackgroundDownloadCoordinator.shared.hasActiveTasks(for: modelID)
            if bgdlAlreadyActive {
                dbgLog("MLX-DL: %@ — BGDL has in-flight tasks; NOT re-triggering startDownload", modelID)

                // Seed downloadStates so picker UI shows progress for the
                // recovered download.
                let initialFraction = BackgroundDownloadCoordinator.shared.progress(for: modelID)
                let initialClamped = max(0.0, min(0.99, initialFraction))
                await MainActor.run {
                    let seedState = DownloadState(
                        isDownloading: true,
                        progress: initialClamped,
                        message: "Downloading \(Int(initialClamped * 100))%...",
                        error: nil,
                        localPath: nil
                    )
                    self.downloadStates[modelID] = seedState
                }
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if Task.isCancelled { break }
                        let shouldContinue = await MainActor.run { () -> Bool in
                            guard var state = self.downloadStates[modelID], state.isDownloading else {
                                return false
                            }
                            let bgdlFraction = BackgroundDownloadCoordinator.shared.progress(for: modelID)
                            let fraction = max(0.0, min(0.99, bgdlFraction))
                            state.progress = fraction
                            state.message = "Downloading \(Int(fraction * 100))%..."
                            self.downloadStates[modelID] = state
                            return true
                        }
                        if !shouldContinue { break }
                    }
                }
                continue
            }

            let modelMeta = meta[modelID] ?? [:]
            let repoID = modelMeta["repoID"] as? String ?? modelID
            let sizeGB = modelMeta["sizeGB"] as? Double
            let size = (sizeGB ?? 0.0) > 0.0 ? sizeGB : nil
            dbgLog("MLX-DL: Auto-resuming download for %@", modelID)
            Task { await self.startDownload(modelID: modelID, repoID: repoID, sizeGB: size) }
        }
    }

    // MARK: - Cache Management

    @Published var hubCacheSize: String = "Calculating..."
    @Published var isCacheCalculating: Bool = false

    private var hubCacheDirectory: URL {
        // 2026-06-16 — shared App Group container root (cache-size display +
        // cleanup), matching the relocated model store.
        SharedModelStore.huggingFaceRoot
    }

    // MARK: - UI Convenience Accessors

    var isDownloading: Bool {
        downloadStates.values.contains { $0.isDownloading }
    }

    var currentDownloadID: String? {
        downloadStates.first { $0.value.isDownloading }?.key
    }

    // MARK: - Initialization

    private init() {
        dbgLog("MLX-DETECTION: MLXModelDownloader.init() starting...")

        Task.detached {
            await MainActor.run {
                let modelIDs = self.downloadedModelIDs
                dbgLog("MLX-DETECTION: Loaded %d model IDs from storage", modelIDs.count)

                var validIDs = modelIDs
                for modelID in modelIDs {
                    let expectedPath = self.modelPath(for: modelID)
                    if FileManager.default.fileExists(atPath: expectedPath.path) {
                        var isDirectory: ObjCBool = false
                        FileManager.default.fileExists(atPath: expectedPath.path, isDirectory: &isDirectory)
                        if isDirectory.boolValue {
                            self.downloadStates[modelID] = DownloadState(
                                isDownloading: false,
                                progress: 1.0,
                                message: "Model ready.",
                                error: nil,
                                localPath: expectedPath
                            )
                            dbgLog("MLX-DETECTION: Restored model: %@", modelID)
                        } else {
                            validIDs.remove(modelID)
                            dbgLog("MLX-DETECTION: Path exists but not directory: %@", modelID)
                        }
                    } else {
                        validIDs.remove(modelID)
                        dbgLog("MLX-DETECTION: Removed invalid model ID: %@", modelID)
                    }
                }

                if validIDs.count != modelIDs.count {
                    self.downloadedModelIDs = validIDs
                }

                // 2026-06-16 — if models are present but no usable MLX model is
                // selected (e.g. downloaded under a build before auto-select
                // existed, or the selected model was deleted), activate the first
                // available one so the picker + answer engine agree at launch.
                if let selected = ModelCatalog.ensureUsableSelection() {
                    dbgLog("MLX-DETECTION: auto-selected %@ as the active answer model.", selected)
                }

                dbgLog("MLX-DETECTION: init complete — %d models ready", self.downloadStates.count)
            }

            await self.resumeInFlightDownloadsIfAny()
            await self.updateCacheSize()
        }
    }

    // MARK: - Multi-Model Download Management

    private nonisolated func checkAvailableSpace(forModelSizeGB sizeGB: Double, modelDisplayName: String) -> String? {
        // Free space is a VOLUME property; the App Group container and Caches
        // sit on the same physical volume, so measure Caches — which always
        // exists. (The container's `Models/` subdir may not exist until the
        // first download, and a volume-capacity query on a non-existent path
        // fails → "storage couldn't be determined." 2026-06-16 bug fix.)
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        guard let values = try? cachesURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let availableBytes = values.volumeAvailableCapacityForImportantUsage else {
            return "\(modelDisplayName) couldn't be downloaded: this device's available storage couldn't be determined. Free up some space and try again."
        }

        let requiredBytes = Int64(sizeGB * 1.3 * 1_073_741_824)  // 30% margin
        if availableBytes >= requiredBytes {
            return nil
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        let requiredStr = formatter.string(fromByteCount: requiredBytes)
        let availableStr = formatter.string(fromByteCount: availableBytes)
        return "Downloading \(modelDisplayName) needs about \(requiredStr) free, but only \(availableStr) is available on this device. Free up some space and try again."
    }

    func startDownload(modelID: String, repoID: String, sizeGB: Double? = nil) async {
        if isModelDownloaded(modelID) {
            await MainActor.run {
                dbgLog("MLX-DL: Model already downloaded: %@", modelID)
                if var state = self.downloadStates[modelID] {
                    state.message = "Model already downloaded."
                    self.downloadStates[modelID] = state
                }
            }
            return
        }

        let alreadyDownloading = await MainActor.run { () -> Bool in
            if let state = downloadStates[modelID], state.isDownloading {
                dbgLog("MLX-DL: Download already in progress for %@", modelID)
                return true
            }
            return false
        }
        if alreadyDownloading { return }

        if currentDownloadTask != nil {
            await MainActor.run {
                let queuedDownload = QueuedDownload(modelID: modelID, repoID: repoID, sizeGB: sizeGB)
                downloadQueue.append(queuedDownload)

                var state = downloadStates[modelID] ?? DownloadState(
                    isDownloading: false,
                    progress: 0.0,
                    message: "Queued...",
                    error: nil,
                    localPath: nil
                )
                state.message = "Queued (position \(downloadQueue.count))..."
                downloadStates[modelID] = state
                dbgLog("MLX-DL: Queued download for %@ (position %d)", modelID, downloadQueue.count)
            }
            return
        }

        // PRE-FLIGHT DISK SPACE CHECK
        let modelDisplayName = await MainActor.run {
            ModelCatalog.model(id: modelID)?.displayName ?? modelID
        }
        let spaceError: String? = {
            guard let sizeGB = sizeGB, sizeGB > 0 else {
                return "\(modelDisplayName) couldn't be downloaded: this model's size couldn't be determined from its repository. Make sure you have plenty of free space on the device before trying again."
            }
            return checkAvailableSpace(forModelSizeGB: sizeGB, modelDisplayName: modelDisplayName)
        }()
        if let spaceError = spaceError {
            await MainActor.run {
                dbgLog("MLX-DL: Refusing %@ — insufficient space. %@", modelID, spaceError)
                var state = downloadStates[modelID] ?? DownloadState(
                    isDownloading: false,
                    progress: 0.0,
                    message: spaceError,
                    error: spaceError,
                    localPath: nil
                )
                state.isDownloading = false
                state.progress = 0.0
                state.message = spaceError
                state.error = spaceError
                downloadStates[modelID] = state
            }
            return
        }

        await MainActor.run {
            currentDownloadModelID = modelID

            var state = downloadStates[modelID] ?? DownloadState(
                isDownloading: true,
                progress: 0.0,
                message: "Starting download...",
                error: nil,
                localPath: nil
            )
            state.isDownloading = true
            state.progress = 0.0
            state.message = "Starting download..."
            state.error = nil
            downloadStates[modelID] = state
        }

        let expectedBytes = sizeGB.map { Int64($0 * 1_073_741_824) } ?? 0
        dbgLog("MLX-PROGRESS: sizeGB=%.2f expectedBytes=%lld for %@", sizeGB ?? 0, expectedBytes, modelID)

        // Polling task — sources progress from BGDL's per-task byte tracking.
        let progressPollingTask: Task<Void, Never>? = expectedBytes > 0 ? Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    let bgdlFraction = BackgroundDownloadCoordinator.shared.progress(for: modelID)
                    let fraction = min(0.99, bgdlFraction)
                    if var state = self.downloadStates[modelID], state.isDownloading {
                        state.progress = fraction
                        state.message = "Downloading \(Int(fraction * 100))%..."
                        self.downloadStates[modelID] = state
                    }
                }
            }
        } : nil

        markInFlight(modelID, repoID: repoID, sizeGB: sizeGB)

        currentDownloadTask = Task {
            let bgTaskID = await MainActor.run { () -> UIBackgroundTaskIdentifier in
                UIApplication.shared.beginBackgroundTask(withName: "ModelDownload-\(modelID)") {
                    dbgLog("MLX-DL: Background task expiring for %@ — iOS will suspend; resume on next launch", modelID)
                }
            }

            defer {
                Task { @MainActor in
                    if bgTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskID)
                    }
                }
            }

            do {
                dbgLog("MLX-DL: Starting download for %@ from %@ via BGDL", modelID, repoID)
                try await BackgroundDownloadCoordinator.shared.startDownload(modelID: modelID, repoID: repoID)

                let alreadyComplete = await MainActor.run { self.isModelDownloaded(modelID) }
                if alreadyComplete {
                    dbgLog("MLX-DL: %@ already complete on coordinator start; done", modelID)
                    progressPollingTask?.cancel()
                    return
                }

                try await self.waitForModelCompletion(modelID: modelID)
                progressPollingTask?.cancel()
                dbgLog("MLX-DL: Download notification received for %@; coordinator handled bookkeeping", modelID)
            } catch is CancellationError {
                await BackgroundDownloadCoordinator.shared.cancelDownload(modelID: modelID)
                progressPollingTask?.cancel()
                await MainActor.run {
                    if var state = self.downloadStates[modelID] {
                        state.isDownloading = false
                        state.message = "Download cancelled at \(Int(state.progress * 100))%"
                        state.error = "Cancelled"
                        self.downloadStates[modelID] = state
                    }
                    self.currentDownloadTask = nil
                    self.currentDownloadModelID = nil
                    self.clearInFlight(modelID)
                    dbgLog("MLX-DL: Download cancelled for %@; in-flight marker cleared", modelID)
                    self.processNextInQueue()
                }
            } catch {
                progressPollingTask?.cancel()
                let errMsg = error.localizedDescription
                await MainActor.run {
                    if var state = self.downloadStates[modelID] {
                        state.isDownloading = false
                        state.error = errMsg
                        state.message = "Download failed — will retry next launch."
                        state.progress = 0.0
                        self.downloadStates[modelID] = state
                    }
                    self.currentDownloadTask = nil
                    self.currentDownloadModelID = nil
                    dbgLog("MLX-DL: Download failed for %@: %@ — in-flight marker preserved for next-launch resume", modelID, errMsg)
                    self.processNextInQueue()
                }
            }
        }
    }

    private func processNextInQueue() {
        guard !downloadQueue.isEmpty else { return }
        let nextDownload = downloadQueue.removeFirst()
        dbgLog("MLX-DL: Processing queued download: %@", nextDownload.modelID)
        Task {
            await startDownload(modelID: nextDownload.modelID, repoID: nextDownload.repoID, sizeGB: nextDownload.sizeGB)
        }
    }

    func cancelDownload(modelID: String) {
        if currentDownloadModelID == modelID {
            currentDownloadTask?.cancel()
            currentDownloadTask = nil
            currentDownloadModelID = nil
        } else {
            downloadQueue.removeAll { $0.modelID == modelID }
        }

        if var state = downloadStates[modelID] {
            state.isDownloading = false
            state.message = "Download cancelled at \(Int(state.progress * 100))%"
            state.error = "Cancelled"
            downloadStates[modelID] = state
        }
        dbgLog("MLX-DL: Cancelled active download for %@", modelID)
    }

    func deleteModel(modelID: String) async {
        let expectedPath = modelPath(for: modelID)
        // 2026-06-16 — release this app's manifest claim first. The files are
        // only physically removed when NO sibling app (Hal) still claims them
        // (sole participant today → always true). When a sibling still claims
        // it, the model is kept on disk and merely dropped from THIS app's list
        // via the `else` branch below.
        let safeToDelete = SharedModelStore.releaseClaim(modelID: modelID)

        if safeToDelete && FileManager.default.fileExists(atPath: expectedPath.path) {
            do {
                try FileManager.default.removeItem(at: expectedPath)
                dbgLog("MLX-DL: Model deleted from %@", expectedPath.path)

                await MainActor.run {
                    var modelIDs = self.downloadedModelIDs
                    modelIDs.remove(modelID)
                    self.downloadedModelIDs = modelIDs

                    var state = self.downloadStates[modelID] ?? DownloadState(
                        isDownloading: false,
                        progress: 0.0,
                        message: "Model deleted.",
                        error: nil,
                        localPath: nil
                    )
                    state.localPath = nil
                    state.progress = 0.0
                    state.message = "Model deleted."
                    self.downloadStates[modelID] = state

                    Task { await self.updateCacheSize() }
                }
            } catch {
                let errMsg = error.localizedDescription
                await MainActor.run {
                    var state = self.downloadStates[modelID] ?? DownloadState(
                        isDownloading: false,
                        progress: 0.0,
                        message: "Delete failed.",
                        error: errMsg,
                        localPath: nil
                    )
                    state.error = "Delete failed: \(errMsg)"
                    state.message = "Delete failed."
                    self.downloadStates[modelID] = state
                }
            }
        } else {
            await MainActor.run {
                var modelIDs = self.downloadedModelIDs
                modelIDs.remove(modelID)
                self.downloadedModelIDs = modelIDs

                var state = self.downloadStates[modelID] ?? DownloadState(
                    isDownloading: false,
                    progress: 0.0,
                    message: "Model was already deleted.",
                    error: nil,
                    localPath: nil
                )
                state.message = "Model was already deleted."
                self.downloadStates[modelID] = state
            }
        }
    }

    func isModelDownloaded(_ modelID: String) -> Bool {
        return downloadedModelIDs.contains(modelID) &&
               FileManager.default.fileExists(atPath: modelPath(for: modelID).path)
    }

    /// Local on-disk path for a downloaded model, or nil.
    func localPath(for modelID: String) -> URL? {
        guard isModelDownloaded(modelID) else { return nil }
        return modelPath(for: modelID)
    }

    private func waitForModelCompletion(modelID: String) async throws {
        let notifications = NotificationCenter.default.notifications(named: .mlxModelDidDownload)
        for await notification in notifications {
            try Task.checkCancellation()
            if let id = notification.userInfo?["modelID"] as? String, id == modelID {
                return
            }
        }
    }

    func markModelAsDownloadedFromBackground(modelID: String) {
        let finalURL = modelPath(for: modelID)
        var modelIDs = self.downloadedModelIDs
        modelIDs.insert(modelID)
        self.downloadedModelIDs = modelIDs

        var state = self.downloadStates[modelID] ?? DownloadState(
            isDownloading: false,
            progress: 1.0,
            message: "Model ready.",
            error: nil,
            localPath: finalURL
        )
        state.isDownloading = false
        state.progress = 1.0
        state.message = "Model ready."
        state.localPath = finalURL
        state.error = nil
        self.downloadStates[modelID] = state

        self.clearInFlight(modelID)

        if self.currentDownloadModelID == modelID {
            self.currentDownloadModelID = nil
            self.currentDownloadTask = nil
        }

        Task { await self.updateCacheSize() }

        dbgLog("MLX-DL: Background download finalized for %@", modelID)

        self.processNextInQueue()
    }

    func getModelPath(_ modelID: String) -> URL? {
        guard downloadedModelIDs.contains(modelID) else { return nil }
        let path = modelPath(for: modelID)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Cache Management

    @MainActor
    func updateCacheSize() async {
        isCacheCalculating = true
        let size = await calculateDirectorySize(hubCacheDirectory)
        hubCacheSize = size > 0 ? formatBytes(Int64(size)) : "No cache"
        isCacheCalculating = false
    }

    func clearHubCache() {
        if FileManager.default.fileExists(atPath: hubCacheDirectory.path) {
            do {
                try FileManager.default.removeItem(at: hubCacheDirectory)
                downloadedModelIDs = []
                downloadStates = [:]
                hubCacheSize = "No cache"
                dbgLog("MLX-CACHE: Cleared Hub cache and all model states")
            } catch {
                dbgLog("MLX-CACHE: Failed to clear cache: %@", error.localizedDescription)
            }
        } else {
            hubCacheSize = "No cache"
        }
    }

    // MARK: - Utility Methods

    private func calculateDirectorySize(_ directory: URL) async -> UInt64 {
        return await withCheckedContinuation { continuation in
            Task.detached {
                var totalSize: UInt64 = 0

                guard FileManager.default.fileExists(atPath: directory.path) else {
                    continuation.resume(returning: 0)
                    return
                }

                let resourceKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
                guard let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: 0)
                    return
                }

                while let fileURL = enumerator.nextObject() as? URL {
                    do {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        if let isDirectory = resourceValues.isDirectory, !isDirectory {
                            if let fileSize = resourceValues.totalFileAllocatedSize {
                                totalSize += UInt64(fileSize)
                            }
                        }
                    } catch {
                        continue
                    }
                }

                continuation.resume(returning: totalSize)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// ==== BLOCK 02: MLX MODEL DOWNLOADER - END ====


// MARK: - Notification
extension Notification.Name {
    static let mlxModelDidDownload = Notification.Name("mlxModelDidDownload")
}
