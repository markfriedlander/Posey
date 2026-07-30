# SharedModelStoreKit 1.1.0 adoption — note for Posey's CC

**Date:** 2026-07-29 · **Made by:** Hal Universal's CC (cross-family change), with Mark's approval.

## What changed in this repo
1. **Bumped SharedModelStoreKit 1.0.2 → 1.1.0** (`Package.resolved`). 1.1.0 adds three package functions:
   `graceStampMissingHeartbeats()`, `reapStaleClaims()`, `clearEntireSharedStore()` (all unit-tested, 16/16 green).
2. **Launch active dead-app cleanup** — `PoseyAppDelegate.didFinishLaunching`: the existing off-main
   `Task.detached` now runs `graceStampMissingHeartbeats()` then `reapStaleClaims()` **before** the existing
   `sweepSupersededPlainCopies()`. Order matters and `touchHeartbeat()` runs first (so Posey is never seen as stale).
   - `reapStaleClaims()` drops provably-dead claimants across ALL models and deletes any now-unclaimed files. This is
     how a **deleted** family app's models finally get reclaimed (the old lease only reaped incidentally on release).
   - `graceStampMissingHeartbeats()` gives pre-lease (heartbeat-less) claims a fresh lease window so old immortal
     claims can eventually age out. Self-limiting.
   - Distinct from `sweepSupersededPlainCopies()` (that reclaims Posey's OWN superseded plain copies from the version
     migration; reap reclaims DEAD SIBLINGS' claims). Both kept.
3. **"Clear all family models" button** — added to `AskPoseyModelLibraryView` (Model Library screen), a new Storage
   Section at the bottom. Last-resort safety valve mirroring Hal's Maintenance screen: `clearEntireSharedStore()`
   removes EVERY shared model for the whole family at once AND resets the manifest (so no ghost entries, the
   manifest-aware counterpart to the 2026-07-15 accidental-wipe bug), then `refreshDownloadStates()`. Distinct from
   the per-model Delete rows (which give up only Posey's claim).

## Why
Dead-app cleanup: once the family expands, a deleted app's stale claims must not pin shared models forever. Every
family app runs the reap at launch, so whichever sibling runs next reclaims a departed app's models. Full story lives
in Hal's `HISTORY.md` (2026-07-29).

## Verified
Builds clean against 1.1.0; launched on the iPhone 16 Plus; the shared store stayed healthy after the reap ran (all
live-claimed models preserved, nothing wrongly deleted). The button compiles + mirrors Hal's device-verified one.

## For submission
No action needed here beyond the normal build/submit. If you re-pin the package, stay at ≥ 1.1.0.
