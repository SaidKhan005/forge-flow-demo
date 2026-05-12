# Mobile Core Weekly Plan Server Truth Contract

Status: planning contract
Date: 2026-05-06
Owner: Phase 8 mobile core logic data wiring

## Purpose

This contract binds the next mobile core sprint after
`8.star-target-server-truth`. It closes Doc 1 Phase 7 — making
weekly plan snapshots and forecast context server-owned truth that
mobile mirrors locally.

The sprint goal is plain:

1. The weekly plan snapshot a manager locks for "the week in force"
   becomes shared server truth.
2. Forecast context (covers/sales/labor demand drivers feeding the plan)
   becomes shared server truth.
3. Mobile no longer treats local SQLite weekly plan rows as the only
   durable owner of shared business decisions.
4. Schedule, Variance, and History reads pull through server truth so
   another device sees the same locked plan.

## Authority

1. `PROJECT_TRACKER.md`
2. `docs/archive/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`
3. `docs/contracts/core_app_architecture.md`
4. `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
5. `docs/contracts/mobile_core_star_target_truth_contract.md`
   (immediate predecessor — target cycles + active profiles must land
   first because weekly plans reference them)
6. `docs/contracts/integration_spine_architecture_contract.md`
7. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
8. `docs/contracts/slice_runtime_acceptance_contract.md`
9. `CLAUDE.md`

## Current Code Reality

The following local/mobile surfaces already exist and must be reused as
cache or pure-domain logic:

- `WeeklyPlanSnapshotService` (locks weekly plan locally)
- `SqliteWeeklyPlanSnapshotRepository`
- `WeeklyPlanLockedComparisonProjector` (Variance comparison source)
- `DemandForecastContextService` (forecast inputs)

Current repo search found no Postgres/proxy server owner for:

- weekly plan snapshots
- forecast context

That means the current app can lock a weekly plan and project Variance
locally, but Doc 1's shared-truth contract is still open. A Variance
result on Vanessa's iPad and a Variance result on the Operator Web
Console can disagree because each is reading its own local cache.

## Scope

This sprint includes:

- Additive Postgres `weekly_plan_snapshots` table (server-owned).
- Additive Postgres `forecast_context` table (server-owned).
- Server repositories and proxy routes for read/write/sync.
- Permission checks for manager writes (lock / unlock / replace).
- Idempotency keys for writes.
- Audit events for lock, replace, and unlock.
- Mobile sync from server truth into existing SQLite caches.
- Schedule / Variance / History read paths through server-backed local
  cache.
- Fixture proof that one device's lock becomes visible on another after
  sync.

This sprint excludes:

- Business scope hamburger selector (separate sprint —
  `mobile_core_business_scope_contract.md`).
- Group/region/company rollups.
- Push notification proof.
- Live vendor/provider calls.
- Larger pressure suite.

## Required End State

The accepted sprint proves this path:

```text
manager locks plan on iPad
-> mobile sends write to proxy
-> server checks permission and idempotency
-> server enforces "one active plan per (operator, location, week_start)"
-> server writes weekly_plan_snapshot decision truth and audit event
-> server writes forecast_context for the same week
-> proxy/mobile sync pulls the snapshot + forecast onto another device
-> Variance on the other device renders the same locked plan
```

## Hard Rules

1. Mobile remains a cache. It may mirror weekly plans + forecast
   context, but it must not be the only durable owner.
2. Locking a plan replaces the previously active plan for the same
   `(operator, location, week_start)`; the prior plan is preserved as a
   superseded row, not deleted.
3. Replacement preserves source, calibration window, effective window,
   and override metadata.
4. Manager lock is permission-checked.
5. Manager lock is idempotency-keyed.
6. Manager lock is audit-logged.
7. Forecast context is keyed by `(operator, location, business_date)`
   and rows for closed dates are immutable.
8. Existing mobile SQLite tables are reused as caches; no duplicate
   mobile cache tables.
9. New Postgres tables are operator-scoped, RLS-enabled, and indexed
   with `operator_id` leading on B-tree hot paths.
10. Weekly plans MUST FK to the `target_cycles` row that produced them;
    deleting a target cycle is forbidden while a weekly plan references
    it (RESTRICT FK).
11. Active target profile is consumed via the projection from the
    star-target sprint; no formula-rewrite path here.

## Acceptance

Accept only when:

- Manager-lock on one device produces a `weekly_plan_snapshots` row
  visible on another device after sync.
- Replacement creates a new active row and marks the prior row
  superseded with provenance.
- Permission failure returns an honest denied state and writes no
  decision row.
- Idempotent retry does not duplicate snapshots or forecast context
  rows.
- Variance / History / Schedule on each device read server-backed
  local mirrors.
- Targeted tests, analyzer, migration lints, and drift scanner pass.
- Proof document names what was simulated and what was not run.

## Lane shape (informational)

A future sprint plan will expand this into Lanes 0–5:

- Lane 0 — Postgres schema + repositories (V1.C is Lane 0)
- Lane 1 — proxy write/read routes
- Lane 2 — server projection / locking enforcement
- Lane 3 — mobile sync + cache mirrors
- Lane 4 — Schedule / Variance / History screen wiring
- Lane 5 — proof harness + closeout

V1.C in `2026-05-06_v1_closure_dispatch_plan.md` ships Lane 0 only.
