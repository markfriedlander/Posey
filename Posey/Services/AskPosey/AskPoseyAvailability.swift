import Foundation
import SharedModelStoreKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: TYPES - START ==========
/// Whether Ask Posey is usable on this device right now, and (if not) why.
///
/// The Ask Posey UI is gated on this value. Per `ask_posey_spec.md` resolved
/// decision 5 ("AFM unavailable: hide the Ask Posey interface entirely"),
/// the entry points (selection-menu item, bottom-bar glyph) are omitted —
/// not greyed out — when the state is anything other than `.available`.
public enum AskPoseyAvailabilityState: Equatable, Sendable {
    /// AFM is ready to take requests on this device.
    case available
    /// FoundationModels is not present (running on iOS < 26).
    case frameworkUnavailable
    /// Apple Intelligence isn't enabled in Settings.
    case appleIntelligenceNotEnabled
    /// Device hardware doesn't support AFM.
    case deviceNotEligible
    /// Model assets aren't installed yet (downloading or not provisioned).
    case modelNotReady
    /// FoundationModels surfaced an `Availability.UnavailableReason` we don't
    /// have a case for. The raw description is captured for diagnostics so
    /// future SDK additions don't silently fall through.
    case unknownUnavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}
// ========== BLOCK 01: TYPES - END ==========


// ========== BLOCK 02: AVAILABILITY SOURCE - START ==========
/// Single chokepoint for "is Ask Posey usable here?"
///
/// Calling code (sheet entry points, classifier, prompt builder) reads
/// `current` whenever it needs to decide whether to render UI or initiate a
/// request. Internally this is a small wrapper around
/// `SystemLanguageModel.default.availability` — the wrapper exists so the
/// rest of the codebase doesn't have to deal with `#available`,
/// `#canImport`, the `UnavailableReason` enum, or the simulator-vs-device
/// distinction every time it asks the question.
///
/// Cheap to call: under the hood it queries the framework directly each
/// time, no caching. AFM availability can change at runtime (Apple
/// Intelligence toggled in Settings, model assets finish downloading), and
/// caching would just produce stale `isAvailable` reads.
public struct AskPoseyAvailability {

