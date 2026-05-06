# Mobile Core First Connection Backfill Contract

Status: planning contract
Date: 2026-05-06
Owner: Phase 8 mobile core logic data wiring

## Purpose

This contract binds the next mobile core sprint from
`docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`.
It closes the first-connection spine and the production wire-in gap left after
the live/closed truth component sprint.

The sprint goal is plain:

1. A newly connected vendor must enqueue a bounded 60-day backfill.
2. The worker must call the vendor adapter `backfill()` path and write
   canonical facts through the existing Postgres sink seams.
3. The first committed canonical batch must trigger the same demo-mode flip
   policy already used by sinks.
4. Backfilled canonical facts must run the closed-shift aggregation and writer
   path so mobile can pull real `shift_records`.
5. Current/open canonical facts must invoke the existing
   `OpenShiftSnapshotProjector` instead of leaving it dormant.

## Authority

1. `PROJECT_TRACKER.md`
2. `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`
3. `docs/contracts/integration_spine_architecture_contract.md`
4. `docs/contracts/phase_7_55_time_boundary_contract.md`
5. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
6. `docs/contracts/slice_runtime_acceptance_contract.md`
7. `CLAUDE.md`

## Current Code Reality

The following surfaces already exist and must be reused:

- `BackfillCommand` and `BackfillResult` in
  `lib/services/integration/integration_adapter_common.dart`.
- `adapter.backfill()` implementations on several accepted adapters.
- `CanonicalSink` with canonical fact upsert, watermark, sync-log, and
  demo-flip seams.
- `DemoModeFlipPolicy`, which flips only after connected plus first backfill
  committed at least one row.
- `CanonicalFactToClosedShiftInputAggregator` and
  `PostgresShiftRecordWriter`.
- `OpenShiftSnapshotProjector`.
- Mobile/proxy pull paths for `shift_records`, `open_shift_snapshots`, and
  `demo_mode_states`.

The missing production pieces are:

- A durable first-backfill work queue or claimable job seam.
- Admin connect routes that enqueue that work after credential/connection
  persistence.
- A worker path that claims backfill work and calls `adapter.backfill()`.
- A post-commit projector/orchestrator that invokes closed aggregation and the
  live snapshot projector from real canonical fact writes.
- A small proof that a first connection can go from backfill to mobile-visible
  closed history without manual seeding.

## Scope

This sprint includes:

- Additive backfill job schema or an equivalent durable claim surface.
- Backfill job repository and pure planning types.
- Admin connect enqueue on OAuth callback and key-paste connect.
- Backfill worker dispatch using the already-defined adapter `backfill()`
  method.
- Backfill status exposure through existing sync/status patterns.
- Production wire-in for existing closed aggregator/writer and
  `OpenShiftSnapshotProjector`.
- Minimal fixture proof using accepted adapter/sink surfaces.

This sprint excludes:

- Star shift manager selection server truth.
- Target cycle server truth.
- Active target profile server truth.
- Weekly plan snapshot server truth.
- Business scope hamburger selector.
- Push notification proof.
- Huge pressure suite.
- Vendor lifecycle promotion.

## Hard Rules

1. Mobile remains a cache. It may read backfill status and cached server rows,
   but it must not run vendor backfill or talk to Postgres directly.
2. Backfill window is bounded to the requested 60-day window unless an explicit
   operator action requests a different bounded window.
3. Watermark persists per committed batch, not only at end of backfill.
4. Sanity hook runs per candidate row with `isDeliberateBackfill: true`.
5. Demo mode flips only after `connected` plus first committed backfill batch
   with at least one row.
6. Disconnect does not auto-revert demo mode.
7. Closed rows preserve prior target and timing provenance on replay.
8. Live snapshots are provisional and must not overwrite closed
   `shift_records`.
9. Any new Postgres table is operator-scoped, RLS-enabled, and indexed with
   `operator_id` leading on B-tree hot paths.
10. No duplicate mobile cache tables. Use existing mobile caches.
11. No banned Phase 8 lean-cut patterns: no KMS surface, no parse warnings or
    parse partial facts, no advisory locks, no custom drain handler, no raw
    payload partition scheme, and no DLQ tile.

## Required End State

The accepted sprint proves this path:

```text
admin connects vendor
-> connector_connection persists
-> first 60-day backfill work is enqueued
-> worker claims work
-> adapter.backfill() writes canonical facts through sink
-> watermark persists per batch
-> demo_mode_state flips only after first committed row
-> closed aggregator writes shift_records for completed periods
-> open projector writes open_shift_snapshots for current periods
-> proxy exposes changed rows
-> mobile SQLite stores rows
-> app status leaves setup/demo state honestly
```

## Acceptance

Accept only when:

- New connection creates exactly one active first-backfill job per
  connection/category/window.
- Replaying the same connect request is idempotent.
- Worker resumes from persisted cursor and does not duplicate canonical facts.
- First committed backfill row flips demo mode, zero-row backfill does not.
- Closed `shift_records` are produced from backfilled canonical facts.
- Open snapshots are produced from current/open canonical facts.
- Mobile sync can pull the rows and status through proxy.
- Targeted tests, analyzer, migration lints, and drift scanner pass.
- Proof document names what was simulated and what was not run.
