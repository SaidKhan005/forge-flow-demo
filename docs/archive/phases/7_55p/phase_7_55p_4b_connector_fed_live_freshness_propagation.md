# Phase 7.55p.4b — Connector-Fed Live Freshness Propagation

Status: Landed (includes 7.55p.4b1 settings-write dedup)

## Goal

Propagate current-state invalidation from app/runtime writes through one
shared app-owned seam so Shift and Variance surfaces refresh without
screen-local manual refresh choreography, while staying reload-driven
and future-compatible with real connector imports.

## Scope

- In: one shared `AppRuntimeInvalidationBus` that fires after write
  completion; `ForgeFlowScope` wires the bus into the coordinator's
  ProxyProvider2 so current-state surfaces refresh through the same
  `refreshCurrentStateSurfaces()` rule used by the active-target cascade;
  four `ShiftService` write paths publish the bus signal; Settings
  write actions use `refreshAfterWrite()` to avoid duplicate
  current-state refresh through the target cascade
- Out: websocket/polling/auto-refresh loops; stale-threshold redesign;
  notification scheduling (`7.55p.4d`); replay integrity audit
  (`7.55p.4c`); Shift/Variance business logic changes

## Touched Seams

| File | What changed |
|---|---|
| `lib/data/app_runtime_invalidation_bus.dart` | New. Singleton ChangeNotifier that signals current-state write completion |
| `lib/data/app_refresh_coordinator.dart` | Added `refreshAfterWrite()`: refreshes scope, demand, weights without target (avoids cascade to current-state since bus already handled it) |
| `lib/data/shift_service.dart` | `closeShift`, `reseedDemo`, `clearAllData`, `advanceMockReplayDay` now call `bus.notifyCurrentStateChanged()` after write completion |
| `lib/forge_flow_app.dart` | Bus exposed via `ChangeNotifierProvider.value`; coordinator changed from `ProxyProvider` to `ProxyProvider2` that triggers `refreshCurrentStateSurfaces()` on either target change or bus signal |
| `lib/screens/settings_screen.dart` | Write actions (reseedDemo, clearAllData, advanceMockReplayDay) call `_refreshAfterWrite()` which uses `coordinator.refreshAfterWrite()`. Wage changes still use `_refreshAppState()` which uses `coordinator.refreshAll()` |
| `test/app_runtime_invalidation_bus_test.dart` | New. Verifies bus notification mechanism, bus -> coordinator -> week/shift path, scope honesty |
| `test/app_refresh_coordinator_test.dart` | Added Group D: verifies `refreshAfterWrite()` touches scope/demand/weights but not target/week/shift |

## How It Works

### Write path (bus-driven)

1. `ShiftService` write method completes (e.g., `closeShift`)
2. Calls `AppRuntimeInvalidationBus.instance.notifyCurrentStateChanged()`
3. Bus fires `notifyListeners()` synchronously
4. `ForgeFlowScope`'s `ProxyProvider2` detects the bus change
5. Coordinator's `refreshCurrentStateSurfaces()` is called
6. `WeekDataNotifier` and `ShiftDashboardNotifier` refresh

### Settings write follow-up (deduped)

After Settings-triggered writes (reseedDemo, clearAllData,
advanceMockReplayDay), the bus already refreshed current-state surfaces
in the write path above. Settings then calls
`coordinator.refreshAfterWrite()` which refreshes scope, demand, and
weights — but skips target to avoid cascading to current-state through
ProxyProvider2 a second time.

### Wage change path (cascade-driven)

Wage changes do not fire the bus (they go through
WageStandardContextService, not ShiftService). Settings calls
`coordinator.refreshAll()` which includes target.refresh(). The target
cascade through ProxyProvider2 refreshes current-state surfaces. This
is the only current-state refresh for wage changes — no duplication.

### Why ProxyProvider2 instead of direct notifier listeners

The coordinator already owns the canonical current-state refresh rule
via `refreshCurrentStateSurfaces()` (landed in 7.55p.4a). By adding
the bus as a second dependency on the coordinator's ProxyProvider, both
triggers — active-target change and write completion — go through the
same shared rule. No new refresh paths, no duplication.

### Future connector compatibility

When real connector/import writers land (Phase 8), they call the same
`AppRuntimeInvalidationBus.instance.notifyCurrentStateChanged()` after
writing to SQLite. No new wiring needed — the existing path handles it.

## Remaining Gaps

- Current runtime freshness is still app-driven / reload-triggered.
  The bus is explicit write-completion signaling, not background-live.
- `AppDataStatus` evaluation remains on-demand (called from Settings
  and ShiftDashboardNotifier). No bus-driven status refresh.
- Replay integrity audit is deferred to `7.55p.4c`.
- Notification scheduling is deferred to `7.55p.4d`.
- `DemandForecastContextNotifier` and `ScheduleDistributionWeightsNotifier`
  are not wired to the bus. They reload on manual refresh only.
