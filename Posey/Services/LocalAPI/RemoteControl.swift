import Foundation
import SwiftUI
import UIKit

// ========== BLOCK 01: NOTIFICATION NAMES - START ==========
/// Notifications the local API posts to drive the running app's UI
/// programmatically. Built per Mark's 2026-05-02 directive: the API
/// must be able to do everything a human can do that isn't blocked
/// by Apple security policies. Each name maps to a single user
/// intent observed by exactly one view layer.
///
/// Pattern follows the existing `.openAskPoseyForDocument`
/// convention — the API verb in `LibraryViewModel.executeAPICommand`
/// posts the notification, the relevant SwiftUI view observes via
/// `.onReceive` and performs the equivalent of a user action.
extension Notification.Name {
    /// `userInfo["documentID"]: UUID`, `userInfo["offset"]: Int`.
    /// ReaderView observes; calls `viewModel.jumpToOffset(_:)`.
    static let remoteReaderJumpToOffset = Notification.Name("PoseyRemoteReaderJumpToOffset")

    /// `userInfo["documentID"]: UUID`, `userInfo["offset"]: Int`.
    /// ReaderView observes; calls the same handler the in-app
    /// double-tap gesture invokes (jumpToOffset + restart at that
    /// sentence).
    static let remoteReaderDoubleTap = Notification.Name("PoseyRemoteReaderDoubleTap")

    /// No userInfo. ReaderView observes; presents the Notes sheet.
    static let remoteOpenNotesSheet = Notification.Name("PoseyRemoteOpenNotesSheet")

    /// No userInfo. Observed by every modal sheet host
    /// (AskPoseyView, NotesSheet, etc.) — calls `dismiss()`.
    static let remoteDismissPresentedSheet = Notification.Name("PoseyRemoteDismissPresentedSheet")

    /// `userInfo["documentID"]: UUID`, `userInfo["offset"]: Int`,
    /// `userInfo["body"]: String`. Drives the real save flow:
    /// jumps to the offset so `currentSentenceIndex` matches, sets
    /// `noteDraft`, calls `saveDraftNoteForCurrentSentence()`.
    static let remoteCreateNote = Notification.Name("PoseyRemoteCreateNote")

    /// `userInfo["documentID"]: UUID`, `userInfo["offset"]: Int`.
    /// ReaderView observes; jumps to offset then calls
    /// `addBookmarkForCurrentSentence()`.
    static let remoteCreateBookmark = Notification.Name("PoseyRemoteCreateBookmark")

    /// `userInfo["accessibilityID"]: String`. ReaderView /
    /// AskPoseyView / etc. don't observe this — it's handled in
    /// `RemoteControl.tap(accessibilityID:)` which walks the key
    /// window's UIView tree directly.
    static let remoteScrollToAccessibilityID = Notification.Name("PoseyRemoteScrollToAccessibilityID")

    /// No userInfo. ReaderView observes; calls `toggleChrome()` —
    /// the same code path as a real in-reader tap. Used by the
    /// API to verify chrome reveal/dismiss behavior on device
    /// without needing a synthesized touch event.
    static let remoteReaderToggleChrome = Notification.Name("PoseyRemoteReaderToggleChrome")

    /// `userInfo["storageID"]: String`. AskPoseyView observes; runs
    /// the same closure tapping the anchor row in the thread runs
    /// (cancel in flight, jump reader to anchor offset, dismiss).
    /// Built because SwiftUI's accessibility bridging in iOS 17+
    /// makes the generic TAP-by-id verb unreliable on synthetic
    /// elements; intent-level dispatch always works.
    static let remoteTapAskPoseyAnchor = Notification.Name("PoseyRemoteTapAskPoseyAnchor")

    /// `userInfo["entryID"]: String`. NotesSheet observes; runs the
    /// same handler `handleSavedAnnotationTap` runs on a real tap
    /// (expand for notes, jump+dismiss for bookmarks, dismiss+open
    /// Ask Posey for conversations).
    static let remoteTapSavedAnnotation = Notification.Name("PoseyRemoteTapSavedAnnotation")

    /// `userInfo["entryID"]: String`. NotesSheet observes; jumps
    /// the reader to the note's offset and dismisses (same as tapping
    /// "Jump to Note" inside an expanded note).
    static let remoteTapJumpToNote = Notification.Name("PoseyRemoteTapJumpToNote")

    /// `userInfo["entryID"]: String`. NotesSheet observes; calls
    /// `proxy.scrollTo(entryID, anchor: .top)` to bring the matching
    /// Saved Annotation row into view. Substitute for the device-side
    /// scroll gesture the test driver can't perform.
    static let remoteScrollSavedAnnotations = Notification.Name("PoseyRemoteScrollSavedAnnotations")

