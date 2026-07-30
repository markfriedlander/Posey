import Foundation
import UserNotifications
import SharedModelStoreKit

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
        // Cross-app model store (SharedModelStoreKit): tell the shared store which
        // App Group container this app uses, then stamp our "still alive" heartbeat
        // so our model claims aren't reaped as if this were an uninstalled app.
        // MUST run before any store access — without configure() the store falls back
        // to per-app Caches and already-downloaded models would read as absent.
        SharedModelStore.configure(appGroupID: "group.com.MarkFriedlander.aifamily")
        SharedModelStore.touchHeartbeat()

        // Launch store-maintenance, all off-main (coordinated file I/O), and after
        // configure() + touchHeartbeat() (which marks US alive so Posey is never reaped
        // as stale). In order:
        //  1. graceStampMissingHeartbeats() — give pre-lease (heartbeat-less) claims a
        //     fresh lease window so a long-deleted app's immortal claim can age out.
        //  2. reapStaleClaims() — drop provably-dead claimants across ALL models and
        //     delete any now-unclaimed model files. Every family app runs this so a
        //     deleted sibling's models get reclaimed by whoever launches (new in 1.1.0).
        //  3. sweepSupersededPlainCopies() — reclaim THIS app's own superseded plain
        //     (pre-version) copies from the version-safety migration (existing behavior).
        Task.detached {
            SharedModelStore.graceStampMissingHeartbeats()
            SharedModelStore.reapStaleClaims()
            sweepSupersededPlainCopies()
        }

        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Routes iOS background-URLSession resume events to the MLX downloader's
    /// `BackgroundDownloadCoordinator`. iOS calls this when the system needs
    /// to deliver pending events for a background session whose identifier
    /// matches `BackgroundDownloadCoordinator.backgroundSessionID` — including
    /// after the app was terminated and relaunched specifically to handle them.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloadCoordinator.backgroundSessionID else {
            // Unknown background session identifier — call the handler so
            // iOS doesn't keep us alive needlessly.
            completionHandler()
            return
        }
        BackgroundDownloadCoordinator.shared.backgroundCompletionHandler = completionHandler
    }
}

/// Launch-time sweep of superseded PLAIN copies (version-safety, no-orphans).
///
/// Before model identity carried a version, a curated model lived in its plain `repo`
/// folder. Now each curated (pinned, non-`plainFolderRepos`) model lives under its
/// version-stamped identity `repo@<sha>`, and the plain copy is never trusted. The
/// per-download / per-adopt reap (MLXModelDownloader) removes a plain copy the moment its
/// stamped replacement lands — but a model the user never re-triggers would keep its stale
/// plain copy forever. This closes that gap: for every pinned non-plain repo with a plain
/// copy still on disk, drop THIS app's claim on the bare id and, once no app in the family
/// still claims it, delete the folder.
///
/// Why this must run in EVERY family app, not just the one deleting a model: the store
/// deletes a shared copy only when the LAST claimant releases it. On a device with more than
/// one of the family apps installed, an old shared plain copy survives until every app that
/// still claims it has swept. Idempotent; a true no-op on a device that never had a
/// pre-version copy. `plainFolderRepos` (the embedders + sd-turbo) are skipped: their
/// required identity IS the bare id, so their plain folder is the real copy.
nonisolated func sweepSupersededPlainCopies() {
    let fm = FileManager.default
    for repoID in SharedModelStore.pinnedRevisions.keys {
        // Only stamped repos have a superseded plain form; this guard skips plainFolderRepos.
        guard SharedModelStore.requiredIdentity(forRepoID: repoID) != repoID else { continue }
        guard SharedModelStore.isRepoDownloaded(repoID) else { continue }
        // Drop our claim on the bare id; the store deletes files only when no app in the
        // family still claims it. Re-check presence before removing (a concurrent reap on
        // the same launch may have taken it already).
        let safeToDelete = SharedModelStore.releaseClaim(modelID: repoID)
        guard safeToDelete, SharedModelStore.isRepoDownloaded(repoID) else {
            dbgLog("MLX-SWEEP: kept plain copy of %@ — another app still claims it", repoID)
            continue
        }
        do {
            try fm.removeItem(at: SharedModelStore.mlxModelDir(repoID))
            dbgLog("MLX-SWEEP: reaped superseded plain copy of %@ (now version-stamped)", repoID)
        } catch {
            dbgLog("MLX-SWEEP: failed to reap plain %@: %@", repoID, error.localizedDescription)
        }
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
