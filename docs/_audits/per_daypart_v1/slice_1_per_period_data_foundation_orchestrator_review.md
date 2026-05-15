# Slice 1 — Orchestrator Independent Audit

**PR:** [#767](https://github.com/SaidKhan005/forge-flow-demo/pull/767) `claude/per-daypart-slice-1-per-period-data-foundation`
**Worker self-audit:** [`slice_1_per_period_data_foundation.md`](slice_1_per_period_data_foundation.md)
**Auditor:** Main orchestrator (independent file:line verification, separate from worker)
**Date:** 2026-05-15
**Verdict:** **APPROVE — but schema-touching → parked for operator merge approval per CLAUDE.md gate.**

## Scope check

32 files. Allocation:
- 1 Postgres migration (new, additive, cutoff 202605160000)
- 1 SQLite migration step (V36) + schema + fresh-create + seed updates (4 SQLite infra files)
- 8 domain model files (extend; no field-shape breaks)
- 1 cycle write-path service (`target_cycle_service.dart`)
- 1 weekly-plan write-path service (`weekly_plan_snapshot_service.dart`)
- 1 shift service (Gap 23 carry)
- 1 Postgres writer (`postgres_shift_record_writer.dart` — mirror 5 new columns)
- 1 demo seed (`mock_integration_replay_seed.dart`)
- 2 Learn model files (Gap 39 model layer)
- 4 test files (1 extended, 3 new)
- 4 authority/runbook doc bumps (mechanical cutoff/count refresh)

Zero scope drift. No touches to Slice 2/3/4/5/6 surfaces. No touches to `tock_reservation_postgres_sink.dart` (Claude 2 Slice 7a) or `canonical_fact_to_closed_shift_input_test.dart` (Claude 2 Task D). Concurrency clean.

## Pattern B verification (file:line independent re-check)

| Lens | Worker claim | Orchestrator re-verification | Status |
|---|---|---|---|
| **RLS-Ready Schema** | `(operator_id, location_id)` leads both new indexes; 4 sanctioned wrapper functions used | `db/migrations/202605160000_per_daypart_v1_per_period_target_persistence.sql:87-93,156-162` confirmed. Index leads with `(operator_id, location_id, …)`. Policy uses `public.app_current_operator()` + `public.app_current_location()`. No bare `current_setting`. | ✓ |
| **FK shape per RLS contract** | FKs back through `(operator_id, …)` composite | Migration `:61-67,142-148` — FK to `target_cycles(operator_id, cycle_id)` + `locations(operator_id, location_id)`. Same for weekly plan child. | ✓ |
| **Additive + nullable** | All new columns nullable for backward compat | Migration `:185-200` — `daypart_*` columns + `wage_at_lock_time_json` are `add column if not exists … (no NOT NULL)`. ✓ |
| **Design Rule 1 (per-period naming)** | `daypart*` prefix on per-period fields, no whole-day reuse | `lib/domain/models/target_cycle.dart:30-46` — `TargetCycleDaypart` carries own `targetCPLH/SPLH/PPA/opzFloor/opzCeiling/coverCount`. `shift_records.daypart_target_*` columns separate from whole-day. ✓ |
| **Design Rule 2 (null not zero)** | Empty `dayparts` returned instead of `0` placeholders | `target_cycle_service.dart:474-490` (Gap 42 path) — `dayparts: const <TargetCycleDaypart>[]` when `recommendation.isInsufficient`. No sentinel zeros. ✓ |
| **Design Rule 4 (pool consistency invariant)** | Parent pool recomputed inside write path from per-period rows | `target_cycle_service.dart:514` + `:618` — `TargetCycleDaypartPool.fromDayparts(dayparts)`. Math at `lib/domain/models/target_cycle.dart:113-127` (Σ(cover×value)/Σ(cover); OPZ band = union floor/ceiling). ✓ |
| **Design Rule 5 (wages stay whole-day)** | Per-period theoretical dollars use whole-day wage × per-period hours | Migration `:128-136` comment + Postgres column shape confirms. `weekly_plan_snapshot_service.dart` per-period theoretical hooks use parent wages, not per-period wages. ✓ |
| **Design Rule 8 (wage_at_lock_time stamp)** | JSONB stamp lives on `weekly_plan_snapshots`, not on a per-period row | Migration `:170-180` — `weekly_plan_snapshots.wage_at_lock_time_json jsonb`. Comment explicitly says audit checks compare against this column, not `ActiveTargetProfile` current wages. ✓ |
| **Gap 42 fallback** | Empty per-period table + `MeridianConfig` defaults when insufficient | `target_cycle_service.dart:474-490` matches the operator-locked decision exactly. ✓ |
| **Gap 23 carry-through** | `_shiftRecordFromFact` threads timing-provenance + per-period stamps | `shift_service.dart:432-441` — `businessTimingProfileId`, `businessTimingProfileVersionId`, `servicePeriodKey`, 5× `daypartTarget*`/`daypartOpz*` fields all carried. ✓ |
| **Time Guardrails** | `TIMESTAMPTZ` on all new operator-scoped tables; `business_date DATE` denormalized | Migration `:118` + `:152` — `created_at timestamptz`, `business_date date`. No `TIMESTAMP WITHOUT TIME ZONE`. ✓ |
| **Migration drift + cutoff** | `--fix --strict-docs` + `migration_cutoff_lint` clean | Worker ran both, no failures. Cutoff bumped consistently across the 4 authority docs. ✓ |
| **Hard Promise 2 (closed truth retains stamp)** | `daypart_*` columns on `shift_records` + Postgres writer mirror | `shift_service.dart` + `postgres_shift_record_writer.dart` both write the 5 new columns. ✓ |
| **Test coverage** | 15 new tests; 70+56 existing pass | 4 test files inspected — `target_cycle_daypart_pool_test.dart` locks pool math; `target_cycle_service_test.dart` extended group locks pool-consistency invariant. Coverage matches the 5 new invariants. ✓ |

## Findings

### No blocking findings.

### Non-blocking follow-up items (filed by worker, accepted):

1. **`ActiveTargetProfile:59-62` legacy sentinel-zero divide-by-zero fallback** — out of slice scope. File a Slice 2/3 sweep that nullables whole-day theoretical % fields. Acceptable to defer.
2. **`RecommendedBenchmarkSelection.pooledRecommendedTarget*` + `unionOpz*` deprecation** — worker marked `@Deprecated`. Cleanup of callers downstream. Acceptable.
3. **`_buildDayDaypartRows` cover allocation uses `coverCount` proportion** instead of `ScheduleDistributionWeights`. Worker's note: acceptable simplification, can layer distribution-weight-driven allocation in Slice 3 without breaking write contract. Accepted.
4. **Analyzer narration update** for the Learn layer (Gap 39 model→narration plumb-through) remains a follow-up. Model layer is done; narration tail is for a downstream slice.

None of the four block merge. All four are correctly out-of-scope for Slice 1.

## Risk assessment

- **Migration reversibility:** All additive (nullable columns, new tables). Rollback = `drop table … cascade; alter table … drop column if exists …`. No data destruction.
- **Concurrency with Claude 2:** No file overlap. Verified against `tock_reservation_postgres_sink.dart` (Slice 7a — already merged in #766) and the test file in PR #768.
- **Demo reseed wipes existing demo shifts** before regenerate (Decision 4 locked). Production HP #2 retained — only the demo seed branch touches existing rows.
- **CI dark until 2026-06-01 (per `feedback_ci_dark_until_2026_06_01.md`):** Worker disclosed local `dart analyze` clean + 15 new tests + 126 existing tests passing. Acceptable per the high-risk-slice escalation pattern.

## Merge recommendation

**APPROVE.** All Pattern B claims independently re-verified. No blocking findings. No operator-decision findings.

**However: schema-touching slice → CLAUDE.md "Hard Promises" + "Authority Order" + the "Auto-merge" rule reads explicitly carve out auth-critical / RLS-touching / schema-touching / proxy-touching slices as operator-approval-required regardless of audit verdict.** Two new tables + 1 JSONB column + 5 new shift_records columns clears the schema-touching bar.

**Parked for operator merge approval. The Pattern B is clean; this is purely a gate, not a finding.**

## What unblocks on merge

Slice 1's merge unblocks Slices 2 / 3 / 4 / 5 / 6 for parallel dispatch:
- Slice 2 (Benchmark tab redesign) — needs per-period reader
- Slice 3 (Plan tab persistence wiring) — needs `weekly_plan_snapshot_day_dayparts`
- Slice 4 (Shift daypart card full parity) — needs `target_cycle_dayparts` + per-shift stamps
- Slice 5 (Variance read-seam swap) — needs per-period reader
- Slice 6 (Audit scorer extension) — needs both new child tables + pool-consistency invariant

Slice 4 → Claude 2. Slices 2/3/5/6 → Main parallel dispatch.
