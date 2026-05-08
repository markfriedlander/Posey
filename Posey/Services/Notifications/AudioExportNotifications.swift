import Foundation
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

// ========== BLOCK 01: NOTIFICATION NAMES + USERINFO KEYS - START ==========
extension Notification.Name {
    /// Posted by `PoseyAppDelegate.userNotificationCenter(_:didReceive:)`
    /// when the user taps a delivered Audio Export notification.
    /// `userInfo` carries `audioExportFileURL` (URL) and
    /// `audioExportDocumentID` (String UUID, optional).
    /// Observed by `AudioExportSheet` (and the antenna SIMULATE verb)
    /// to re-present the share-sheet path the user asked for.
    static let audioExportNotificationTapped =
        Notification.Name("audioExportNotificationTapped")
}

enum AudioExportNotificationKeys {
    static let fileURL = "audioExportFileURL"
    static let documentID = "audioExportDocumentID"
    static let documentTitle = "audioExportDocumentTitle"
}
// ========== BLOCK 01: NOTIFICATION NAMES + USERINFO KEYS - END ==========


// ========== BLOCK 02: COORDINATOR - START ==========
/// Coordinates local-notification permission and delivery for the
/// Audio Export feature. The flow Mark specified (2026-05-08):
///
/// 1. User taps Export → request notification permission if not yet
///    granted (system prompt).
/// 2. Export runs as a UIApplication background task so it survives
///    lock screen / app switch.
/// 3. On completion the coordinator fires a local notification.
/// 4. User tapping the notification routes through
///    `PoseyAppDelegate` → posts `.audioExportNotificationTapped`,
///    which the open `AudioExportSheet` (or its re-opened instance)
///    listens for and uses to present the share sheet.
///
/// Crucially the share sheet **never** appears on its own — the
/// completion path just delivers a notification and (if the app is
/// foregrounded with the export sheet visible) lights up the manual
/// Share button. Auto-popping a share sheet on a backgrounded user
/// was the broken experience this redesign replaces.
@MainActor
final class AudioExportNotifications {
    static let shared = AudioExportNotifications()

    private init() {}

    private let categoryIdentifier = "AudioExportComplete"

    /// Cached after first `requestAuthorization` so subsequent exports
    /// don't pay the round-trip. Reset when the system settings
    /// change is observed (we re-check on every export kickoff
    /// regardless — this is just a hot-path memo).
    private var lastKnownStatus: UNAuthorizationStatus = .notDetermined

    /// Returns true if notifications are authorized (or provisionally
    /// authorized). False if the user denied or the system can't
    /// schedule. Safe to call repeatedly; only prompts on first
    /// `.notDetermined`.
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        lastKnownStatus = settings.authorizationStatus
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(
                    options: [.alert, .sound, .badge]
                )
                lastKnownStatus = granted ? .authorized : .denied
                return granted
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Schedule a completion notification for a finished export.
    /// Delivers immediately (1-second trigger so the system has time
    /// to wire it up). Replaces any pending notification with the
    /// same identifier so back-to-back exports don't pile up.
    func scheduleCompletionNotification(
        fileURL: URL,
        documentID: UUID?,
        documentTitle: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Export Complete"
        content.body = "\"\(documentTitle)\" is ready to share."
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = [
            AudioExportNotificationKeys.fileURL: fileURL.path,
            AudioExportNotificationKeys.documentID: documentID?.uuidString ?? "",
            AudioExportNotificationKeys.documentTitle: documentTitle
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let identifier = "audioExport.complete.\(documentID?.uuidString ?? UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                #if DEBUG
                NSLog("[AudioExportNotifications] schedule failed: \(error)")
                #endif
            }
        }
    }

    /// Schedule a failure notification. Same delivery characteristics.
    /// Optional — the sheet's `.failed` UI also surfaces the reason —
    /// but if the user has backgrounded the app this is the only way
    /// they'll learn the export errored before they reopen Posey.
    func scheduleFailureNotification(
        documentID: UUID?,
        documentTitle: String,
        reason: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Export Failed"
        content.body = "\"\(documentTitle)\": \(reason)"
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let identifier = "audioExport.failed.\(documentID?.uuidString ?? UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
// ========== BLOCK 02: COORDINATOR - END ==========
