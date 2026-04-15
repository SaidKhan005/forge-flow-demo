# Phase 7.55n.11 - Runtime Write + Import Completion Freshness Propagation

Updated: 2026-04-13
Owner: Claude implementation
Status: Landed

## Goal

Make the current-state freshness propagation contract explicit so both
app/runtime writes and future connector/import completion events refresh
current-state surfaces through one shared, named seam — not just
comment-implied convention.

## Scope

- In: explicit named producer entrypoints on the shared invalidation bus,
  alignment of existing write paths to the explicit contract,
  import-completion entrypoint for future connectors, focused tests
- Out: actual Phase 8 connector/import implementation, new refresh lists,
  polling/websocket/background loops, UI changes, broad coordinator
  redesign

## What This Establishes

1. `AppRuntimeInvalidationBus` now exposes two explicit named producer
   entrypoints:

   a. **`notifyRuntimeWriteCompleted()`** — called after app/runtime
      writes that change current-state operational data. Used by
      `ShiftService.closeShift()`, `.reseedDemo()`, `.clearAllData()`,
      and `.advanceMockReplayDay()`.

   b. **`notifyImportCompletionPersisted()`** — called after a connector
      or import writer finishes persisting fresher current-state
      operational data. No live connector implementation exists yet.
      This is the explicit contract that future Phase 8 adapters will
      call after persisting canonical operational facts.

2. Both entrypoints converge on the same `notifyListeners()` signal.
   ForgeFlowScope's ProxyProvider2 routes that signal through
   `AppRefreshCoordinator.refreshCurrentStateSurfaces()` — the same
   shared rule used by the active-target cascade, app resume (7.55n.9),
   and boundary invalidation (7.55n.10).

3. The backward-compatible `notifyCurrentStateChanged()` method remains
   for existing test wiring and non-producer call sites. New producers
   should use the named entrypoints.

4. ShiftService's four write paths now call `notifyRuntimeWriteCompleted()`
   instead of the undifferentiated `notifyCurrentStateChanged()`.

## What This Does Not Establish

- No actual connector or import implementation
- No vendor polling, webhooks, or socket behavior
- No new downstream refresh path — everything still routes through the
  existing coordinator seam
- No transport-layer semantics on the bus — it remains a pure
  invalidation signal that does not carry payloads or connection state

## Touched Seams

| File | What changed |
|---|---|
| `lib/data/app_runtime_invalidation_bus.dart` | Added `notifyRuntimeWriteCompleted()` and `notifyImportCompletionPersisted()` as explicit named producer entrypoints. Kept `notifyCurrentStateChanged()` for backward compatibility. Updated header comments. |
| `lib/data/shift_service.dart` | `closeShift`, `reseedDemo`, `clearAllData`, `advanceMockReplayDay` now call `notifyRuntimeWriteCompleted()` instead of `notifyCurrentStateChanged()`. |
| `test/app_runtime_invalidation_bus_test.dart` | Rewritten. 20 tests across 6 groups: runtime-write entrypoint, import-completion entrypoint, both-through-coordinator, scope isolation, scope honesty, backward compatibility. |
| `test/current_state_propagation_contract_test.dart` | **New.** 11 tests across 3 groups: API shape, convergence through coordinator, honesty (no connector implementation implied). |

## Design Decisions

| Decision | Rationale |
|---|---|
| Two named entrypoints, not one generic method | Makes the producer path explicit in the call site. A future reader seeing `notifyImportCompletionPersisted()` knows the call came from a connector path, not a Settings action. |
| Both converge on `notifyListeners()` | The downstream refresh behavior is the same regardless of producer. The bus carries an invalidation signal, not a payload. Named entrypoints are about producer clarity, not differential downstream behavior. |
| Keep `notifyCurrentStateChanged()` | Backward compatibility for test wiring (e.g., `_TestBus` in app_boundary_refresh_test) where the producer path is not the thing being tested. |
| No arguments on `notifyImportCompletionPersisted()` | The bus does not know or care what was imported. A connector calls this after it has already persisted data to the canonical store. The bus just says "something changed." |
| No separate import-completion bus | One bus, one downstream path. Splitting would add complexity without behavioral difference. |

## Future Connector Contract

When a Phase 8 adapter or import writer finishes persisting fresher
current-state operational data to the canonical store, it should:

```dart
AppRuntimeInvalidationBus.instance.notifyImportCompletionPersisted();
```

This will cause ForgeFlowScope's ProxyProvider2 to call
`AppRefreshCoordinator.refreshCurrentStateSurfaces()`, which refreshes
`WeekDataNotifier` and `ShiftDashboardNotifier` — the same path used by
runtime writes, app resume, and boundary invalidation.

The connector does NOT need to:
- know which notifiers to refresh
- call the coordinator directly
- manage widget-local refresh lists
- carry payload data on the bus signal

## Remaining Gaps

- Vendor live-data capability audit (7.55n.12) — what real vendor APIs
  can support: event-driven updates, polling fallback, freshness SLA
- Proof and blocker cleanup (7.55n.13) — end-to-end validation including
  the pre-existing `snapshot_blended_wage` schema column gap
