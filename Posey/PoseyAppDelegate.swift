import Foundation
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

// ========== BLOCK 01: APP DELEGATE - START ==========
/// Bridges UIKit lifecycle into the SwiftUI App for the bits SwiftUI
/// can't express directly — currently:
/// - `UNUserNotificationCenterDelegate` so taps on Audio Export
///   completion notifications route back into the app and present
///   the share sheet via `.audioExportNotificationTapped`.
/// - Foreground-presentation policy so the banner+sound still
///   appears when Posey is the frontmost app at delivery time.
///
/// Wired into `PoseyApp` via `@UIApplicationDelegateAdaptor`.
final class PoseyAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
}
// ========== BLOCK 01: APP DELEGATE - END ==========


// ========== BLOCK 02: USER NOTIFICATION CENTER DELEGATE - START ==========
extension PoseyAppDelegate: UNUserNotificationCenterDelegate {

    /// Foreground delivery. Without this method iOS suppresses
    /// notification UI when the app is frontmost; with it we ask iOS
    /// to show the banner + play the sound regardless. The user can
    /// still tap-to-share or ignore.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Tap handler. Pulls the file URL out of `userInfo` and posts
    /// `.audioExportNotificationTapped` for whichever surface is
    /// observing — the open `AudioExportSheet` re-presents the
    /// share sheet; if the sheet isn't currently up, the post sits
    /// in the notification center and a fresh sheet observer (for
    /// example, when the user re-enters the export sheet manually)
    /// is responsible for surfacing the latest export. We
    /// deliberately do NOT auto-open the share sheet here without an
    /// existing observer — surprise modals on launch were the
    /// anti-pattern this redesign eliminates.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo

        // Re-marshal to a Sendable userInfo dict for our observers.
        var forwarded: [String: Any] = [:]
        if let pathString = info[AudioExportNotificationKeys.fileURL] as? String {
            forwarded[AudioExportNotificationKeys.fileURL] = URL(fileURLWithPath: pathString)
        }
        if let docID = info[AudioExportNotificationKeys.documentID] as? String, !docID.isEmpty {
            forwarded[AudioExportNotificationKeys.documentID] = docID
        }
        if let title = info[AudioExportNotificationKeys.documentTitle] as? String {
            forwarded[AudioExportNotificationKeys.documentTitle] = title
        }

        NotificationCenter.default.post(
            name: .audioExportNotificationTapped,
            object: nil,
            userInfo: forwarded
        )
        completionHandler()
    }
}
// ========== BLOCK 02: USER NOTIFICATION CENTER DELEGATE - END ==========
