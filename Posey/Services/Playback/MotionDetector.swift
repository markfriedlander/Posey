import Combine
import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

// ========== BLOCK 01: MOTION DETECTOR - START ==========
/// CoreMotion-backed device-movement classifier for the M8 Motion
/// reading style's Auto sub-preference. Reports a simple boolean —
/// "is the user moving?" — based on `CMMotionActivityManager` activity
/// classifications + a low-pass filter on accelerometer magnitude.
///
/// **Privacy contract.** Per `DECISIONS.md` "Motion Mode Three-Setting
/// Design" (2026-05-01), CoreMotion never engages without explicit
/// user consent. The detector won't `start()` unless the caller
/// passes `consented: true`. Motion data stays on-device and is
/// never persisted beyond the in-flight `isMoving` value.
///
/// **Lifecycle.** Owned by `ReaderViewModel` (only when the user has
/// chosen Motion + Auto). Stop on view-model deinit, on user changing
/// sub-preference away from `.auto`, on app backgrounding. Restart
/// when the user re-enables.
///
/// `@MainActor` because the `isMoving` `@Published` flag drives a
/// SwiftUI view update — must mutate on main.
@MainActor
final class MotionDetector: ObservableObject {

    /// True when the device has been moving consistently for the
    /// last few samples; false when stationary. The render path uses
    /// this to decide between Motion (large centered) and the user's
    /// last non-Motion style.
    @Published private(set) var isMoving: Bool = false

    #if canImport(CoreMotion)
    // Lazy — created the first time `start(consented: true)` runs.
    // iOS will not show the "Allow Motion & Fitness" permission
    // prompt until a CoreMotion API is touched. By deferring the
    // manager construction itself we make absolutely sure no
    // stray instantiation can race a launch-time prompt. (Per
    // Mark's Task 2 #26 — the permission must only ever appear
    // after the user explicitly chooses Auto in Reading Style.)
    private var activityManager: CMMotionActivityManager?
    private var motionManager: CMMotionManager?
    private var isStarted = false

    /// Smoothed acceleration magnitude over the last N samples — used
    /// as a fallback when CMMotionActivity isn't authorized but
    /// raw motion is. Above 0.05g sustained = "moving."
    private var smoothedAcceleration: Double = 0.0
    #endif

    init() {}

    /// Start monitoring. No-op when consent is missing — this is the
    /// gate that enforces the privacy contract.
    func start(consented: Bool) {
        guard consented else { return }
        #if canImport(CoreMotion)
        guard !isStarted else { return }
        isStarted = true

        // Lazy construction — by the time we get here the user has
        // chosen Auto AND granted in-app consent. Only now do we
        // touch CoreMotion APIs; iOS will surface its system
        // permission dialog at this point, never earlier.
        let activity = activityManager ?? CMMotionActivityManager()
        activityManager = activity
        let motion = motionManager ?? CMMotionManager()
        motionManager = motion

        // Prefer high-level activity classification when authorized
        // (uses very little battery; fuses Apple's built-in models).
        if CMMotionActivityManager.isActivityAvailable() {
            activity.startActivityUpdates(to: OperationQueue.main) { [weak self] activity in
                guard let self, let activity else { return }
                let movingClasses =
                    activity.walking || activity.running || activity.cycling || activity.automotive
                self.isMoving = movingClasses && activity.confidence != .low
            }
        }

        // Fallback: low-pass-filter accelerometer magnitude. Engages
        // even when activity classification isn't yet emitting (e.g.
        // first-second-after-start).
        if motion.isAccelerometerAvailable, !motion.isAccelerometerActive {
            motion.accelerometerUpdateInterval = 0.5
            motion.startAccelerometerUpdates(to: OperationQueue.main) { [weak self] data, _ in
                guard let self, let data else { return }
                let g = data.acceleration
                // Subtract gravity (~1g downward) by computing the
                // magnitude minus 1, then absolute-valuing.
                let magnitude = sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
                let delta = abs(magnitude - 1.0)
                // Exponential moving average — smooths jitter.
                self.smoothedAcceleration = 0.7 * self.smoothedAcceleration + 0.3 * delta
                if !CMMotionActivityManager.isActivityAvailable() {
                    self.isMoving = self.smoothedAcceleration > 0.05
                }
            }
        }
        #endif
    }

    /// Stop monitoring. Call when the user disables Auto, when the
    /// reader closes, or when the app backgrounds. Cheap to call
    /// repeatedly.
    func stop() {
        #if canImport(CoreMotion)
        if let activity = activityManager,
           CMMotionActivityManager.isActivityAvailable() {
            activity.stopActivityUpdates()
        }
        if let motion = motionManager, motion.isAccelerometerActive {
            motion.stopAccelerometerUpdates()
        }
        isStarted = false
        smoothedAcceleration = 0
        isMoving = false
        #endif
    }

    deinit {
        #if canImport(CoreMotion)
        // Stop accelerometer + activity updates synchronously — the
        // managers are reentrant and stopping is idempotent. Only
        // touch them if they were ever instantiated.
        activityManager?.stopActivityUpdates()
        motionManager?.stopAccelerometerUpdates()
        #endif
    }
}
// ========== BLOCK 01: MOTION DETECTOR - END ==========
