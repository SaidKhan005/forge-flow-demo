# Phase 7.55n.10 - Automatic Boundary Invalidation / Refresh

Updated: 2026-04-13
Owner: Claude implementation
Status: Landed

## Goal

Automatically refresh current-state surfaces when the app stays open across
a restaurant-local business-date boundary, so Shift and Variance do not
silently keep showing old current-state after the business date changes
underneath an already-foregrounded app.

## Scope

- In: foreground-only business-date boundary monitor, boundary-triggered
  refresh through the shared coordinator seam, lifecycle integration with
  the existing resume path (7.55n.9), dedup between resume and boundary
  refresh
- Out: background refresh, timers that run while backgrounded, websockets,
  polling, vendor-live plumbing, widget-local refresh lists, UI changes to
  Shift or Variance, import-completion propagation (7.55n.11)

## What This Establishes

1. `CurrentStateBoundaryMonitor` is a lightweight foreground-only
   `Timer.periodic` (1-minute default) that periodically resolves the
   current business date and compares it to the last known value.

2. When the business date changes, the monitor fires a callback that
   routes through `AppRefreshCoordinator.refreshCurrentStateSurfaces()` —
   the same shared seam used by ProxyProvider2, pull-to-refresh, and
   app-resume refresh.

3. **Business date is the master boundary signal.** Week rollover and
   60-day cycle rollover are handled downstream, not through separate
   watchers:
   - `WeeklyPlanSnapshotService.getCurrentWeekSnapshot()` already resolves
     week-span rollover on each refresh call
   - `TargetCycleService.getOrCreateActiveCycle()` already detects cycle
     expiration and auto-refreshes on each call
   - A boundary-triggered `refreshCurrentStateSurfaces()` causes these
     services to re-evaluate on the next surface read

4. The monitor is foreground-only:
   - Started on initial app mount (via `addPostFrameCallback`)
   - Stopped on `AppLifecycleState.paused`
   - Re-seeded and restarted on `AppLifecycleState.resumed` (after the
     resume refresh from 7.55n.9)
   - Stopped on widget dispose

5. Dedup between resume refresh and boundary monitor:
   - When the app resumes, 7.55n.9 fires `refreshCurrentStateSurfaces()`
   - The monitor re-seeds to the current business date on restart
   - If the date changed while backgrounded, the resume path already
     handled the refresh; the monitor's baseline is now the new date
   - Subsequent periodic checks find no change → no duplicate refresh

6. Initial seed does NOT fire the callback. Notifiers already load in
   their constructors, and the ProxyProvider2 cold-start guard (7.55n.9a)
   absorbs the first coordinator call.

## Touched Seams

| File | What changed |
|---|---|
| `lib/services/current_state_boundary_monitor.dart` | **New.** Foreground-only periodic boundary monitor with injectable clock, resolver, and interval. try/catch resilience around resolver calls. |
| `lib/forge_flow_app.dart` | `AppShell` gains `testBusinessDateResolver` for test injection. `_AppShellState` creates, starts, stops, and re-seeds the boundary monitor on lifecycle transitions. |
| `test/current_state_boundary_monitor_test.dart` | **New.** 13 unit tests: seed behavior, boundary detection, deduplication, start/stop lifecycle, resolver resilience. |
| `test/app_boundary_refresh_test.dart` | **New.** 7 integration tests with production-style ProxyProvider2 wiring: boundary-triggered refresh, initial-mount no-op, lifecycle stop/restart, resume dedup, multiple boundary changes. |

## Design Decisions

| Decision | Rationale |
|---|---|
| Business date as the sole boundary signal | Week and cycle rollovers are already resolved downstream by existing services on refresh. A separate watcher for each boundary would add complexity without benefit. |
| 1-minute check interval | One SQLite config read + pure date math per minute is negligible overhead. Ensures boundary changes are detected within 1 minute while foregrounded. |
| Re-seed on resume, not just restart | Prevents the monitor from detecting a boundary "change" that the resume path already handled. The re-seed updates the baseline to the current date before periodic checking resumes. |
| try/catch around resolver calls | Makes the monitor resilient to resolver failures (no timing config, no DB, test environments without SQLite). The monitor simply skips failed checks instead of crashing. |
| `testBusinessDateResolver` on AppShell | Allows integration tests to control the business date without requiring SQLite. The production callback always routes through the coordinator. |
| No changes to AppRefreshCoordinator | The existing `refreshCurrentStateSurfaces()` is sufficient. The monitor is an additional trigger source, not a new refresh path. |

## Timezone Limitation

`BusinessDateAuthorityService.resolveBusinessDate()` expects a
restaurant-local timestamp. Full timezone-conversion support is not yet
landed in the repo. The production wiring passes `DateTime.now()` which
is correct only when the device timezone matches the restaurant timezone.

This limitation is inherited from the existing business-date authority
seam and is documented honestly here. It will be resolved when full
timezone conversion lands (queued under the timing implementation gaps
in the time-boundary contract).

## Week / Cycle Rollover Honesty

Week and 60-day cycle rollovers are NOT detected by separate boundary
watchers. They are resolved **downstream** through the existing refresh
path:

- A boundary-triggered `refreshCurrentStateSurfaces()` refreshes
  `WeekDataNotifier` and `ShiftDashboardNotifier`
- Those notifiers re-read through `ShiftService`, which calls
  `WeeklyPlanSnapshotService.getCurrentWeekSnapshot()` and
  `TargetCycleService.getOrCreateActiveCycle()`
- Those services already resolve rollover on each call

This is indirect but correct and honest. The boundary monitor does not
pretend to detect week or cycle boundaries directly — it detects the
master business-date boundary and lets the existing downstream services
handle the derived boundaries.

## Remaining Gaps

- Full timezone conversion for business-date resolution (documented above)
- Runtime write / import completion freshness propagation (7.55n.11)
- Vendor live-data capability audit (7.55n.12)
- Freshness label on Shift does not tick live — re-evaluated on each
  refresh (pull-to-refresh, resume, boundary, or write-invalidation),
  not continuously
