import Foundation
import MediaPlayer

// ========== BLOCK 01: NOW PLAYING CONTROLLER - START ==========
/// Surfaces playback to the iOS lock screen + Control Center via
/// `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. Owned by
/// `ReaderViewModel` (which is where document title + active sentence
/// + the playback toggle methods all live). M8 lock-screen + background
/// audio support — load-bearing for the Motion-mode listening use case
/// (in your pocket while walking, cycling, driving).
///
/// Without this class, locking the phone mid-sentence loses the
/// playback metaphor: iOS shows a generic "Audio playing" placeholder
/// and the user has no controls. With it, Posey looks like a
/// first-class audio player — title visible, play/pause works, skip
/// commands jump sentences.
///
/// **Thread / lifecycle.** All MediaPlayer APIs are main-thread; this
/// type is `@MainActor`. The controller is initialized after the
/// ReaderViewModel has its document and playback service set up; it
/// configures the remote command center exactly once and tears it
/// down when the controller is deallocated. Repeated open/close of
/// the same document is safe — `update(...)` overwrites the now-playing
/// info; `clear()` removes it.
@MainActor
final class NowPlayingController {

    /// Closures to invoke when the user hits a remote command on the
    /// lock screen / Control Center / a paired headset. The host wires
    /// these to its toggle / next / previous methods.
    struct Commands {
        let togglePlayback: () -> Void
        let nextSentence: () -> Void
        let previousSentence: () -> Void
    }

    private let commands: Commands
    private var commandCenterTargets: [Any] = []

    init(commands: Commands) {
        self.commands = commands
        configureRemoteCommands()
    }

    deinit {
        // Capture before isolation domain switches at deinit time.
        let targets = commandCenterTargets
        Task { @MainActor in
            let center = MPRemoteCommandCenter.shared()
            for target in targets {
                center.playCommand.removeTarget(target)
                center.pauseCommand.removeTarget(target)
                center.togglePlayPauseCommand.removeTarget(target)
                center.nextTrackCommand.removeTarget(target)
                center.previousTrackCommand.removeTarget(target)
            }
            // Clear any lingering now-playing info so the lock screen
            // doesn't keep showing a stale "Posey is playing" entry.
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    /// Update the lock-screen metadata. Pass `playbackRate: 1.0` while
    /// playing and `0.0` while paused so iOS animates the time label
    /// correctly. `currentTime` and `duration` are optional — when
    /// nil, iOS just shows the title without a progress indicator.
    func update(
        title: String,
        sentenceText: String?,
        isPlaying: Bool,
        currentTime: TimeInterval? = nil,
        duration: TimeInterval? = nil
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: isPlaying ? 1.0 : 0.0)
        ]
        if let sentenceText, !sentenceText.isEmpty {
            // Use "artist" as the slot for the active sentence — it's
            // the natural secondary line under the title in the lock
            // screen layout. Trim to a reasonable length so a long
            // sentence doesn't overflow the chip.
            info[MPMediaItemPropertyArtist] = String(sentenceText.prefix(120))
        }
        if let currentTime {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: currentTime)
        }
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Clear lock-screen metadata. Call when the reader closes or
    /// the document changes so the lock screen doesn't keep showing
    /// stale info.
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Play / Pause / Toggle — all three exist because some
        // remote-control sources (headphones, CarPlay) only emit one
        // or the other. Wire them all to the same toggle.
        let toggleHandler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            self?.commands.togglePlayback()
            return .success
        }
        commandCenterTargets.append(center.playCommand.addTarget(handler: toggleHandler))
        commandCenterTargets.append(center.pauseCommand.addTarget(handler: toggleHandler))
        commandCenterTargets.append(center.togglePlayPauseCommand.addTarget(handler: toggleHandler))

        let nextHandler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            self?.commands.nextSentence()
            return .success
        }
        commandCenterTargets.append(center.nextTrackCommand.addTarget(handler: nextHandler))

        let prevHandler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            self?.commands.previousSentence()
            return .success
        }
        commandCenterTargets.append(center.previousTrackCommand.addTarget(handler: prevHandler))

        // Explicitly enable the commands we wired. iOS hides the
        // skip-track buttons by default unless they're enabled; for a
        // reading app with sentence-level granularity, surfacing them
        // gives the user real control.
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
    }
}
// ========== BLOCK 01: NOW PLAYING CONTROLLER - END ==========
