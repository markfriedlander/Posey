//
//  PoseyApp.swift
//  Posey
//
//  Created by Mark Friedlander on 3/22/26.
//

import SwiftUI

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

                    if let preloadTXTURL = launchConfiguration.preloadTXTURL {
                        _ = try TXTLibraryImporter(databaseManager: manager).importDocument(from: preloadTXTURL)
                    } else if
                        let inlineBase64 = launchConfiguration.preloadTXTInlineBase64,
                        let data = Data(base64Encoded: inlineBase64),
                        let rawText = String(data: data, encoding: .utf8)
                    {
                        let title = launchConfiguration.preloadTXTTitle ?? "Preloaded"
                        let fileName = launchConfiguration.preloadTXTFileName ?? "\(title).txt"
                        _ = try TXTLibraryImporter(databaseManager: manager).importDocument(
                            title: title,
                            fileName: fileName,
                            rawText: rawText
                        )
                    } else if let preloadMarkdownURL = launchConfiguration.preloadMarkdownURL {
                        _ = try MarkdownLibraryImporter(databaseManager: manager).importDocument(from: preloadMarkdownURL)
                    } else if
                        let inlineBase64 = launchConfiguration.preloadMarkdownInlineBase64,
                        let data = Data(base64Encoded: inlineBase64),
                        let rawText = String(data: data, encoding: .utf8)
                    {
                        let title = launchConfiguration.preloadMarkdownTitle ?? "Preloaded"
                        let fileName = launchConfiguration.preloadMarkdownFileName ?? "\(title).md"
                        _ = try MarkdownLibraryImporter(databaseManager: manager).importDocument(
                            title: title,
                            fileName: fileName,
                            rawText: rawText
                        )
                    } else if let preloadRTFURL = launchConfiguration.preloadRTFURL {
                        _ = try RTFLibraryImporter(databaseManager: manager).importDocument(from: preloadRTFURL)
                    } else if
                        let inlineBase64 = launchConfiguration.preloadRTFInlineBase64,
                        let data = Data(base64Encoded: inlineBase64)
                    {
                        let title = launchConfiguration.preloadRTFTitle ?? "Preloaded"
                        let fileName = launchConfiguration.preloadRTFFileName ?? "\(title).rtf"
                        _ = try RTFLibraryImporter(databaseManager: manager).importDocument(
                            title: title,
                            fileName: fileName,
                            rawData: data
                        )
                    } else if let preloadDOCXURL = launchConfiguration.preloadDOCXURL {
                        _ = try DOCXLibraryImporter(databaseManager: manager).importDocument(from: preloadDOCXURL)
                    } else if
                        let inlineBase64 = launchConfiguration.preloadDOCXInlineBase64,
                        let data = Data(base64Encoded: inlineBase64)
                    {
                        let title = launchConfiguration.preloadDOCXTitle ?? "Preloaded"
                        let fileName = launchConfiguration.preloadDOCXFileName ?? "\(title).docx"
                        _ = try DOCXLibraryImporter(databaseManager: manager).importDocument(
                            title: title,
                            fileName: fileName,
                            rawData: data
                        )
                    } else if let preloadHTMLURL = launchConfiguration.preloadHTMLURL {
                        _ = try HTMLLibraryImporter(databaseManager: manager).importDocument(from: preloadHTMLURL)
                    } else if
                        let inlineBase64 = launchConfiguration.preloadHTMLInlineBase64,
                        let data = Data(base64Encoded: inlineBase64)
                    {
                        let title = launchConfiguration.preloadHTMLTitle ?? "Preloaded"
                        let fileName = launchConfiguration.preloadHTMLFileName ?? "\(title).html"
                        _ = try HTMLLibraryImporter(databaseManager: manager).importDocument(
                            title: title,
                            fileName: fileName,
                            rawData: data
                        )
                    } else if let preloadEPUBURL = launchConfiguration.preloadEPUBURL {
                        _ = try EPUBLibraryImporter(databaseManager: manager).importDocument(from: preloadEPUBURL)
                    } else if
                        let inlineBase64 = launchConfiguration.preloadEPUBInlineBase64,
                        let data = Data(base64Encoded: inlineBase64)
                    {
                        let title = launchConfiguration.preloadEPUBTitle ?? "Preloaded"
                        let fileName = launchConfiguration.preloadEPUBFileName ?? "\(title).epub"
                        _ = try EPUBLibraryImporter(databaseManager: manager).importDocument(
                            title: title,
                            fileName: fileName,
                            rawData: data
                        )
                    } else if let preloadPDFURL = launchConfiguration.preloadPDFURL {
                        _ = try PDFLibraryImporter(databaseManager: manager).importDocument(from: preloadPDFURL)
                    } else if
                        let inlineBase64 = launchConfiguration.preloadPDFInlineBase64,
                        let data = Data(base64Encoded: inlineBase64)
                    {
                        let title = launchConfiguration.preloadPDFTitle ?? "Preloaded"
                        let fileName = launchConfiguration.preloadPDFFileName ?? "\(title).pdf"
                        _ = try PDFLibraryImporter(databaseManager: manager).importDocument(
                            title: title,
                            fileName: fileName,
                            rawData: data
                        )
                    }

                    databaseManager = manager
                } catch {
                    databaseErrorMessage = error.localizedDescription
                }
            }
        }
    }
}