    /// `userInfo["citationNumber"]: Int`. AskPoseyView observes;
    /// fires the same dispatch path the inline-citation tap fires
    /// (resolve N → chunk on most-recent assistant message →
    /// onJumpToChunk + dismiss). Substitute for the per-link tap
    /// gesture the test driver can't synthesize on a SwiftUI
    /// markdown link.
    static let remoteTapCitation = Notification.Name("PoseyRemoteTapCitation")

    // ===== Playback transport (2026-05-02) ===========================
    /// `userInfo["documentID"]: UUID`. ReaderView observes; calls
    /// `viewModel.togglePlayback()` if currently paused/idle.
    static let remotePlaybackPlay = Notification.Name("PoseyRemotePlaybackPlay")
    /// `userInfo["documentID"]: UUID`. ReaderView observes; calls
    /// `viewModel.togglePlayback()` if currently playing.
    static let remotePlaybackPause = Notification.Name("PoseyRemotePlaybackPause")
    /// `userInfo["documentID"]: UUID`. ReaderView observes; calls
    /// `viewModel.goToNextMarker()`.
    static let remotePlaybackNext = Notification.Name("PoseyRemotePlaybackNext")
    /// `userInfo["documentID"]: UUID`. ReaderView observes; calls
    /// `viewModel.goToPreviousMarker()`.
    static let remotePlaybackPrevious = Notification.Name("PoseyRemotePlaybackPrevious")
    /// `userInfo["documentID"]: UUID`. ReaderView observes; calls
    /// `viewModel.restartFromBeginning()`.
    static let remotePlaybackRestart = Notification.Name("PoseyRemotePlaybackRestart")

    // ===== Sheet opens ==============================================
    /// No userInfo. ReaderView observes; sets `isShowingPreferencesSheet`.
    static let remoteOpenPreferencesSheet = Notification.Name("PoseyRemoteOpenPreferencesSheet")
    /// No userInfo. ReaderView observes; sets `isShowingTOCSheet`.
    static let remoteOpenTOCSheet = Notification.Name("PoseyRemoteOpenTOCSheet")
    /// No userInfo. ReaderPreferencesSheet observes; sets the sheet's
    /// internal `isShowingAudioExport` state.
    static let remoteOpenAudioExportSheet = Notification.Name("PoseyRemoteOpenAudioExportSheet")
    /// No userInfo. ReaderView observes; sets `isSearchActive` on the
    /// view model so the search bar appears.
    static let remoteOpenSearchBar = Notification.Name("PoseyRemoteOpenSearchBar")

    // ===== Library nav ==============================================
    /// `userInfo["documentID"]: UUID`. LibraryView observes; pushes
    /// the matching document onto the navigation path.
    static let remoteOpenDocument = Notification.Name("PoseyRemoteOpenDocument")
    /// No userInfo. LibraryView observes; pops the navigation path.
    static let remoteLibraryNavigateBack = Notification.Name("PoseyRemoteLibraryNavigateBack")
    /// No userInfo. LibraryView observes; toggles antenna OFF (re-enable
    /// is user-consent-gated and intentionally NOT exposed).
    static let remoteAntennaOff = Notification.Name("PoseyRemoteAntennaOff")

    // ===== Preferences ==============================================
    /// `userInfo["isCustom"]: Bool`. ReaderView observes; calls
    /// `viewModel.setVoiceMode(isCustom:)`.
    static let remoteSetVoiceMode = Notification.Name("PoseyRemoteSetVoiceMode")
    /// `userInfo["rate"]: Float` (0.1–1.0 normalized). ReaderView
    /// observes; updates the playback service's custom-mode rate.
    static let remoteSetRate = Notification.Name("PoseyRemoteSetRate")
    /// `userInfo["fontSize"]: Double`. ReaderView observes; sets
    /// `viewModel.fontSize`.
    static let remoteSetFontSize = Notification.Name("PoseyRemoteSetFontSize")
    /// `userInfo["readingStyle"]: String` (raw value: standard, focus,
    /// immersive, motion). ReaderView observes; sets
    /// `viewModel.readingStyle`.
    static let remoteSetReadingStyle = Notification.Name("PoseyRemoteSetReadingStyle")
    /// `userInfo["motionPreference"]: String` (raw value: off, on,
    /// auto). ReaderView observes; sets `viewModel.motionPreference`.
    static let remoteSetMotionPreference = Notification.Name("PoseyRemoteSetMotionPreference")

