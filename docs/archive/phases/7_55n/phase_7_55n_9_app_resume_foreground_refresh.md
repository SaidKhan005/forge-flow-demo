# Phase 7.55n.9 - App Resume / Foreground Refresh

Updated: 2026-04-13 (7.55n.9a correctness cleanup applied)
Owner: Claude implementation
Status: Landed

## Goal

Revalidate current-state surfaces automatically when the app returns from
the background so Shift does not quietly keep showing stale in-memory state
after resume.

## Scope

- In: app lifecycle observation on AppShell, resume-triggered refresh
  through the shared coordinator seam, cold-start guards on both the
  lifecycle observer and the coordinator
- Out: polling, timers, websockets, background refresh, boundary
  auto-refresh (7.55n.10), vendor-live plumbing

## What This Establishes

1. `_AppShellState` is a `WidgetsBindingObserver` that listens for
   `AppLifecycleState` changes.

2. When the app transitions from `paused` to `resumed`, it calls
   `AppRefreshCoordinator.refreshCurrentStateSurfaces()` — the same
   shared seam used by the ProxyProvider2 and pull-to-refresh.

3. Two cold-start guards prevent duplicate refresh on initial build:

   a. **Coordinator guard** (`_coldStartComplete`): the first call to
      `refreshCurrentStateSurfaces()` is skipped. This absorbs the
      `ProxyProvider2.update()` that fires once on initial build before
      any real dependency change. Notifiers already load in their
      constructors, so this first proxy call is redundant.

   b. **Lifecycle guard** (`_hasBeenBackgrounded`): set to `true` only
      on `paused`, reset to `false` on each `resumed`. This prevents
      the lifecycle observer from refreshing on cold start AND prevents
      later `inactive -> resumed` transitions from false-positiving
      after a prior background cycle.

4. `inactive` alone (e.g., phone call overlay) does NOT trigger
   refresh on resume — only full backgrounding (`paused`) does. The
   flag reset ensures this holds even after a prior `paused -> resumed`
   cycle.

## 7.55n.9a — Correctness Cleanup

| Issue | Fix |
|---|---|
| ProxyProvider2.update() fires on cold start | Added `_coldStartComplete` guard to `AppRefreshCoordinator.refreshCurrentStateSurfaces()` — first call is a no-op |
| `_hasBeenBackgrounded` was sticky (never reset) | Now reset to `false` on each `resumed`, so later `inactive -> resumed` does not false-positive |
| Test harness used plain `Provider.value()` | Rewrote to use production-style `ProxyProvider2` wiring so cold-start proxy-update issues are caught |

## Touched Seams

| File | What changed |
|---|---|
| `lib/forge_flow_app.dart` | `_AppShellState` mixes in `WidgetsBindingObserver`. `didChangeAppLifecycleState` calls coordinator on `paused` -> `resumed` transitions. Flag reset on each `resumed`. |
| `lib/data/app_refresh_coordinator.dart` | Added `_coldStartComplete` guard: first `refreshCurrentStateSurfaces()` call is skipped (absorbs ProxyProvider2 initial build) |
| `test/app_resume_refresh_test.dart` | Rewritten. 8 tests with production-style ProxyProvider2 wiring: resume after pause, second cycle, proxy cold-start guard, resumed-without-pause, inactive-only, sticky-flag regression, coordinator seam, subsequent proxy updates |
| `test/app_refresh_coordinator_test.dart` | Group B setUp consumes cold-start skip. Added cold-start guard test. |

## Design Decisions

| Decision | Rationale |
|---|---|
| `paused` as the background trigger, not `inactive` | `inactive` fires during transient interruptions (phone call, permission dialog). Only full backgrounding (`paused`) justifies a data refresh on return. |
| Two-layer cold-start guard | Coordinator guard absorbs the ProxyProvider2 initial-build call. Lifecycle guard absorbs the framework's cold-start `resumed` event. Both are needed because they protect against different sources. |
| Flag reset on each `resumed` | Prevents the sticky-flag problem where a prior `paused -> resumed` cycle would make all subsequent `resumed` events fire, even `inactive -> resumed`. |
| Routes through `refreshCurrentStateSurfaces()` | Keeps the definition of "current-state surfaces" centralized in the coordinator. AppShell does not maintain its own refresh list. |

## Remaining Gaps

- Automatic boundary invalidation (7.55n.10): business-date, week, and
  60-day cycle rollover while the app is open
- Vendor live-data capability audit (7.55n.12)
- Freshness label on Shift does not tick live — re-evaluated on each
  refresh (pull-to-refresh, resume, or write-invalidation), not
  continuously
