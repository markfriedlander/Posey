import Combine
import Foundation

// ========== BLOCK 01: JOB MODEL - START ==========
/// Single audio export job tracked by the API. UI surfaces (Audio
/// Export sheet) and the headless API path both write into the
/// shared registry so a script can kick off an export, poll status,
/// and fetch the resulting M4A file without ever opening the sheet.
struct RemoteAudioExportJob: Sendable {
    let id: String
    let documentID: UUID
    let documentTitle: String
    let startedAt: Date
    var status: Status
    var progress: Double                // 0...1
    var currentSegmentIndex: Int
    var totalSegments: Int
    var resultURL: URL?
    var errorMessage: String?

    enum Status: String, Sendable {
        case pending
        case rendering
        case finished
        case failed
        case cancelled
    }

    func snapshot() -> [String: Any] {
        var dict: [String: Any] = [
            "jobID": id,
            "documentID": documentID.uuidString,
            "documentTitle": documentTitle,
            "startedAt": startedAt.timeIntervalSince1970,
            "status": status.rawValue,
            "progress": progress,
            "currentSegmentIndex": currentSegmentIndex,
            "totalSegments": totalSegments
        ]
        if let url = resultURL {
            dict["resultPath"] = url.path
            dict["bytes"] = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        }
        if let err = errorMessage { dict["errorMessage"] = err }
        return dict
    }
}
// ========== BLOCK 01: JOB MODEL - END ==========


// ========== BLOCK 02: REGISTRY - START ==========
/// Tracks all audio export jobs the API has launched. MainActor-
/// isolated to keep mutation single-threaded — exports themselves
/// run on the AVSpeechSynthesizer's queue but state updates hop
/// back to main inside `AudioExporter`.
@MainActor
final class RemoteAudioExportRegistry {
    static let shared = RemoteAudioExportRegistry()
    private init() {}

    private var jobs: [String: RemoteAudioExportJob] = [:]

    func create(documentID: UUID, documentTitle: String) -> RemoteAudioExportJob {
        let job = RemoteAudioExportJob(
            id: UUID().uuidString,
            documentID: documentID,
            documentTitle: documentTitle,
            startedAt: Date(),
            status: .pending,
            progress: 0,
            currentSegmentIndex: 0,
            totalSegments: 0,
            resultURL: nil,
            errorMessage: nil
        )
        jobs[job.id] = job
        return job
    }

    func update(_ jobID: String, mutate: (inout RemoteAudioExportJob) -> Void) {
        guard var job = jobs[jobID] else { return }
        mutate(&job)
        jobs[jobID] = job
    }

    func get(_ jobID: String) -> RemoteAudioExportJob? { jobs[jobID] }

    func all() -> [RemoteAudioExportJob] {
        jobs.values.sorted { $0.startedAt > $1.startedAt }
    }
}
// ========== BLOCK 02: REGISTRY - END ==========


// ========== BLOCK 03: HEADLESS EXPORT DRIVER - START ==========
/// Run an audio export job from outside any UI surface — segments
/// the document text, applies the user's current voice mode from
/// `PlaybackPreferences`, and pumps `AudioExporter` while updating
/// the matching `RemoteAudioExportRegistry` job.
///
/// Bridges the live `@Published state: AudioExportState` from
/// `AudioExporter` into the registry so the API caller can poll
/// `AUDIO_EXPORT_STATUS:<jobID>` for granular progress.
@MainActor
func runHeadlessAudioExport(jobID: String, plainText: String, title: String) async {
    // 2026-05-13 — Cache fast-path. If a cached export already exists
    // for this document, return its URL immediately without
    // re-rendering. The cache is invalidated automatically when the
    // source document is deleted (see AudioExportCache observer).
    let documentID = RemoteAudioExportRegistry.shared.get(jobID)?.documentID
    if let docID = documentID,
       let cachedURL = AudioExportCache.shared.cachedURL(for: docID) {
        RemoteAudioExportRegistry.shared.update(jobID) { job in
            job.status = .finished
            job.progress = 1.0
            job.resultURL = cachedURL
        }
        return
    }

    let segmenter = SentenceSegmenter()
    let segments = segmenter.segments(for: plainText)
    let voiceMode = PlaybackPreferences.shared.voiceMode

    RemoteAudioExportRegistry.shared.update(jobID) { job in
        job.status = .rendering
        job.totalSegments = segments.count
    }

    let exporter = AudioExporter()
    // Bridge the exporter's published state into the job registry
    // so AUDIO_EXPORT_STATUS reflects rendering progress without the
    // UI sheet being open.
    let cancellable = exporter.$state.sink { state in
        Task { @MainActor in
            switch state {
            case .idle:
                break
            case .rendering(let progress, let idx, let total):
                RemoteAudioExportRegistry.shared.update(jobID) { job in
                    job.status = .rendering
                    job.progress = progress
                    job.currentSegmentIndex = idx
                    job.totalSegments = total
                }
            case .finished(let url):
                RemoteAudioExportRegistry.shared.update(jobID) { job in
                    job.status = .finished
                    job.progress = 1.0
                    job.resultURL = url
                }
            case .failed(let reason):
                RemoteAudioExportRegistry.shared.update(jobID) { job in
                    job.status = .failed
                    job.errorMessage = reason
                }
            }
        }
    }
    defer { _ = cancellable }  // hold the subscription until export completes

    do {
        let url = try await exporter.render(
            segments: segments,
            voiceMode: voiceMode,
            outputDirectory: FileManager.default.temporaryDirectory,
            documentTitle: title
        )
        // 2026-05-13 — Move the freshly rendered file into the
        // persistent cache so future exports of the same document hit
        // the cache fast-path. Move failures fall back to surfacing
        // the temp URL directly; the user still gets a usable file.
        var finalURL = url
        if let docID = RemoteAudioExportRegistry.shared.get(jobID)?.documentID,
           let cachedURL = try? AudioExportCache.shared.store(url, for: docID) {
            finalURL = cachedURL
        }
        RemoteAudioExportRegistry.shared.update(jobID) { job in
            job.status = .finished
            job.progress = 1.0
            job.resultURL = finalURL
        }
    } catch {
        RemoteAudioExportRegistry.shared.update(jobID) { job in
            if let exportError = error as? AudioExportError, case .cancelled = exportError {
                job.status = .cancelled
            } else {
                job.status = .failed
            }
            job.errorMessage = error.localizedDescription
        }
    }
}
// ========== BLOCK 03: HEADLESS EXPORT DRIVER - END ==========