    /// Read once whenever the UI needs to decide visibility.
    public static var current: AskPoseyAvailabilityState {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return resolve(SystemLanguageModel.default.availability)
        }
        return .frameworkUnavailable
        #else
        return .frameworkUnavailable
        #endif
    }

    /// Whether the reader-facing Ask Posey surfaces (sparkle glyph, contextual
    /// "Ask Posey" item, chat sheet) should be visible on this device.
    ///
    /// 2026-05-31 — Ask Posey is a **post-download unlock feature**. It is
    /// invisible in the reader until the user has downloaded the models it
    /// needs — **any non-default embedder** (retrieval ranking; Nomic or mxbai)
    /// AND **at least one MLX model** (answer generation). AFM is NOT part of
    /// this gate: AFM is used only for
    /// background `@Generable` auxiliary tasks (query expansion, document-metadata
    /// extraction) when present, and a device may unlock Ask Posey with no AFM at
    /// all.
    /// The preferences "Ask Posey" on-ramp stays visible regardless (it's how
    /// the user discovers + downloads what's needed) — only the *reader*
    /// surfaces are gated on this.
    ///
    /// `POSEY_ENABLE_ASK_POSEY` remains the build-level master switch (set in
    /// Debug today; flipped on for Release at submission). When compiled in,
    /// visibility is purely the runtime unlock below.
    public static var isAvailable: Bool {
        #if POSEY_ENABLE_ASK_POSEY
        return isUnlocked
        #else
        return false
        #endif
    }

    /// The runtime unlock condition: a non-default embedder provisioned AND ≥1
    /// MLX model downloaded AND no embedder swap in flight. Cheap, synchronous,
    /// isolation-free (UserDefaults + the non-isolated downloader + the static
    /// catalog), so SwiftUI can read it directly when deciding reader-chrome
    /// visibility.
    ///
    /// `!isSwapInProgress` (2026-06-17 — Rule 2 of the embedder-swap design):
    /// while a backend swap is building the target column, the reader surfaces
    /// hide so no query races the half-built column. The active backend's column
    /// stays complete and readable throughout — the lock is what lets the swap
    /// be non-destructive without ever needing two backends loaded for querying.
    /// Re-unlocks automatically when the swap completes and clears its marker.
    public static var isUnlocked: Bool {
        embedderProvisioned && hasDownloadedMLXModel && !EmbeddingBackend.isSwapInProgress
    }

    /// Whether Ask Posey is *set up* on this device — a non-default embedder
    /// provisioned AND ≥1 MLX model downloaded — REGARDLESS of an in-flight
    /// swap. The difference
    /// from `isUnlocked`: `isSetUp` stays true *during* an embedder swap, when
    /// `isUnlocked` is temporarily false.
    ///
    /// 2026-06-17 — the reader Ask Posey affordance keys its *visibility* on
    /// this (not `isUnlocked`), so that during a swap the sparkle stays put and
    /// shows an "upgrading…" status instead of *vanishing* (the "where did Ask
    /// Posey go?" gap the swap-lock opened). Whether it can be *opened* is a
    /// separate, finer check (`isUnlocked` + the document being done indexing).
    /// When Ask Posey isn't set up at all (`isSetUp == false`), there's no
    /// sparkle — the Preferences on-ramp is the path.
    public static var isSetUp: Bool {
        embedderProvisioned && hasDownloadedMLXModel
    }

    /// Present-based unlock (Mark, 2026-07-08): Ask Posey is provisioned only
    /// while the **active** embedder is an advanced, downloadable one — Nomic or
    /// mxbai — whose model is actually on disk. Selecting an advanced embedder
    /// provisions Ask Posey; deleting the active one (which reverts the active
    /// backend to the built-in NLContextual floor) drops this to false and
    /// re-locks. The Apple NLContextual embedder never unlocks Ask Posey — it's
    /// strong enough for the reader's search fallback, not for Ask Posey
    /// retrieval. Derived, not a persisted flag, so it tracks download / delete /
    /// select with no migration: the unlock simply follows what's present.
    public static var embedderProvisioned: Bool {
        guard let repo = EmbeddingBackend.current().modelID else { return false }
        // Disk-truth, not the downloader's tracking set: the active advanced
        // embedder's model must actually be on disk. Checking disk (rather than
        // `MLXModelDownloader.isModelDownloaded`) recognizes an embedder fetched
        // by ANY path — swift-embeddings' own snapshot, a prior install's
        // App-Group copy — not just ones this app's downloader recorded. The
        // active backend is never mid-download, so a plain presence check is safe.
        return SharedModelStore.isRepoDownloaded(repo)
    }

    /// True when at least one curated MLX model is present on disk. Mirrors
    /// `ModelCatalogService.downloadedModels`' MLX reconcile (`MLXModelDownloader
    /// .isModelDownloaded(id)`) but without the `@MainActor` hop.
    public static var hasDownloadedMLXModel: Bool {
        ModelCatalog.all.contains { model in
            model.source == .mlx && MLXModelDownloader.shared.isModelDownloaded(model.id)
        }
    }

    /// Human-readable explanation suitable for diagnostic logging. Not for
    /// end-user UI — the user-facing rule is "hide entirely when not
    /// available," so we never display a reason string to the user.
    public static var diagnosticDescription: String {
        switch current {
        case .available:
            return "available"
        case .frameworkUnavailable:
            return "FoundationModels framework not available (iOS < 26)"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence not enabled in Settings"
        case .deviceNotEligible:
            return "Device hardware not eligible for Apple Intelligence"
        case .modelNotReady:
            return "Apple Intelligence model assets not ready"
        case .unknownUnavailable(let reason):
            return "AFM unavailable (unknown reason): \(reason)"
        }
    }
}
// ========== BLOCK 02: AVAILABILITY SOURCE - END ==========


// ========== BLOCK 03: FOUNDATIONMODELS BRIDGE - START ==========
#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
extension AskPoseyAvailability {

    /// Convert FoundationModels' `Availability` into our local enum so the
    /// rest of the codebase can pattern-match without depending on the
    /// framework type directly. Centralising the mapping here also means a
    /// new `UnavailableReason` case in a future SDK release lands as
    /// `.unknownUnavailable` rather than a compile-time break.
    fileprivate static func resolve(_ availability: SystemLanguageModel.Availability)
        -> AskPoseyAvailabilityState
    {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .unknownUnavailable(reason: String(describing: reason))
            }
        @unknown default:
            return .unknownUnavailable(reason: String(describing: availability))
        }
    }
}
#endif
// ========== BLOCK 03: FOUNDATIONMODELS BRIDGE - END ==========
