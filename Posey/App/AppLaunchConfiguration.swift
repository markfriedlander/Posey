import Foundation

struct AppLaunchConfiguration {
    enum PlaybackMode: String {
        case system
        case simulated
    }

    let isTestMode: Bool
    let shouldResetDatabase: Bool
    let databaseURL: URL?
    let preloadTXTURL: URL?
    let preloadTXTTitle: String?
    let preloadTXTFileName: String?
    let preloadTXTInlineBase64: String?
    let preloadMarkdownURL: URL?
    let preloadMarkdownTitle: String?
    let preloadMarkdownFileName: String?
    let preloadMarkdownInlineBase64: String?
    let preloadRTFURL: URL?
    let preloadRTFTitle: String?
    let preloadRTFFileName: String?
    let preloadRTFInlineBase64: String?
    let preloadDOCXURL: URL?
    let preloadDOCXTitle: String?
    let preloadDOCXFileName: String?
    let preloadDOCXInlineBase64: String?
    let preloadHTMLURL: URL?
    let preloadHTMLTitle: String?
    let preloadHTMLFileName: String?
    let preloadHTMLInlineBase64: String?
    let preloadEPUBURL: URL?
    let preloadEPUBTitle: String?
    let preloadEPUBFileName: String?
    let preloadEPUBInlineBase64: String?
    let preloadPDFURL: URL?
    let preloadPDFTitle: String?
    let preloadPDFFileName: String?
    let preloadPDFInlineBase64: String?
    let playbackMode: PlaybackMode
    let shouldAutoOpenFirstDocument: Bool
    let shouldAutoPlayOnReaderAppear: Bool
    let shouldAutoCreateNoteOnReaderAppear: Bool
    let shouldAutoCreateBookmarkOnReaderAppear: Bool
    let automationNoteBody: String

    static var current: AppLaunchConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments

        return AppLaunchConfiguration(
            isTestMode: environment["POSEY_TEST_MODE"] == "1" || arguments.contains("--posey-ui-test-mode"),
            shouldResetDatabase: environment["POSEY_RESET_DATABASE"] == "1",
            databaseURL: environment["POSEY_DATABASE_PATH"].flatMap { URL(fileURLWithPath: $0) },
            preloadTXTURL: environment["POSEY_PRELOAD_TXT_PATH"].flatMap { URL(fileURLWithPath: $0) },
            preloadTXTTitle: environment["POSEY_PRELOAD_TXT_TITLE"],
            preloadTXTFileName: environment["POSEY_PRELOAD_TXT_FILENAME"],
            preloadTXTInlineBase64: environment["POSEY_PRELOAD_TXT_INLINE_BASE64"],
            preloadMarkdownURL: environment["POSEY_PRELOAD_MARKDOWN_PATH"].flatMap { URL(fileURLWithPath: $0) },
            preloadMarkdownTitle: environment["POSEY_PRELOAD_MARKDOWN_TITLE"],
            preloadMarkdownFileName: environment["POSEY_PRELOAD_MARKDOWN_FILENAME"],
            preloadMarkdownInlineBase64: environment["POSEY_PRELOAD_MARKDOWN_INLINE_BASE64"],
            preloadRTFURL: environment["POSEY_PRELOAD_RTF_PATH"].flatMap { URL(fileURLWithPath: $0) },
            preloadRTFTitle: environment["POSEY_PRELOAD_RTF_TITLE"],
            preloadRTFFileName: environment["POSEY_PRELOAD_RTF_FILENAME"],
            preloadRTFInlineBase64: environment["POSEY_PRELOAD_RTF_INLINE_BASE64"],
            preloadDOCXURL: environment["POSEY_PRELOAD_DOCX_PATH"].flatMap { URL(fileURLWithPath: $0) },
            preloadDOCXTitle: environment["POSEY_PRELOAD_DOCX_TITLE"],
            preloadDOCXFileName: environment["POSEY_PRELOAD_DOCX_FILENAME"],
            preloadDOCXInlineBase64: environment["POSEY_PRELOAD_DOCX_INLINE_BASE64"],
            preloadHTMLURL: environment["POSEY_PRELOAD_HTML_PATH"].flatMap { URL(fileURLWithPath: $0) },
            preloadHTMLTitle: environment["POSEY_PRELOAD_HTML_TITLE"],
            preloadHTMLFileName: environment["POSEY_PRELOAD_HTML_FILENAME"],
            preloadHTMLInlineBase64: environment["POSEY_PRELOAD_HTML_INLINE_BASE64"],
            preloadEPUBURL: environment["POSEY_PRELOAD_EPUB_PATH"].flatMap { URL(fileURLWithPath: $0) },
            preloadEPUBTitle: environment["POSEY_PRELOAD_EPUB_TITLE"],
            preloadEPUBFileName: environment["POSEY_PRELOAD_EPUB_FILENAME"],
            preloadEPUBInlineBase64: environment["POSEY_PRELOAD_EPUB_INLINE_BASE64"],
            preloadPDFURL: environment["POSEY_PRELOAD_PDF_PATH"].flatMap { URL(fileURLWithPath: $0) },
            preloadPDFTitle: environment["POSEY_PRELOAD_PDF_TITLE"],
            preloadPDFFileName: environment["POSEY_PRELOAD_PDF_FILENAME"],
            preloadPDFInlineBase64: environment["POSEY_PRELOAD_PDF_INLINE_BASE64"],
            playbackMode: PlaybackMode(rawValue: environment["POSEY_PLAYBACK_MODE"] ?? "") ?? .system,
            shouldAutoOpenFirstDocument: environment["POSEY_AUTOMATION_OPEN_FIRST_DOCUMENT"] == "1",
            shouldAutoPlayOnReaderAppear: environment["POSEY_AUTOMATION_PLAY_ON_APPEAR"] == "1",
            shouldAutoCreateNoteOnReaderAppear: environment["POSEY_AUTOMATION_CREATE_NOTE_ON_APPEAR"] == "1",
            shouldAutoCreateBookmarkOnReaderAppear: environment["POSEY_AUTOMATION_CREATE_BOOKMARK_ON_APPEAR"] == "1",
            automationNoteBody: environment["POSEY_AUTOMATION_NOTE_BODY"] ?? "Automated smoke note"
        )
    }
}