    // ===== TOC + search =============================================
    /// `userInfo["documentID"]: UUID`, `userInfo["page"]: Int`.
    /// ReaderView observes; calls `viewModel.jumpToPage(_:)`.
    static let remoteJumpToPage = Notification.Name("PoseyRemoteJumpToPage")
    /// `userInfo["query"]: String`. ReaderView observes; activates
    /// search and sets `viewModel.searchQuery`.
    static let remoteSetSearchQuery = Notification.Name("PoseyRemoteSetSearchQuery")
    /// No userInfo. ReaderView observes; calls
    /// `viewModel.goToNextSearchMatch()`.
    static let remoteSearchNext = Notification.Name("PoseyRemoteSearchNext")
    /// No userInfo. ReaderView observes; calls
    /// `viewModel.goToPreviousSearchMatch()`.
    static let remoteSearchPrevious = Notification.Name("PoseyRemoteSearchPrevious")
    /// No userInfo. ReaderView observes; calls
    /// `viewModel.deactivateSearch()`.
    static let remoteSearchClear = Notification.Name("PoseyRemoteSearchClear")
}
// ========== BLOCK 01: NOTIFICATION NAMES - END ==========


// ========== BLOCK 02: WINDOW UTILITIES - START ==========
/// Helpers for the `TAP`, `TYPE`, `READ_TREE`, and `SCREENSHOT`
/// commands. Walk the live UIView hierarchy under the active
/// UIWindow — SwiftUI bridges `.accessibilityIdentifier(_:)` onto
/// the underlying UIView via UIHostingController, so an identifier
/// search finds SwiftUI buttons, fields, and rows just like UIKit
/// ones. `accessibilityActivate()` triggers the underlying tap
/// action without faking a UITouch event.
@MainActor
enum RemoteControl {

