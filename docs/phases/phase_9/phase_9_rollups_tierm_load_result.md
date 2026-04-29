# Phase 9 Rollups Tier-M Load-Test Result

Status: SCAFFOLDED — NOT LIVE-RUN.
Generated: 2026-04-29.

This is the result template for B38 (Rollup pg_cron Tier-M load test —
cutover.0b row 8). The harness exists; no live measurements are
recorded yet. The B38 gate and cutover.0b row 8 are NOT cleared by
this document. They clear only after an authorized operator captures
real staging measurements that meet the thresholds locked in the
"Thresholds and tripwires" section below.

## Authority

This result doc is governed by:

- `docs/phases/phase_9/phase_9_execution_backlog.md` — B38 only.
- `docs/phases/phase_9/phase_9_scalability_performance_audit_2026-04-27.md`
  — Prelaunch Performance Test Matrix → Rollups row.
- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`
  — Q3.1 (refresh strategy), Q3.6 (idempotency), Q3.7 (freshness),
  Q3.9 (error handling), Q3.10 (observability).
- Migrations 202604280010_a / b / c — schema under test.
- `lib/services/rollups/rollup_worker.dart` — worker primitives.
- `tool/rollups_load_test/synth_seed.dart` — synthetic seed harness.

## Intended Tier-M profile

Locked by B38:

| Axis                   | Value                  |
| ---------------------- | ---------------------- |
| Operators              | 500                    |
| Locations per operator | 200                    |
| Days                   | 90                     |
| Metric families        | sales, labor, traffic  |
| Start date             | 2026-01-01             |

Row counts (deterministic):

- `rollup_business_day` rows: 500 × 200 × 90 × 3 = 27,000,000.
- Prerequisite rows: 500 operators + 500 root org_units + 100,000
  locations = 101,000.
- `aggregation_state` rows seeded: 1
  (`rollup_table='rollup_business_day'`, `grain='business_day'`,
  `last_processed_seq=0`).

## Live preflight checklist

Every step is the responsibility of the authorized staging operator.
This doc and the harness do NOT execute any of these steps.

- [ ] Migrations 202604280010_a / b / c applied on the staging
      Postgres instance via the standard staging migration channel.
- [ ] Reserved synthetic-ID prefixes confirmed unused on staging
      (the harness uses `00000000-0000-0001-0000-` for operators,
      `00000000-0000-0002-0000-` for org_units, and the
      `-0000-0003-0000-` middle segment for locations).
- [ ] Synthetic SQL emitted with
      `dart run tool/rollups_load_test/synth_seed.dart --emit-sql
      --output=build/rollups_load_test/tierm.sql
      --confirm-tier-m-scale`.
- [ ] Synthetic SQL applied on staging via the standard migration
      channel. The harness never connects to a database; the operator
      runs psql.
- [ ] `cron.job` lists `forge_rollup_hot_path` (60 s) and
      `forge_rollup_cold_path` (300 s).
- [ ] NOTIFY traffic on the `rollups_tick` channel observed (at
      least one hot-path tick and one cold-path tick).
- [ ] Rollup worker (`lib/services/rollups/rollup_worker.dart`)
      pointed at staging; `aggregation_state.lease_owner` reflects
      the worker identity.
- [ ] Approved staging measurement window opened (start time + end
      time recorded below).
- [ ] `pg_stat_statements` reset before the window so capture is
      clean.

## Metrics table

Fill in per measurement window. One row per
`(grain, path, run_id)`. Numbers below are placeholders; do not
treat any populated value here as evidence of a live run until this
notice is removed.

| Grain          | Path | p50 (ms) | p95 (ms) | p99 (ms) | Queue depth | Freshness lag (s) | Claim contention (winners/total) | aggregation_state advancement (Δseq/min) |
| -------------- | ---- | -------- | -------- | -------- | ----------- | ----------------- | -------------------------------- | ---------------------------------------- |
| business_day   | hot  |  TBD     |  TBD     |  TBD     |    TBD      |     TBD           |             TBD                  |               TBD                        |
| daypart        | hot  |  TBD     |  TBD     |  TBD     |    TBD      |     TBD           |             TBD                  |               TBD                        |
| week           | cold |  TBD     |  TBD     |  TBD     |    TBD      |     TBD           |             TBD                  |               TBD                        |
| accounting_period | cold | TBD   |  TBD     |  TBD     |    TBD      |     TBD           |             TBD                  |               TBD                        |
| month          | cold |  TBD     |  TBD     |  TBD     |    TBD      |     TBD           |             TBD                  |               TBD                        |
| quarter        | cold |  TBD     |  TBD     |  TBD     |    TBD      |     TBD           |             TBD                  |               TBD                        |
| year           | cold |  TBD     |  TBD     |  TBD     |    TBD      |     TBD           |             TBD                  |               TBD                        |

Capture sources:

- p50 / p95 / p99 latency: `pg_stat_statements` filtered to the
  `rollup_acquire_lease`, `INSERT ... ON CONFLICT` UPSERTs against
  `rollup_<grain>`, and the `aggregation_state` advance UPDATE.
- Queue depth: count of `(rollup_table, grain)` rows whose
  `last_run_status IN ('leased', 'idle')` and whose
  `last_processed_seq < high_watermark` at sample time.
- Freshness lag: `now() - max(computed_at)` per grain, sampled at
  one-minute intervals across the window.
- Claim contention: from the worker logs, count of
  `rollup_acquire_lease` calls that returned TRUE vs FALSE per
  `(rollup_table, grain)` per minute.
- `aggregation_state` advancement: `Δlast_processed_seq` per minute
  per `(rollup_table, grain)` row.

## Thresholds and tripwires

Locked thresholds (placeholders until the first live run sets the
floor; do NOT clear B38 against placeholders):

| Metric                                 | Threshold (TBD on first live run) | Tripwire (alert at) |
| -------------------------------------- | --------------------------------- | ------------------- |
| business_day p95 (hot path)            | TBD ms                            | TBD ms              |
| business_day p99 (hot path)            | TBD ms                            | TBD ms              |
| daypart p95 (hot path)                 | TBD ms                            | TBD ms              |
| Cold-path p95 (any of week / period / month / quarter / year) | TBD ms | TBD ms |
| Hot-path freshness lag (sustained)     | < 90 s                            | > 120 s             |
| Cold-path freshness lag (sustained)    | < 600 s                           | > 900 s             |
| Hot-path missed cron windows           | 0 in window                       | 1                   |
| Cold-path missed cron windows          | 0 in window                       | 1                   |
| Claim contention                       | TBD%                              | TBD%                |
| `aggregation_state` no-advance interval | < 2× the cron interval           | > 3× the cron interval |

Targets are set on the first authorized staging run. The values above
are shape-only; populate them once a real measurement exists.

## Blocker — end-to-end recomputation path

The current repo CANNOT exercise the full pg_cron + worker
recomputation cycle end-to-end at Tier-M, because the vendor-side
aggregator that produces the RAW facts the worker would aggregate
FROM has not landed. That work follows post-7.58 vendor connector
payload finalization.

Concretely:

- The harness in `tool/rollups_load_test/synth_seed.dart` seeds the
  ROLLUP table directly with synthetic rows plus one
  `aggregation_state` watermark row. It does NOT seed any source
  fact table because no canonical fact table exists yet.
- The worker's `claimBatch` / `flushBatch` path is exercised in unit
  tests (`test/phase_9_0sigma_k_rollups_test.dart`) against a fake
  Postgres executor, NOT against a 27-million-row live workload.
- The hot-path / cold-path `pg_notify` cycle can be observed on
  staging once the migrations are applied, but the worker has
  nothing to aggregate, so the watermark advancement column in the
  metrics table cannot be populated by this slice.

What this slice CAN measure on staging once applied:

- Raw write throughput into `rollup_business_day` from the seed
  apply itself (one-time bulk load, not steady-state).
- Index build / maintenance cost on the deterministic UPSERT key
  and the tenant-leading hot-read index.
- RLS policy plan shape under load (Tier-M `EXPLAIN` capture for the
  operator-dashboard read pattern).
- pg_cron schedule presence + NOTIFY emission cadence.

What this slice CANNOT measure today:

- Steady-state worker throughput.
- Claim contention under multi-worker leasing.
- Watermark advancement rate at production fact-volume.
- Freshness lag under sustained load.
- Late-arriving-data + bounded-rebuild p95 (Q3.5 + Q3.8).

These remain blockers on B38 closure and on cutover.0b row 8. They
clear only after a follow-up slice provides a fact-table seed (or
the post-7.58 vendor aggregator lands) and the worker is exercised
end-to-end on staging.

## Tool reference

Scaffolded harness:

- Source: `tool/rollups_load_test/synth_seed.dart`.
- Default mode: plan-only — prints the scale math, the target
  tables, the live preflight checklist, and these blockers. Writes
  no SQL; never connects to a database.
- Emit mode: `--emit-sql --output=<path>`. Refuses ≥ 1,000,000
  rows of output unless `--confirm-tier-m-scale` is also passed.
- Tuning flags: `--operators`, `--locations-per-operator`,
  `--days`, `--start-date`, `--metric-families`.

Tests:

- `test/rollups_load_test_synth_seed_test.dart` — deterministic
  small-plan output, Tier-M default math, refusal logic, no-live-
  apply-by-default guard.

## Open questions

- Final p95 / p99 thresholds per grain depend on the staging host
  spec (Azure DB Flexible Server PG 16, Canada Central; CLAUDE.md
  Proxy & API Conventions). Values are set on the first live run.
- Whether to seed all seven grains for a Tier-M test or limit to
  `rollup_business_day` (today's harness scope). Decision deferred
  to the follow-up slice that adds the fact-table seed.
- Whether the freshness-lag SLO for the cold path is 5 minutes
  (interval-aligned) or 10 minutes (one full miss tolerated). Lock
  during the first live run.
