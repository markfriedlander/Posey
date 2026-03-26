//
//  PoseyApp.swift
//  Posey
//
//  Created by Mark Friedlander on 3/22/26.
//

import SwiftUI

// ========== BLOCK 1: APP ENTRY POINT - START ==========
@main
struct PoseyApp: App {
    private let launchConfiguration = AppLaunchConfiguration.current
    @State private var databaseManager: DatabaseManager?
    @State private var databaseErrorMessage: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let databaseManager {
                    LibraryView(
                        databaseManager: databaseManager,
                        playbackMode: launchConfiguration.playbackMode,
                        isTestMode: launchConfiguration.isTestMode,
                        shouldAutoOpenFirstDocument: launchConfiguration.shouldAutoOpenFirstDocument,
                        shouldAutoPlayOnReaderAppear: launchConfiguration.shouldAutoPlayOnReaderAppear,
                        shouldAutoCreateNoteOnReaderAppear: launchConfiguration.shouldAutoCreateNoteOnReaderAppear,
                        shouldAutoCreateBookmarkOnReaderAppear: launchConfiguration.shouldAutoCreateBookmarkOnReaderAppear,
                        automationNoteBody: launchConfiguration.automationNoteBody
                    )
                } else if let databaseErrorMessage {
                    ContentUnavailableView(
                        "Database Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(databaseErrorMessage)
                    )
                } else {
                    ProgressView("Starting Posey…")
                }
            }
            .task {
                guard databaseManager == nil, databaseErrorMessage == nil else {
                    return
                }
                do {
                    let manager: DatabaseManager
                    if let databaseURL = launchConfiguration.databaseURL {
                        manager = try DatabaseManager(databaseURL: databaseURL, resetIfExists: launchConfiguration.shouldResetDatabase)
                    } else {
                        manager = try DatabaseManager(resetIfExists: launchConfiguration.shouldResetDatabase)
                    }
                    if let preload = launchConfiguration.preload {
                        try executePreload(preload, databaseManager: manager)
                    }
                    databaseManager = manager
                } catch {
                    databaseErrorMessage = error.localizedDescription
                }
            }
        }
    }
}
// ========== BLOCK 1: APP ENTRY POINT - END ==========

// ========== BLOCK 2: PRELOAD EXECUTION - START ==========
private extension PoseyApp {
    func executePreload(_ preload: PreloadRequest, databaseManager: DatabaseManager) throws {
        let defaultTitle = "Preloaded"

        switch preload.format {
        case .txt:
            switch preload.source {
            case .url(let url):
                _ = try TXTLibraryImporter(databaseManager: databaseManager).importDocument(from: url)
            case .inlineBase64(let b64):
                guard let data = Data(base64Encoded: b64),
                      let rawText = String(data: data, encoding: .utf8) else { return }
                let title = preload.title ?? defaultTitle
                _ = try TXTLibraryImporter(databaseManager: databaseManager).importDocument(
                    title: title, fileName: preload.fileName ?? "\(title).txt", rawText: rawText)
            }

        case .markdown:
            switch preload.source {
            case .url(let url):
                _ = try MarkdownLibraryImporter(databaseManager: databaseManager).importDocument(from: url)
            case .inlineBase64(let b64):
                guard let data = Data(base64Encoded: b64),
                      let rawText = String(data: data, encoding: .utf8) else { return }
                let title = preload.title ?? defaultTitle
                _ = try MarkdownLibraryImporter(databaseManager: databaseManager).importDocument(
                    title: title, fileName: preload.fileName ?? "\(title).md", rawText: rawText)
            }

        case .rtf:
            switch preload.source {
            case .url(let url):
                _ = try RTFLibraryImporter(databaseManager: databaseManager).importDocument(from: url)
            case .inlineBase64(let b64):
                guard let data = Data(base64Encoded: b64) else { return }
                let title = preload.title ?? defaultTitle
                _ = try RTFLibraryImporter(databaseManager: databaseManager).importDocument(
                    title: title, fileName: preload.fileName ?? "\(title).rtf", rawData: data)
            }

        case .docx:
            switch preload.source {
            case .url(let url):
                _ = try DOCXLibraryImporter(databaseManager: databaseManager).importDocument(from: url)
            case .inlineBase64(let b64):
                guard let data = Data(base64Encoded: b64) else { return }
                let title = preload.title ?? defaultTitle
                _ = try DOCXLibraryImporter(databaseManager: databaseManager).importDocument(
                    title: title, fileName: preload.fileName ?? "\(title).docx", rawData: data)
            }

        case .html:
            switch preload.source {
            case .url(let url):
                _ = try HTMLLibraryImporter(databaseManager: databaseManager).importDocument(from: url)
            case .inlineBase64(let b64):
                guard let data = Data(base64Encoded: b64) else { return }
                let title = preload.title ?? defaultTitle
                _ = try HTMLLibraryImporter(databaseManager: databaseManager).importDocument(
                    title: title, fileName: preload.fileName ?? "\(title).html", rawData: data)
            }

        case .epub:
            switch preload.source {
            case .url(let url):
                _ = try EPUBLibraryImporter(databaseManager: databaseManager).importDocument(from: url)
            case .inlineBase64(let b64):
                guard let data = Data(base64Encoded: b64) else { return }
                let title = preload.title ?? defaultTitle
                _ = try EPUBLibraryImporter(databaseManager: databaseManager).importDocument(
                    title: title, fileName: preload.fileName ?? "\(title).epub", rawData: data)
            }

        case .pdf:
            switch preload.source {
            case .url(let url):
                _ = try PDFLibraryImporter(databaseManager: databaseManager).importDocument(from: url)
            case .inlineBase64(let b64):
                guard let data = Data(base64Encoded: b64) else { return }
                let title = preload.title ?? defaultTitle
                _ = try PDFLibraryImporter(databaseManager: databaseManager).importDocument(
                    title: title, fileName: preload.fileName ?? "\(title).pdf", rawData: data)
            }
        }
    }
}
// ========== BLOCK 2: PRELOAD EXECUTION - END ==========