    /// The key window of the foreground active scene. Returns nil
    /// during launch transitions or background — callers fall
    /// through to a clear error response.
    static var keyWindow: UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if windowScene.activationState == .foregroundActive ||
               windowScene.activationState == .foregroundInactive {
                if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                    return key
                }
                if let any = windowScene.windows.first {
                    return any
                }
            }
        }
        return nil
    }

    /// First responder at or below `root` whose `accessibilityIdentifier`
    /// matches `id`. SwiftUI sets `.accessibilityIdentifier(_:)` on the
    /// auto-synthesized UIAccessibilityElement rather than on the
    /// underlying UIView, so the walker descends into both
    /// `subviews` and `accessibilityElements`. Returns the first
    /// match — UIView when the id is on the view itself,
    /// UIAccessibilityElement otherwise. Both respond to
    /// `accessibilityActivate()`.
    static func findResponder(accessibilityID id: String, in root: NSObject) -> NSObject? {
        if let view = root as? UIView, view.accessibilityIdentifier == id {
            return view
        }
        if let element = root as? UIAccessibilityElement,
           element.accessibilityIdentifier == id {
            return element
        }
        // accessibilityElements is the SwiftUI-bridged surface
        if let elements = (root.value(forKey: "accessibilityElements") as? [Any]) {
            for raw in elements {
                guard let obj = raw as? NSObject else { continue }
                if let hit = findResponder(accessibilityID: id, in: obj) { return hit }
            }
        }
        if let view = root as? UIView {
            for sub in view.subviews {
                if let hit = findResponder(accessibilityID: id, in: sub) { return hit }
            }
        }
        return nil
    }

    /// Back-compat alias kept so external code expecting a UIView
    /// keeps compiling — only returns a hit when it IS a UIView.
    static func findView(accessibilityID id: String, in root: UIView) -> UIView? {
        findResponder(accessibilityID: id, in: root) as? UIView
    }

    /// Walks every active window plus every presented view
    /// controller in the chain; returns the first matching responder
    /// (UIView or UIAccessibilityElement). Searches presented
    /// controllers FIRST so a tap on a sheet's "Done" button finds
    /// the sheet's button rather than the reader's underneath.
    static func locate(accessibilityID id: String) -> NSObject? {
        for window in allWindows {
            var presented = window.rootViewController?.presentedViewController
            var stack: [UIViewController] = []
            while let p = presented {
                stack.append(p)
                presented = p.presentedViewController
            }
            for vc in stack.reversed() {
                if let hit = findResponder(accessibilityID: id, in: vc.view) { return hit }
            }
            if let hit = findResponder(accessibilityID: id, in: window) { return hit }
        }
        return nil
    }

    /// Activate the matched responder as if the user tapped it.
    /// SwiftUI elements respond to `accessibilityActivate()` whether
    /// the id is bridged onto a UIView or a UIAccessibilityElement.
    /// Returns false when the identifier isn't found in the live tree.
    static func tap(accessibilityID id: String) -> Bool {
        guard let target = locate(accessibilityID: id) else { return false }
        if let view = target as? UIView { return view.accessibilityActivate() }
        if let element = target as? UIAccessibilityElement { return element.accessibilityActivate() }
        return false
    }

    /// Insert text into the first responder. Used after a `TAP`
    /// targets a TextField so the field becomes first responder,
    /// then `TYPE` shoves text into it. Falls back to inserting
    /// directly into a UIKeyInput-conforming responder if the
    /// matched view exposes one.
    static func type(text: String) -> Bool {
        guard let window = keyWindow else { return false }
        if let responder = window.firstResponderInHierarchy() as? UIKeyInput {
            responder.insertText(text)
            return true
        }
        return false
    }

    /// Snapshot the active key window into a PNG. Returns nil when
    /// no foreground-active window is available.
    static func screenshotPNG() -> Data? {
        guard let window = keyWindow else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return image.pngData()
    }

    /// All windows across all foreground scenes, including any sheet
    /// presentation containers iOS may have promoted to a separate
    /// UIWindow.
    static var allWindows: [UIWindow] {
        var windows: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            guard windowScene.activationState == .foregroundActive ||
                  windowScene.activationState == .foregroundInactive else { continue }
            windows.append(contentsOf: windowScene.windows)
        }
        return windows
    }

    /// Recursive JSON-friendly dump of the accessibility-relevant
    /// subset of the view tree. Each node has id (accessibility
    /// identifier), label, value, frame, kind (UIView class name),
    /// hidden, isAccessibilityElement, and children.
    /// Walks every window plus every presented controller in every
    /// scene so SwiftUI sheets — which iOS often puts in their own
    /// presentation container — show up in the dump.
    static func readTree() -> [String: Any] {
        let windows = allWindows
        guard !windows.isEmpty else { return ["error": "No active windows"] }
        var nodes: [[String: Any]] = []
        for window in windows {
            nodes.append(dump(view: window))
            var presented = window.rootViewController?.presentedViewController
            while let p = presented {
                nodes.append(dump(view: p.view))
                presented = p.presentedViewController
            }
        }
        return ["windows": nodes]
    }

    private static func dump(view: UIView) -> [String: Any] {
        var node = baseNode(for: view)
        var children: [[String: Any]] = []
        if let elements = view.accessibilityElements as? [NSObject] {
            for el in elements {
                children.append(dumpAny(el))
            }
        }
        for sub in view.subviews {
            children.append(dump(view: sub))
        }
        if !children.isEmpty { node["children"] = children }
        return node
    }

    /// Generic dispatcher — handles UIView, UIAccessibilityElement,
    /// and any NSObject by best-effort. SwiftUI accessibility trees
    /// mix UIView nodes with synthetic UIAccessibilityElement leaves,
    /// so the walker has to handle both.
    private static func dumpAny(_ obj: NSObject) -> [String: Any] {
        if let view = obj as? UIView { return dump(view: view) }
        return baseNode(for: obj)
    }

    private static func baseNode(for obj: NSObject) -> [String: Any] {
        var node: [String: Any] = [
            "kind": String(describing: Swift.type(of: obj))
        ]
        if let view = obj as? UIView {
            node["frame"] = [view.frame.origin.x, view.frame.origin.y,
                             view.frame.size.width, view.frame.size.height]
            node["hidden"] = view.isHidden
        }
        if let element = obj as? UIAccessibilityElement {
            let frame = element.accessibilityFrame
            node["frame"] = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        }
        node["isAccessibilityElement"] = (obj.value(forKey: "isAccessibilityElement") as? Bool) ?? false
        if let id = (obj.value(forKey: "accessibilityIdentifier") as? String), !id.isEmpty {
            node["id"] = id
        }
        if let label = (obj.value(forKey: "accessibilityLabel") as? String), !label.isEmpty {
            node["label"] = label
        }
        if let value = (obj.value(forKey: "accessibilityValue") as? String), !value.isEmpty {
            node["value"] = value
        }
        return node
    }
}
// ========== BLOCK 02: WINDOW UTILITIES - END ==========


