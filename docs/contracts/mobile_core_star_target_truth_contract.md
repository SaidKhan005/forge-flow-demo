# Mobile Core Star And Target Truth Contract

Status: planning contract
Date: 2026-05-06
Owner: Phase 8 mobile core logic data wiring

## Purpose

This contract binds the next mobile core sprint from
`docs/archive/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md` after
`8.first-connect-backfill-wire-in`.

The sprint goal is plain:

1. Closed shift history produces star candidates.
2. Manager-selected stars become shared server truth.
3. Manager selection and clear actions write through the proxy with permission,
   idempotency, once-per-cycle validation, and audit.
4. Server target cycles and active target profiles become the shared truth that
   mobile mirrors locally.
5. Mobile no longer treats local SQLite star/target rows as the only durable
   owner of shared business decisions.

## Authority

1. `PROJECT_TRACKER.md`
2. `docs/archive/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`
3. `docs/contracts/core_app_architecture.md`
4. `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
5. `docs/contracts/integration_spine_architecture_contract.md`
6. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
7. `docs/contracts/slice_runtime_acceptance_contract.md`
8. `CLAUDE.md`

## Current Code Reality

The following local/mobile surfaces already exist and must be reused as cache
or pure-domain logic:

- `BaselineSelectionRepository`
- `SqliteBaselineSelectionRepository`
- `TargetCycleRepository`
- `SqliteTargetCycleRepository`
- `TargetProfileRepository`
- `SqliteTargetProfileRepository`
- `BaselineManagerService`
- `TargetCycleService`
- `TargetCyclePolicy`
- `TargetCycleActiveTargetProfileProjector`

Current repo search found no Postgres/proxy server owner for:

- selected star shift records
- target cycles
- active target profiles

That means the current app can calculate and cache star/target state locally,
but Doc 1's shared-truth contract is still open.

## Scope

This sprint includes:

- Additive selected-star server table or equivalent operator-scoped decision
  table.
- Additive server target-cycle and active-target-profile persistence.
- Server repositories and proxy routes for read/write/sync.
- Permission checks for manager/admin writes.
- Idempotency keys for writes.
- Audit events for selection, clear, manager override, and target replacement.
- Mobile sync from server truth into existing SQLite caches.
- Star/Baseline screen write path through proxy.
- Target/profile read path through server-backed local cache.
- Fixture proof that one device write becomes visible on another after sync.

This sprint excludes:

- Weekly plan snapshot server truth.
- Business scope hamburger selector.
- Group/region/company rollups.
- Push notification proof.
- Huge pressure suite.
- Live vendor/provider calls.

## Required End State

The accepted sprint proves this path:

```text
closed shift_records exist
-> star candidates render from closed history
-> manager selects or clears stars on mobile
-> mobile sends write to proxy
-> server checks permission and idempotency
-> server enforces once-per-cycle override rule
-> server writes selected-star decision truth and audit event
-> server writes/replaces target cycle
-> server projects active target profile
-> mobile sync pulls selected stars, target cycle, and active profile
-> another device sees the same selected stars and target profile
```

## Hard Rules

1. Mobile remains a cache. It may mirror selected stars, target cycles, and
   active target profiles, but it must not be the only durable owner.
2. Recommended stars and manager-selected stars are separate concepts.
3. No code may fabricate manager-selected rows from recommendations.
4. Manager override is permission-checked.
5. Manager override is idempotency-keyed.
6. Manager override is audit-logged.
7. The once-per-cycle manager override rule is enforced server-side.
8. Target cycles are server-owned and replacement preserves provenance.
9. Active target profile is a projection of the active target cycle.
10. Existing mobile SQLite tables are reused as caches; no duplicate mobile
    cache tables.
11. New Postgres tables are operator-scoped, RLS-enabled, and indexed with
    `operator_id` leading on B-tree hot paths.
12. Weekly plan snapshot creation remains out of scope for this sprint.

## Acceptance

Accept only when:

- Manager selection made on one device appears on another device after sync.
- Clearing a selection writes through proxy and syncs to another device.
- Permission failure returns an honest denied state and writes no decision row.
- Idempotent retry does not duplicate selection or target replacement rows.
- Once-per-cycle manager override denial is enforced server-side.
- Selected-star truth remains separate from recommendations.
- Target cycle and active target profile are projected server-side.
- Mobile reads server-backed local mirrors for target state.
- Targeted tests, analyzer, migration lints, and drift scanner pass.
- Proof document names what was simulated and what was not run.
