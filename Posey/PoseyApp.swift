//
//  PoseyApp.swift
//  Posey
//
//  Created by Mark Friedlander on 3/22/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// ========== BLOCK 1: APP ENTRY POINT - START ==========
@main
struct PoseyApp: App {
    // 2026-05-08 — UIApplicationDelegate adaptor wires
    // UNUserNotificationCenterDelegate so taps on Audio Export
    // completion banners route back into the app and post
    // .audioExportNotificationTapped (see PoseyAppDelegate.swift).
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(PoseyAppDelegate.self) private var appDelegate
    #endif

    private let launchConfiguration = AppLaunchConfiguration.current
    @State private var databaseManager: DatabaseManager?
    @State private var databaseErrorMessage: String?

    var body: some Scene {
        WindowGroup {
            // Task 10 (2026-05-03 — Mac Catalyst): on macOS, the
            // window can be resized arbitrarily by the user. Posey's
            // reader was designed for a phone-shaped portrait
            // viewport; below ~360 wide the chrome starts overlapping
            // and below ~480 tall the playback strip clips into the
            // text. Apply a sensible minimum so the layout always
            // has room to breathe.
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
                // Test-only orientation override. Useful for the simulator MCP
                // (which has no rotation API) and for future automated UI tests.
                // Pass POSEY_FORCE_ORIENTATION = portrait | landscape | landscapeLeft
                // | landscapeRight on launch. Silently no-ops on platforms
                // without UIKit window scenes.
                applyForcedOrientationIfNeeded()
            }
            #if targetEnvironment(macCatalyst)
            .frame(minWidth: 480, minHeight: 600)
            #endif
        }
        #if targetEnvironment(macCatalyst)
        .defaultSize(width: 720, height: 900)
        #endif
    }

    @MainActor
    private func applyForcedOrientationIfNeeded() {
        #if canImport(UIKit) && os(iOS)
        guard let raw = launchConfiguration.forceOrientation else { return }
        let mask: UIInterfaceOrientationMask
        switch raw.lowercased() {
        case "portrait":         mask = .portrait
        case "landscape":        mask = .landscapeRight
        case "landscapeleft":    mask = .landscapeLeft
        case "landscaperight":   mask = .landscapeRight
        default: return
        }
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
        #endif
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