// ========== BLOCK 03: UIVIEW FIRST-RESPONDER HELPER - START ==========
private extension UIView {
    /// Walk the responder chain rooted at this view to find the
    /// first responder. UIKit doesn't expose a public API for this
    /// outside of UIResponder.next traversal from a known starting
    /// point, so we recurse through subviews looking for one that
    /// reports `isFirstResponder == true`.
    func firstResponderInHierarchy() -> UIResponder? {
        if isFirstResponder { return self }
        for sub in subviews {
            if let hit = sub.firstResponderInHierarchy() { return hit }
        }
        return nil
    }
}
// ========== BLOCK 03: UIVIEW FIRST-RESPONDER HELPER - END ==========


// ========== BLOCK 04: REMOTE-CONTROL STATE BRIDGE - START ==========
/// MainActor-isolated cache of the live reader state so the
/// `READER_STATE` API verb can answer "where is the reader right now"
/// without hopping through SwiftUI environment plumbing. ReaderView
/// updates these fields on appear, sentence change, and disappear;
/// the API just reads.
@MainActor
final class RemoteControlState {
    static let shared = RemoteControlState()
    private init() {}

    var visibleDocumentID: UUID?
    var currentSentenceIndex: Int = 0
    var currentOffset: Int = 0
    var playbackState: String = "idle"
    var presentedSheet: String?
    var isSearchActive: Bool = false
    var searchQuery: String = ""
    var searchMatchCount: Int = 0
    var currentSearchMatchPosition: Int = 0

    func snapshot() -> [String: Any] {
        var dict: [String: Any] = [
            "currentSentenceIndex": currentSentenceIndex,
            "currentOffset": currentOffset,
            "playbackState": playbackState,
            "isSearchActive": isSearchActive,
            "searchQuery": searchQuery,
            "searchMatchCount": searchMatchCount,
            "currentSearchMatchPosition": currentSearchMatchPosition
        ]
        if let id = visibleDocumentID { dict["visibleDocumentID"] = id.uuidString }
        if let s = presentedSheet { dict["presentedSheet"] = s }
        return dict
    }
}
// ========== BLOCK 04: REMOTE-CONTROL STATE BRIDGE - END ==========


// ========== BLOCK 05: REMOTE TARGET REGISTRY - START ==========
/// Central registry of every interactive UI element in the app,
/// keyed by stable string id. Each control registers itself on
/// appear and unregisters on disappear via the
/// `.remoteRegister(_:action:)` View modifier. The `TAP:<id>` API
/// verb looks up the registered closure and fires it — equivalent
/// to a user tap, since the registered closure IS the same closure
/// the button's action fires.
///
/// **Why this exists.** SwiftUI's `.accessibilityIdentifier(_:)` on
/// iOS 26 doesn't reliably bridge through to either the UIView's
/// `accessibilityIdentifier` property or the
/// `accessibilityElements` chain — empirically the live UIView tree
/// returns 0 surfaced ids. Walking the tree to find views by
/// identifier therefore can't drive SwiftUI buttons. This registry
/// sidesteps the bridging entirely: the View modifier stores the
/// action under the same id at appear-time, the API fires it
/// directly. Per Mark's "everything a human can do" standard
/// (2026-05-02 directive); the audit identified TAP as the one
/// generic capability the notification-based intent dispatch
/// couldn't cover, and this is the long-term fix.
@MainActor
final class RemoteTargetRegistry {
    static let shared = RemoteTargetRegistry()
    private init() {}

    private var actions: [String: () -> Void] = [:]

    func register(_ id: String, action: @escaping () -> Void) {
        actions[id] = action
    }

    func unregister(_ id: String) {
        actions.removeValue(forKey: id)
    }

    @discardableResult
    func fire(_ id: String) -> Bool {
        guard let action = actions[id] else { return false }
        action()
        return true
    }

    /// Snapshot of all currently-registered ids. Useful for the
    /// `LIST_REMOTE_TARGETS` verb so test scripts can discover what's
    /// tappable on the active screen without enumerating the source.
    func registeredIDs() -> [String] {
        actions.keys.sorted()
    }
}

extension View {
    /// Register the view as a remote-tap target under `id`, and set
    /// `.accessibilityIdentifier(id)` for VoiceOver/UI-test parity.
    /// Registers on appear, unregisters on disappear so a tap target
    /// is only callable when the user could see and tap it. Pass the
    /// SAME closure the button's `action:` fires — the registry then
    /// dispatches an exact-equivalent tap.
    func remoteRegister(_ id: String, action: @escaping () -> Void) -> some View {
        self
            .accessibilityIdentifier(id)
            .onAppear { RemoteTargetRegistry.shared.register(id, action: action) }
            .onDisappear { RemoteTargetRegistry.shared.unregister(id) }
    }
}
// ========== BLOCK 05: REMOTE TARGET REGISTRY - END ==========
