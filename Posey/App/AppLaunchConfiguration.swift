import Foundation

// ========== BLOCK 1: PRELOAD REQUEST - START ==========
struct PreloadRequest {
    enum Format: String {
        case txt
        case markdown
        case rtf
        case docx
        case html
        case epub
        case pdf
    }

    enum Source {
        case url(URL)
        case inlineBase64(String)
    }

    let format: Format
    let source: Source
    let title: String?
    let fileName: String?
}
// ========== BLOCK 1: PRELOAD REQUEST - END ==========

// ========== BLOCK 2: LAUNCH CONFIGURATION - START ==========
struct AppLaunchConfiguration {
    enum PlaybackMode: String {
        case system
        case simulated
    }

    let isTestMode: Bool
    let shouldResetDatabase: Bool
    let databaseURL: URL?
    let preload: PreloadRequest?
    let playbackMode: PlaybackMode
    let shouldAutoOpenFirstDocument: Bool
    let shouldAutoPlayOnReaderAppear: Bool
    let shouldAutoCreateNoteOnReaderAppear: Bool
    let shouldAutoCreateBookmarkOnReaderAppear: Bool
    let automationNoteBody: String
    /// Test-only: force a specific interface orientation at launch.
    /// Accepted values (case-insensitive): "portrait", "landscape",
    /// "landscapeLeft", "landscapeRight". Silently ignored otherwise.
    /// Used by the simulator MCP (which has no rotation API) and by
    /// future automated UI tests. Has no effect for end users.
    let forceOrientation: String?

    static var current: AppLaunchConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments

        return AppLaunchConfiguration(
            isTestMode: environment["POSEY_TEST_MODE"] == "1" || arguments.contains("--posey-ui-test-mode"),
            shouldResetDatabase: environment["POSEY_RESET_DATABASE"] == "1",
            databaseURL: environment["POSEY_DATABASE_PATH"].flatMap { URL(fileURLWithPath: $0) },
            preload: resolvePreload(from: environment),
            playbackMode: PlaybackMode(rawValue: environment["POSEY_PLAYBACK_MODE"] ?? "") ?? .system,
            shouldAutoOpenFirstDocument: environment["POSEY_AUTOMATION_OPEN_FIRST_DOCUMENT"] == "1",
            shouldAutoPlayOnReaderAppear: environment["POSEY_AUTOMATION_PLAY_ON_APPEAR"] == "1",
            shouldAutoCreateNoteOnReaderAppear: environment["POSEY_AUTOMATION_CREATE_NOTE_ON_APPEAR"] == "1",
            shouldAutoCreateBookmarkOnReaderAppear: environment["POSEY_AUTOMATION_CREATE_BOOKMARK_ON_APPEAR"] == "1",
            automationNoteBody: environment["POSEY_AUTOMATION_NOTE_BODY"] ?? "Automated smoke note",
            forceOrientation: environment["POSEY_FORCE_ORIENTATION"]
        )
    }

    private static func resolvePreload(from environment: [String: String]) -> PreloadRequest? {
        guard let formatRaw = environment["POSEY_PRELOAD_FORMAT"],
              let format = PreloadRequest.Format(rawValue: formatRaw.lowercased()) else {
            return nil
        }

        let source: PreloadRequest.Source
        if let path = environment["POSEY_PRELOAD_PATH"] {
            source = .url(URL(fileURLWithPath: path))
        } else if let b64 = environment["POSEY_PRELOAD_INLINE_BASE64"] {
            source = .inlineBase64(b64)
        } else {
            return nil
        }

        return PreloadRequest(
            format: format,
            source: source,
            title: environment["POSEY_PRELOAD_TITLE"],
            fileName: environment["POSEY_PRELOAD_FILENAME"]
        )
    }
}
// ========== BLOCK 2: LAUNCH CONFIGURATION - END ==========
