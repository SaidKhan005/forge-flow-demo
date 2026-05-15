# Per-Daypart Targets V1 — Implementation Plan

Status: **Active planning**
Created: 2026-05-15
Owner: Operator (Vanessa) — output of Phase 2 walkthrough session
Authority position:

- Below `docs/contracts/core_app_architecture.md` (binds Layers 1–12)
- Below `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md` (binds cycle + weekly plan behavior; this plan amends Rules 5 + 6, see Slice 0)
- Below `docs/contracts/phase_7_55_time_boundary_contract.md` (binds time boundaries; this plan amends Rule 5 + Rule 6, see Slice 0)
- Above Slice 0 through Slice 6 worker prompts dispatched from this plan

When this plan and a contract conflict, the contract wins. When this plan and a slice prompt conflict, this plan wins.

---

## Operator decisions locked (2026-05-15)

The 4 operator decisions that gated slice dispatch are resolved.

| # | Question | Operator decision | Slice impact |
|---|---|---|---|
| Gap 42 | Fallback shape when insufficient recommendation | **Be honest.** Leave per-period child table empty when `recommendation.isInsufficient`; read layer falls back to parent whole-day pool. App is designed to get a 60-day vendor backfill on first connect, so insufficient cycles are rare in practice. | Slice 1 unblocked. |
| Gap 31 | `shift_close_authority` operator-editability | **Keep F&F-controlled.** Document as backend-only carve-out per HP #11. Close authority is per-restaurant (not per-daypart) and depends on per-vendor finalization behavior which only F&F integration testing knows correctly. | No slice change; contract amendment in Slice 0 adds the HP #11 documented carve-out. |
| Gap 36 | Legacy `covers_source_*` columns vs keyed table | **Kill the old columns.** Backfill any existing data from the three named columns into the keyed `data_accuracy_service_period_settings` table during Slice 2 demo reseed, then drop the old columns. Pre-production so no real operator data to preserve carefully. | Slice 2 extension: one-time backfill + column drop migration. |
| Gap 35 | Operator-web Benchmarks override write-seam | **Cut the operator-web override entirely.** Mobile Baseline Manager star-shift selector is the only override path. Operator-web Benchmarks screen becomes read-only (still shows current targets, but no pin-to-override button). | Slice 2 extension: remove override write path from `benchmarks_screen.dart` + `operator_web_benchmarks_gateway.dart`; drop `benchmark_overrides` table; remove `_writeReplacementCycle`'s admin-replacement path that read from this table. |

---

## Why this work exists

The recommendation engine in `lib/domain/services/recommended_benchmark_selection_service.dart` already computes per-service-period targets cleanly. It walks 60 days of closed shifts, runs Jim Taylor's CPLH / SPLH / PPA / OPZ math at the period level, and produces a target per period at lines 122–294. Then at lines 305–332 those per-period values get pooled into one whole-day cover-weighted scalar and the per-period resolution is thrown away. Only the pooled scalars get persisted to `target_cycles`. Every downstream screen reaches for the whole-day target because that's the only thing in the database.

This flattening violates Promise 3 of `core_app_architecture.md`: "Live canonical POS/labor/reservation facts must be bucketed into the effective configured service periods first… Whole Day is then a rollup from those buckets." And Layer 9: "Whole Day rolls up from service-period buckets."

The work removes the flattening so the per-period numbers the engine already computes flow through to the screens that need them. No new feature, no parallel system — restore the architecture to what it was always supposed to be.

---

## Vocabulary

- **Service period** — canonical name in code, schema, contract docs.
- **Daypart** — operator-facing label in UI copy.

Same concept. Continue the existing split: `service_period_*` in persistence, `daypart` in user-facing strings. The convention is established (`service_period_definitions_json` in `restaurant_timing_configs`, `service_period_key` on `selected_star_shift_decisions`, etc.).

---

## Architectural decisions locked

### Decision 1: Targets owned by Benchmark only

Per Layer 4 of `core_app_architecture.md`. The Weekly Plan does NOT store its own copy of any target. Plan stamps the cycle that was active at lock time via `target_profile_version_id`; reads through to that cycle for target values.

### Decision 2: Schema is child tables, not JSON blobs

The alignment audit needs to query "for this period, does this number equal that number" cleanly. Rows are queryable; blobs require unpacking.

### Decision 3: Cycle rollover gates to operator's configured week-start day (Option 2)

Replaces today's behavior where cycles refresh mid-week. Cycle length becomes 60–66 days per operator. Jim Taylor's "minimum 60 days" promise is preserved. Eliminates Plan-vs-Benchmark drift within a single week.

### Decision 4: Pre-production simplification — no dual-shape history

We're not live. The demo seeder regenerates closed shifts. New schema requires per-period target stamps on every closed shift uniformly (not nullable). Slice 1 includes a demo reseed step that wipes existing demo closed shifts and regenerates them under the new schema. The architecture's "no retroactive re-grading of closed truth" rule still lives in the contract for post-launch.

### Decision 5: Plan tab gets no target columns

Plan owns demand-derived output; Benchmark owns targets. Plan tab columns stay as: Day · Covers · Sales · FOH Hrs · BOH Hrs at both day and daypart sub-row levels. The plumbing change is purely persistence — sub-rows render locked values from the new WeeklyPlanSnapshot child rows instead of regenerated allocator output.

### Decision 6: Variance Week to Date table — Option B

No UX change. One row per closed day. Underlying compare uses period-tagged closed actuals against period-accurate targets rolled up to the day for display.

### Decision 7: Shift daypart card — full parity with whole-day card

The bottom half of the Shift screen (today a flat metric grid + Primary Driver chip) becomes a full mirror of the top half: Shift Outputs section + Shift Inputs section + FOH Productivity section, all scoped to the selected period. Same widgets, same layout, just scoped per-period numbers.

### Decision 8: Benchmark Daypart Breakdown table — swap averages for targets

Today: Daypart · Avg Covers · Avg CPLH · Avg SPLH · Avg PPA.

After: **Daypart · Avg Covers · Target CPLH · Target SPLH · Target PPA · OPZ Range**.

- AVG COVERS stays as a column (demand context the operator scans alongside targets).
- AVG CPLH / SPLH / PPA columns swap to TARGET CPLH / SPLH / PPA — same column position, header text + value source change.
- OPZ Floor and Ceiling fold into a single OPZ Range column rendered as "4.0 – 5.5".
- Plus a Whole Day rollup row (top or bottom of table) that shows the cover-weighted blend.

### Decision 9: "Targets Derived from Benchmark" card — cut

Its Target Inputs and OPZ Range groups become redundant once the daypart table has those columns. Its Wage and Theoretical Output groups can't fold into the daypart table because wages are restaurant-wide and theoretical % is whole-day-only math. Those two groups get rehomed as a slim strip below the daypart table.

### Decision 10: Strip labels — Option B, no em dash

Left half: **Operating Wage Mix** — FOH Wage, BOH Wage, Blended Wage.

Right half: **Theoretical Labor %: The Floor** — FOH %, BOH %, Total %.

Vocabulary from `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`. Jim treats wages as operational inputs (not targets); theoretical labor % is "the floor — the minimum achievable."

### Decision 11: Wages stay whole-day; theoretical % strip stays whole-day

Wages don't have a per-period variant in Jim's framework. Theoretical labor % on the strip uses whole-day wages × whole-day forecast — stays whole-day. Per-period theoretical % shows up only where it has period-specific inputs (Variance non-closed rows).

### Decision 12: History — no UX overhaul

Same card layout. After demo reseed, every closed shift carries per-period target stamps uniformly. Each row gets graded against its period's locked target. No transition period, no dual shapes, no retroactive re-grading.

### Decision 13: Learn — no UX overhaul

Pattern resolution sharpens to the period underneath. Today: "your Fridays trend high." After: "your Friday dinners run 12 points over target every week while Friday lunches are dead on." Primary driver becomes period-scoped. Dual-source rule applies: current target from current per-period benchmark; historical evidence keeps locked-at-close-time per-period stamps.

### Decision 14: Variance 2nd table (Full Week Projection) — no UX change, target seam swap

Already structurally daypart-aware. Today non-closed daypart rows pull whole-day theoretical % from the active profile and apply it uniformly. After: per-period theoretical % from the new per-period profile rows. Wages stay whole-day in the labor-dollars math; only theoretical % and required hours gain period resolution.

---

## Schema changes

### New child table: `target_cycle_dayparts`

One row per (target_cycle_id, service_period_id). Carries:

- `target_cplh DOUBLE PRECISION NOT NULL`
- `target_splh DOUBLE PRECISION NOT NULL`
- `target_ppa DOUBLE PRECISION NOT NULL`
- `opz_floor_cplh DOUBLE PRECISION NOT NULL`
- `opz_ceiling_cplh DOUBLE PRECISION NOT NULL`
- `cover_count INTEGER NOT NULL` (per-period candidate cover total at compute time, for the weighted rollup)
- Operator/location scoping columns per RLS pattern in `hardening_rls_and_repository_pattern_contract.md`
- B-tree index leading with `(operator_id, location_id, target_cycle_id)`

Parent `target_cycles` row keeps its existing whole-day scalar fields (`target_cplh`, `target_splh`, `target_ppa`, `opz_floor_cplh`, `opz_ceiling_cplh`) as a derived rollup cache. The cycle-write path inside `_writeReplacementCycle` (in `target_cycle_service.dart:217–321`) recomputes these from the per-period rows on every write.

### New child table: `weekly_plan_snapshot_day_dayparts`

One row per (snapshot_id, business_date, service_period_id). Carries:

- `forecast_covers INTEGER NOT NULL`
- `forecast_sales DOUBLE PRECISION NOT NULL`
- `required_foh_hours DOUBLE PRECISION NOT NULL`
- `required_boh_hours DOUBLE PRECISION NOT NULL`
- `theoretical_foh_dollars DOUBLE PRECISION NOT NULL`
- `theoretical_boh_dollars DOUBLE PRECISION NOT NULL`
- Operator/location scoping
- B-tree index leading with `(operator_id, location_id, snapshot_id)`

Required hours per period computed at lock time as (period forecast covers / period cycle.target_cplh) and (period forecast sales / period cycle.target_splh), using the cycle that was active at lock time. Theoretical dollars per period = required hours × wage (wages whole-day).

### New column on `weekly_plan_snapshots`: `wage_at_lock_time_json`

Stamps the wages (FOH wage, BOH wage, blended wage) that were true at lock time. Audit checks compare locked dollar values against THIS column, not against current wages.

### New per-shift columns on `shift_records` (closed-shift target stamps)

Per-period target stamp at close time so History grades each closed shift against its period's locked target. Demo reseed populates these uniformly. Production behavior is "closed truth retains the stamp from its close time" per Promise 2.

### Migration scope

- SQLite migration: new tables + columns via `tool/migration_drift_scanner.dart --fix --strict-docs` then `tool/migration_cutoff_lint.dart` (per CLAUDE.md house rule).
- Postgres migration: new tables with RLS-ready scoping + per-table policy stubs.
- Demo reseed: wipe existing demo closed shifts; regenerate via `MockReplayDataSourceProvider` so the same DAOs that production will use feed the new stamps.

---

## Cycle rollover gating (Slice 0)

Today: `TargetCyclePolicy.needsAutoRefresh(existing, businessDate)` returns true when `businessDate > existing.effectiveEnd`.

After: returns true when `businessDate > existing.effectiveEnd` AND `weekdayOf(businessDate) == operatorWeekStartDay`.

The `operatorWeekStartDay` comes from `restaurant_timing_configs.week_start_day` (existing column, already populated). When the policy returns false because today isn't the configured week-start day, the existing cycle stays active a few extra days (1–6) until the next week-start.

New cycle's `effectiveStart = businessDate` (the week-start day). `effectiveEnd = effectiveStart + 59 days`.

Cycle length range: 60–66 days per operator.

### Contract amendments

`docs/contracts/phase_7_55_time_boundary_contract.md`:

- **Rule 5 refinement**: `effectiveStart` aligns with the operator's configured `week_start_day`. `effectiveEnd = effectiveStart + 59 days` (inclusive). The current cycle remains active while `effectiveStart <= businessDate <= effectiveEnd`. When `businessDate > effectiveEnd`, the cycle is past expiry but still active until the next configured week-start day.
- **Rule 6 rewrite**: Cycle refresh aligns to the configured business-week start. A 60-day cycle boundary that lands within a week defers refresh to the next week-start day. The previous "midweek cycle refresh does not rewrite the locked week" scenario is structurally eliminated — cycles cannot refresh mid-week under the new policy.
- **Rule 7 unchanged** (weekly snapshot lock happens at business-week start).

`docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`:

- **Rule E rewrite**: Cycles refresh at the operator's configured week-start day. The "if a 60-day target cycle refreshes during a week, the new target influences the next generated week" scenario no longer happens because cycles cannot refresh mid-week. Locked weekly plans inside a single week always reference the active cycle.

`docs/contracts/core_app_architecture.md`:

- **Layer 4 refinement**: cycle effective windows align to operator's configured week-start day. Cycle length is 60–66 days per operator depending on where the 60-day boundary falls relative to the week-start.
- **Layer 8 refinement**: WeeklyPlanSnapshot's reference to "the cycle in force when that week was generated" always equals the active cycle inside that week — no cross-cycle drift within a week.

---

## CPLH override authority cascade

The override path stays the same shape it has today (`TargetCycleService.applyManagerOverrideCycle` → `_writeReplacementCycle`). What changes is per-period awareness at the input layer and pool computation at the write layer.

### Input layer (already per-period in code today)

- Operator taps "Manager Override" on the CPLH Range & Target widget at the top of the Benchmark tab.
- Pushed into `BaselineManagerScreen`. The day-detail screen (`lib/screens/baseline_manager/baseline_manager_day_detail.dart`) already groups candidate shifts by daypart with sticky headers.
- Manager picks stars per period.
- Selections persist to Postgres `selected_star_shift_decisions` with both `daypart` and `service_period_key` columns set. (Already wired today.)

### Write path (extended in Slice 1)

`_writeReplacementCycle` becomes per-period-aware:

1. Re-prime benchmark context for the 60-day window.
2. Resolve wages fresh from the wage-authority waterfall (whole-day, unchanged).
3. For each operator-configured period:
   - Read selected stars for that period (or fall back to all candidates).
   - Compute period CPLH, SPLH, PPA, OPZ floor, OPZ ceiling.
   - Persist to `target_cycle_dayparts` row for this cycle + this period.
4. Compute the whole-day pooled values as the cover-weighted sum of the per-period values:
   - `pooled_cplh = Σ(period_covers × period_cplh) / Σ(period_covers)`
   - Same for SPLH and PPA.
   - `pooled_opz_floor` and `pooled_opz_ceiling` = cover-weighted blend of period OPZ values.
5. Write the parent `target_cycles` row with pooled scalars (cache).
6. Sync the new `ActiveTargetProfile` (both per-period rows and whole-day scalar fields).
7. Persist the selection summary.

### Read seam (extended in Slice 1)

`ActiveTargetProfile` exposes:
- All existing whole-day scalar fields (CPLH, SPLH, PPA, OPZ floor, OPZ ceiling, FOH wage, BOH wage, blended wage, theoretical %s) — read these for whole-day surfaces.
- New `List<ActiveTargetProfileDaypart>` field — read these for per-period surfaces.

Per-period and whole-day fields are guaranteed consistent because both come from the same write path; the pool is computed FROM the per-period rows, not stored independently.

### Cascade after override

Every consumer reads through `ActiveTargetProfile`, so the cascade is automatic:

- **CPLH Range & Target widget** (top of Benchmark tab): reads whole-day pool — re-renders with new pooled CPLH and OPZ band.
- **Daypart Breakdown table** (middle of Benchmark tab): period rows read per-period child rows; Whole Day rollup row reads the same whole-day pool field as the widget — **1:1 by construction**.
- **Operating Wage Mix strip** (below table): reads whole-day wages — re-renders if wages were edited (independent path).
- **Theoretical Labor %: The Floor strip** (below table): recomputes from new pool + wages + forecast covers + forecast PPA — re-renders.
- **Shift screen whole-day Zone Status Card**: reads whole-day pool — re-renders new OPZ band.
- **Shift screen daypart cards** (each period): reads its period's child row — re-renders new period target, new period OPZ band.
- **Variance Full Week Projection non-closed rows**: reads per-period theoretical % from the new profile — re-renders. Wages stay whole-day in labor-dollars math.
- **WTD vs Plan**: reads from the locked WeeklyPlanSnapshot, which doesn't change mid-week. Override only affects next week's plan generation.
- **History**: rows that close after the override pick up new per-period stamps; rows that closed before keep their stamps.
- **Learn**: re-evaluates patterns against new current per-period targets; historical evidence keeps locked-at-close-time per-period stamps.

### Pool-consistency safety net

The new audit check "TargetCycle.pooled_cplh = cover-weighted Σ(period.cplh)" fires every time the cycle is read. It guards against any future code path that mutates the pool directly without going through the write path that recomputes it from periods.

---

## Per-screen UX changes summary

| Screen | UX change | Read-side change |
|---|---|---|
| Benchmark tab — CPLH Range & Target widget | None | Reads whole-day pool from new profile (same field name, value now = cover-weighted period rollup) |
| Benchmark tab — Daypart Breakdown table | Swap CPLH/SPLH/PPA averages for targets; keep Avg Covers; fold OPZ floor + ceiling into single OPZ Range column; add Whole Day rollup row; replace hardcoded `['lunch','dinner','late_night']` with timing-config resolver | Reads per-period child rows from active profile |
| Benchmark tab — Targets Derived from Benchmark card | Cut; replaced by slim strip below daypart table | Card removed |
| Benchmark tab — Operating Wage Mix + Theoretical Labor %: The Floor strip (new) | Slim strip below daypart table; Option B labels no em dash | Reads whole-day wages + recomputes theoretical % from whole-day pool |
| Plan tab — Weekly Operating Plan table | None | Sub-rows render locked values from new WeeklyPlanSnapshot child rows instead of regenerated allocator output |
| Shift tab — whole-day half | None | Reads whole-day pool from new profile |
| Shift tab — service period half | Bottom card becomes full mirror of top half: Outputs + Inputs + FOH Productivity sections, all scoped to selected period | Reads per-period child rows for targets; reads per-period child rows from WeeklyPlanSnapshot for scheduled/needed/excess hours |
| Variance tab — WTD vs Plan table (1st) | None | Daypart-accurate compare underneath; rolls up to day-level for display |
| Variance tab — Full Week Projection (2nd) | None | Non-closed rows read per-period theoretical % from new profile; wages stay whole-day in labor-dollars math |
| History tab | None | All closed shifts uniformly graded against per-period stamps after demo reseed |
| Learn tab | None | Pattern detection sharpens to period; dual-source rule applies |
| Settings — Data Alignment Audit panel | New check shapes visible; denominator grows from 76 to ~155 at 4 periods | New per-period checks added; cross-cycle drift checks removed; pool-consistency + wage-at-lock-time checks added |

---

## Design rules (binding for slice implementation)

1. **Field naming.** Don't reuse plain field names like `targetCPLH` across layers. Per-period variants on `ActiveTargetProfile`, `TargetCycle`, `WeeklyPlanSnapshot` use period-scoped naming (e.g., `daypartTargetCPLH` on per-period rows; `pooledTargetCPLH` on parent whole-day fields if disambiguation is needed; or carry as `ActiveTargetProfileDaypart.targetCPLH` so the type makes the scope obvious).
2. **Null vs zero.** Use `null` for "unavailable" or "not yet computed." Never use `0` as a sentinel — zero is a legitimate value in degenerate cycles where the actual target is zero.
3. **Allocator stops being the regenerated authority.** `DaypartPlanAllocator` (`lib/services/daypart_plan_allocator.dart:47–62`) currently regenerates per-period plan values on every render. After Slice 1, those values are persisted on `weekly_plan_snapshot_day_dayparts`. The allocator is retired or becomes a fallback for pre-locked plans only.
4. **Pool is derived inside the write path.** Whole-day pool on `target_cycles` is recomputed from `target_cycle_dayparts` rows by `_writeReplacementCycle`. No code path outside the write path is allowed to mutate the parent pool fields directly. The pool-consistency audit check guards this.
5. **Wages stay whole-day.** Don't add per-period wage columns. Per-period labor-dollar math is `(period hours) × (whole-day wage)`. Per-period theoretical % math uses per-period required hours × whole-day wage, divided by per-period forecast sales.
6. **Theoretical Labor %: The Floor strip stays whole-day.** Its math (FOH theoretical % + BOH theoretical % = total) uses whole-day inputs. Per-period theoretical % appears only where its inputs are per-period (Variance non-closed rows).
7. **Timing config resolver, not hardcodes.** The benchmark tracker read service hardcodes `['lunch','dinner','late_night']` at one call site. Replace with `ServicePeriodDefinitionResolver` reading the operator's `restaurant_timing_configs.service_period_definitions_json`. Every per-period iteration in the codebase must read the operator's actual configured periods.
8. **Wage-at-lock-time column on WeeklyPlanSnapshot.** Audit checks that compare locked dollar values against wages must compare against this column, not against `ActiveTargetProfile` current wages.

---

## Slice sequence

### Slice 0 — Cycle rollover gating + contract amendments

**Scope:** Smallest. No schema change. Single PR.

- Update `TargetCyclePolicy.needsAutoRefresh` (in `lib/services/target_cycle_policy.dart` or wherever it lives — verify in audit) to require `weekdayOf(businessDate) == operatorWeekStartDay` in addition to the existing past-effective-end check.
- Update `_createRecommendedCycle` to compute `effectiveStart = businessDate` (which is the week-start day when this fires) and `effectiveEnd = effectiveStart + 59 days`.
- Amend `phase_7_55_time_boundary_contract.md` Rule 5 + Rule 6.
- Amend `phase_7_55_target_cycle_weekly_plan_rules.md` Rule E.
- Amend `core_app_architecture.md` Layer 4 + Layer 8 paragraphs.
- Tests: cover all seven possible `week_start_day` values, plus the cross-week-boundary auto-refresh case, plus the past-effective-end-but-not-yet-week-start deferral case.

### Slice 1 — Per-period data layer foundation

**Scope:** Schema migrations + cycle-write path extension + demo reseed. Largest slice.

- SQLite migration: add `target_cycle_dayparts` table, `weekly_plan_snapshot_day_dayparts` table, `wage_at_lock_time_json` column on `weekly_plan_snapshots`, per-period stamp columns on `shift_records`.
- Postgres migration: same tables with RLS-ready scoping per `hardening_rls_and_repository_pattern_contract.md`.
- Update `_writeReplacementCycle` in `target_cycle_service.dart` to compute per-period values and persist child rows + recompute parent pool.
- Update `ActiveTargetProfile` to expose per-period rows + whole-day fields.
- Update `_syncActiveTargetProfile` to sync both layers.
- Update `RecommendedBenchmarkSelectionService` to stop pooling — emit per-period stats as the persistence target, with pool computed inside the cycle-write path.
- Demo reseed: wipe existing demo closed shifts; regenerate via `MockReplayDataSourceProvider` so closed shifts get per-period target stamps under the new schema.
- Update `WeeklyPlanSnapshotGenerator` (whatever it's called — verify in audit) to compute per-(day, period) demand-derived values at lock time and persist to the new child table.
- Run `tool/migration_drift_scanner.dart --fix --strict-docs` then `tool/migration_cutoff_lint.dart`.
- Tests: cycle-write path produces consistent pool; pool always equals cover-weighted period sum; demo reseed populates per-period stamps on closed shifts.

### Slice 2 — Benchmark tab redesign

- `DaypartTable` widget gets column swap: Daypart · Avg Covers · Target CPLH · Target SPLH · Target PPA · OPZ Range.
- Whole Day rollup row added.
- Hardcoded `['lunch','dinner','late_night']` in benchmark tracker read service replaced with timing-config resolver.
- `_BaselineTargetsCard` widget cut.
- New strip widget below daypart table: Operating Wage Mix (FOH Wage, BOH Wage, Blended Wage) + Theoretical Labor %: The Floor (FOH %, BOH %, Total %).
- Test updates: `test/baseline_override_propagation_test.dart` and `test/target_consistency_opz_test.dart` re-pointed at new surfaces.

### Slice 3 — Plan tab persistence wiring

- `ScheduleForecastNotifier.adjustedDayViews` reads sub-row values from `weekly_plan_snapshot_day_dayparts` instead of calling `DaypartPlanAllocator`.
- `DaypartPlanAllocator` retired (or kept as a fallback for snapshots that pre-date the migration if any survive demo reseed).
- No UI changes — sub-rows render the same columns from a different source.

### Slice 4 — Shift daypart card full parity

- `_DaypartScaffoldCard` in `lib/screens/shift_dashboard.dart` replaced with a card composed of:
  - Outputs section (Sales Forecast card + Labor card; Covers + Blended Wage pills)
  - Inputs section (PPA/CPLH/SPLH grid + FOH/BOH Hours columns with scheduled/needed/excess)
  - FOH Productivity section (Zone Status Card with period-scoped CPLH + OPZ band + SPLH matrix)
- Reads per-period values from new `ActiveTargetProfile` per-period rows + new `weekly_plan_snapshot_day_dayparts` for scheduled/needed.
- Period selector pattern unchanged. Whole-day half at the top unchanged.

### Slice 5 — Variance read-seam swap

- `VarianceWeekProjectionReadService._theoreticalPctForRow` reads `currentTargetProfile.daypartFor(row.daypart).theoreticalLaborPct` for non-closed rows instead of `currentTargetProfile.theoreticalLaborPct`.
- `_laborDollarsForRow` keeps whole-day blended wage (wages don't have per-period variants).
- Closed rows unchanged.
- WTD comparison gets daypart-accurate compute underneath without UI change.

### Slice 6 — Audit scorer extension

- Add per-period checks to `data_alignment_audit_read_service.dart`:
  - Per-period benchmark authority (cycle → profile per-period equality)
  - Per-period Shift runtime (Shift's period card target = profile period target)
  - Per-period Variance runtime (Variance non-closed row theoretical % = profile period theoretical %)
  - Per-period locked-plan day-row reconciliation (snapshot period required hours = period forecast / period cycle target at lock time)
  - Per-period reconciliation (period values sum to day-level value)
  - Per-period actual presence (Shift's period covers/sales/hours presence)
  - Pool-consistency check (whole-day pool = cover-weighted Σ of period values)
  - Wage-at-lock-time check (snapshot's locked dollar = wage_at_lock_time × period required hours)
- Fix structural ordering bug at `data_alignment_audit_read_service.dart:108–111` — fetch cycle independent of snapshot existence.
- Remove cross-cycle drift checks (eliminated by Option 2).

---

## Known gaps caught during planning (mapped to resolving slice)

| # | Gap | Source | Resolved in |
|---|---|---|---|
| 1 | Recommendation pooling kludge throws away per-period stats | `recommended_benchmark_selection_service.dart:305–332` | Slice 1 |
| 2 | TargetCycle persistence is whole-day only | `target_cycle_service.dart:440–442` | Slice 1 |
| 3 | TargetCycle model has no per-period shape | `target_cycle.dart:21–28` | Slice 1 |
| 4 | ActiveTargetProfile is flat scalar | `active_target_profile.dart:7–37` | Slice 1 |
| 5 | Shift per-period read service reaches up to whole-day target | `shift_service_period_read_service.dart:370–460` (candid docstring) | Slice 4 |
| 6 | WeeklyPlanSnapshot day row has no per-period breakdown; allocator regenerates on render | `weekly_plan_snapshot.dart:17–32`; `daypart_plan_allocator.dart:47–62` | Slice 1 + Slice 3 |
| 7 | Variance read consumes whole-day profile only | `variance_week_projection_read_service.dart:51–94` | Slice 5 |
| 8 | Audit structural ordering bug — cycle only fetched if snapshot exists | `data_alignment_audit_read_service.dart:108–111` | Slice 6 |
| 9 | Mid-week cycle drift between locked Plan and current Benchmark | Contract Rule 6 (today) | Slice 0 (Option 2 eliminates this) |
| 10 | Wage-at-lock-time column missing; audit compares locked dollars to today's wages | `weekly_plan_snapshot` schema | Slice 1 + Slice 6 |
| 11 | Sentinel `0` flips audit status for degenerate cycles | `active_target_profile.dart:59–62` | Design Rule 2 — apply in Slice 1 |
| 12 | DaypartPlanAllocator regenerates plan on every render (1:1 trap) | `daypart_plan_allocator.dart:47–62` | Slice 1 (persistence) + Slice 3 (read swap) |
| 13 | benchmark_selection_summary table availability conflated with row presence | Audit gating pattern | Design rule for Slice 6 |
| 14 | Pool-vs-period directionality — future override UI editing only pool would silently break doctrine | Architectural risk | Pool-consistency check in Slice 6 |
| 15 | Hardcoded `['lunch','dinner','late_night']` in benchmark tracker read service | `benchmark_tracker_read_service.dart:101` | Slice 2 |
| 16 | `_DaypartScaffoldCard` stub — "no plan target on purpose" code comment | `shift_dashboard.dart:1236–1239` | Slice 4 |
| 17 | "Targets Derived from Benchmark" card redundant after table extension | `baseline_tracker.dart:133–141` | Slice 2 (cut + strip rehome) |
| 18 | Same field name `targetCPLH` reused across 5 types | Architecture-wide | Design Rule 1 — apply in Slice 1 |

---

## What's deferred (explicitly not in V1)

- Per-period wages. Wages stay whole-day. Not on the roadmap.
- Per-period theoretical % strip on the Benchmark tab. Stays whole-day because its formula uses whole-day inputs.
- Provenance chip on Plan tab. Not needed — Option 2 cycle gating eliminates the drift it would have explained.
- Operator-facing "Plan was locked under Cycle X" UI. Same reason.
- Re-grading old closed shifts retroactively under per-period cycles. Forbidden by Promise 2; not in scope.
- Per-operator override of cycle length (variable from the 60-day minimum). Out of scope.

---

## Operator-visible net story

When this work lands:

- Targets live in Benchmark only. Plan locks demand for one week and points at whatever cycle was active when it locked.
- Cycles roll only at the operator's configured week-start day. Within any single week every screen agrees about which cycle's standards apply.
- The whole-day view is honestly the rollup of service periods. Each daypart view is honestly its own scope, using the same visual grammar so the operator's eye doesn't have to relearn.
- The Benchmark tab's daypart table tells the truth at the period level. The Whole Day rollup row equals the CPLH the widget at the top shows.
- The Shift screen's daypart cards mirror the whole-day card fully (Outputs + Inputs + FOH Productivity) scoped to each period.
- The Plan tab's day-by-day sub-rows render locked values that don't quietly shift between when the operator locked and when they open the screen.
- The Variance Full Week Projection's variance points per non-closed row become period-accurate.
- History grades each closed shift against the period's locked target at close time.
- Learn detects patterns at period resolution: "Friday dinner: covers down" instead of "Friday: covers down."
- The data alignment audit grows from 7/76 today to roughly the same proportion passing at ~155 checks with full data, where the chain end-to-end can be proven by hard equalities.

Jim Taylor's "lunch and dinner are different businesses" insight becomes visible across every screen.

---

## Cross-references

- `docs/contracts/core_app_architecture.md` — Layers 1–12; Promises 1–3; the binding rules this plan honors.
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md` — Rules A–F; this plan amends Rule E.
- `docs/contracts/phase_7_55_time_boundary_contract.md` — Rules 1–9; this plan amends Rule 5 + Rule 6.
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — RLS-ready schema rules for the new child tables.
- `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md` — Jim's methodology; source of Operating Wage Mix and Theoretical Labor %: The Floor labels.
- `docs/contracts/metric_card_honesty_contract.md` — metric state + provenance rules for the new per-period reads.
- `docs/contracts/integration_spine_architecture_contract.md` — vendor → canonical fact → bucketer → period stamp pipeline. **NOTE:** the upstream-correctness claim previously asserted here is partial. See Audit Method results in Section "Post-audit consolidated gaps" — the canonical pipeline has serious gaps in production wiring AND in the closed-shift aggregator's bucketing semantics that this plan now folds into Slice 1.5.

---

# Post-audit consolidated gaps

This section extends the "Known gaps caught during planning" table above with findings from a three-agent surface coverage audit run 2026-05-15. Agents inventoried (a) integration plumbing end-to-end, (b) operator settings surfaces and hierarchy-scope compliance, (c) every whole-day target consumer and writer across `lib/`, `test/`, `lib/operator_web/`, `lib/admin/`, `lib/dev/`, `lib/infrastructure/`.

Gaps 1–18 are the planning-phase findings already mapped above. Gaps 19+ are the audit additions.

## Integration plumbing gaps

| # | Gap | Source | Severity | Resolved in |
|---|---|---|---|---|
| 19 | **Production wiring of `CanonicalFactPeriodResolver` + `CanonicalFactPostCommitProjector` is missing.** `tool/advisor_proxy/main.dart:1625-1629` calls `bindPhase8IntegrationsForProduction` without passing the projector/resolver/restaurant-id-resolver. `projectorWiringActive` is always false in production. No production impl of `CanonicalFactPeriodResolver` exists; only test stubs and a harness fixture. | `tool/advisor_proxy/main.dart:1625-1629`; `tool/advisor_proxy/phase_8_vendor_integration_factories.dart:327-346`; `lib/services/integration/projecting_canonical_sink.dart:50-58` | **Production cutover blocker.** Not in scope for per-daypart V1, but flagged as a precondition for any real vendor → closed-shift flow at launch. | Out of scope — separate production cutover work stream. |
| 20 | **Closed-shift aggregator bypasses `DaypartBucketer`.** `_bucketsToDaypart` reimplements bucketing inline with `[startMinutes, endMinutes)` half-open semantics. `DaypartBucketer._classifyInstant` uses `[startMinutes, endMinutes]` inclusive at end. A POS check closing exactly at 15:00:00 belongs to Lunch in live read but to "no period" in closed aggregation. Will cause Slice 6's pool-consistency audit to fire false drift. | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:922-943` vs `lib/domain/services/daypart_bucketer.dart:281-294` | **Blocker for Slice 6 honesty.** | **Slice 1.5** |
| 21 | **Closed-shift aggregator does NOT split labor punches across period boundaries.** `_readLaborPunchesForDaypart` filters by `shift_start` only — an 8-hour FOH punch crossing lunch→dinner is attributed entirely to one period. Direct Promise 3 violation. Open-shift live reads do this correctly via `DaypartBucketer.bucketLaborPunch`. | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:805-835` | **Blocker — invalidates per-period CPLH math from closed data.** | **Slice 1.5** |
| 22 | **Demo seeder writes `shift_records` without timing stamps.** `MockIntegrationReplaySeed._generateShift` doesn't populate `businessTimingProfileId`, `businessTimingProfileVersionId`, or `servicePeriodKey`. | `lib/dev/mock_integration_replay_seed.dart:326-411`; `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:882-943` | Folds into Decision 4 demo reseed. | **Slice 1** (demo reseed scope) |
| 23 | **`ShiftService.closeShift._shiftRecordFromFact` drops timing fields** when converting `ShiftFact` to SQLite. Server-side `PostgresShiftRecordWriter` preserves them; mobile-direct close-shift path strips them. Three-line fix. | `lib/services/shift_service.dart:248-350` vs `lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart:214-216` | Causes null timing keys on demo-closed-via-app rows after Slice 1. | **Slice 1** (fold into per-shift stamp work) |
| 24 | **`closeShift` hardcodes `14 shifts/week` (2 periods × 7 days)** as the gate for upserting `WeekRecord`. With 4-period schedules or weekend brunch the gate never fires. | `lib/services/shift_service.dart:294-300` | Same bug class as Gap 15 (`['lunch','dinner','late_night']` hardcode). | **Slice 1.5** (bundled with bucketing fix) |
| 25 | **Aggregator stage-4 forecast-covers fallback hardcodes `dailyShare / 3` divide-by-3.** Ignores operator-configured periods + distribution weights. Contradicts Decision 11 (timing-config-driven splits). | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:458-469` | Wrong per-period covers when POS lacks covers and forecast is the fallback. | **Slice 1.5** (bundled with bucketing fix) |
| 26 | **Cross-(business-date) labor punch split missing in aggregator.** Punch in 03:00 Tue / out 11:00 Tue with 04:00 cutoff belongs to Mon business date by its `shift_start`; the half after rollover never appears in either day's aggregate. `DaypartBucketer._businessDatesSpanning` handles this; the aggregator does not. | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:813-824` vs `lib/domain/services/daypart_bucketer.dart:300-320` | Edge case but real for late-night operations. | **Slice 1.5** (bundled with bucketing fix) |

## Operator settings surface gaps

| # | Gap | Source | Severity | Resolved in |
|---|---|---|---|---|
| 27 | **Hardcoded `enum Daypart { lunch, dinner, lateNight }` in `DataAccuracySettings` model + 4 UI iteration sites.** Operator-web `covers_source_toggle.dart:78`, `covers_manual_entry_card.dart`, `covers_historical_seed_card.dart`, and mobile `settings_covers_setup_section.dart:42-46`. Same shape as Gap 15 but in a different cluster of files the plan didn't name. | `lib/domain/models/data_accuracy_settings.dart:130-184`; UI sites enumerated above | Operator with non-default periods (e.g. 4-period config with breakfast) cannot enter manual covers or pick covers source for the 4th period. | **Slice 2** (extended scope) |
| 28 | **`ServicePeriodDraft` (operator-web editor) missing `applicableDays`, `shortLabel`, `sortOrder` fields.** Mobile read display shows these; canonical model carries them; operator-web write UI silently ignores them. Operator cannot define day-restricted periods (e.g. "Weekend Brunch Sat/Sun only"). | `lib/operator_web/widgets/service_period_editor.dart:28-62` vs `lib/domain/models/service_period_definition.dart:33-34`; mobile read at `settings_timing_authority_section.dart:43-57` | Plan assumes operator can fully configure their periods — the editor restricts what they can express. | **Slice 2.5** (new small slice) |
| 29 | **Operator-web `data_accuracy_screen.dart` has NO `HierarchyScopeNotice`.** HP #11 explicitly names "data accuracy" as a hierarchy-scoped surface. No scope chip, no "inherited from Operator default" pill anywhere on the screen. | `lib/operator_web/screens/data_accuracy_screen.dart` (full file) | HP #11 violation. | Follow-up after V1 (small dedicated slice) |
| 30 | **Mobile `settings_timing_authority_section.dart` and `settings_wage_authority_section.dart` missing scope chip.** Mobile is view-only but should still surface inheritance state per HP #11. | `lib/screens/settings/settings_timing_authority_section.dart:128-171`; `lib/screens/settings/settings_wage_authority_section.dart:115-229` | HP #11 violation (mobile). | Follow-up after V1 |
| 31 | **`shift_close_authority` not operator-editable.** Mobile is view-only; operator-web business timing editor doesn't include it; only F&F Ops admin (`lib/admin/screens/operator_location_admin_screen.dart:3719`) writes it. Architecture says operator owns timing setup. | `restaurant_timing_configs.shift_close_authority` column; admin-only write path | Architectural inconsistency. Operator decision needed: expose on operator-web, or document the backend-only carve-out per HP #11. | Operator decision required; if expose → Slice 2.5 companion; if document → contract amendment |
| 32 | **Wage Authority hardcoded to `HierarchyScopeLevel.location`** — no business-default wages. Multi-location operators type the same FOH/BOH wages N times. | `lib/operator_web/screens/wage_authority_screen.dart:484` | Inconsistent with HP #11 (wages aren't an exception). Not blocking V1. | Follow-up after V1 |
| 33 | **Hidden mobile `_WageMixEditorScreen` still in code.** `settings_screen.dart:363` passes `viewOnly: true`; ~400 lines of dead UI ships in the mobile binary. | `lib/screens/settings/settings_wage_authority_section.dart:254-663` | Code-health follow-up. | Follow-up cleanup |
| 34 | **Wage Mix UI doesn't say "applies per-period".** After Decision 11 + Decision 14, operators see a single FOH wage but Variance Full Week Projection multiplies it by per-period required hours. Without a copy hint operators may expect to set a different lunch wage. | `lib/screens/settings/settings_wage_authority_section.dart` (no copy); `lib/operator_web/screens/wage_authority_screen.dart` (no copy) | Copy-only fix. | **Slice 2** (one-line copy add) |
| 35 | **Operator-web Benchmarks override writes the pool layer directly.** `benchmarks_screen.dart` writes pooled `target_cplh/splh/ppa` scalars to `benchmark_overrides`. After Slice 1 those scalars become the derived rollup of per-period rows. An override that writes only the pool gets clobbered on the next cycle write (pool recomputed from periods). Risk flagged in plan as audit-time guard (Gap 14), but the WRITE seam itself isn't addressed. | `lib/operator_web/screens/benchmarks_screen.dart:128-184`; pool-consistency check in Slice 6 | Either make operator-web override per-period (mirror mobile Baseline Manager pattern) or add copy explaining the pool-write semantics. | **Slice 2** (decision + copy at minimum; if per-period: small extension) |
| 36 | **Legacy `covers_source_lunch/dinner/late_night` columns coexist with keyed `data_accuracy_service_period_settings`.** Reader `DataAccuracySettings.coversSourceFor(daypart)` reads only the legacy fields. No slice currently resolves precedence between the two shapes. | `lib/domain/models/data_accuracy_settings.dart:207-214`; `lib/operator_web/widgets/keyed_service_period_accuracy_card.dart:7-9` | Ambiguity for per-period work. | **Slice 2** extension or follow-up cleanup |
| 37 | **Walk-in handling per-period split missing.** Walk-in daily count is a single integer per `business_date_iso`. Walk-ins skew toward dinner; period split would improve covers attribution. | `lib/operator_web/widgets/walk_in_handling_card.dart`; `lib/domain/models/data_accuracy_settings.dart` (walk_in_handling_mode) | Out of scope V1 but worth documenting explicitly. | Out of scope (document in "What's deferred") |
| 38 | **Polling tier per-period split missing.** Tier-status surface is location-wide; lunch may demand faster cadence than late-night. | `lib/operator_web/widgets/polling_tier_status_card.dart` | Out of scope V1 (F&F Ops Console controls polling tiers). | Out of scope (document) |

## Whole-day target consumer gaps

| # | Gap | Source | Severity | Resolved in |
|---|---|---|---|---|
| 39 | **Learn pattern detection chain (`LearnBenchmarkContext` + `LearnTeachingAnalyzer` + `LearnTeachingSummary`) needs per-period inputs.** Decision 13 says "no UX overhaul" but the narration content ("Friday dinner: covers down" vs "Friday: covers down") requires per-period sourcing. No slice in the plan explicitly extends these. | `lib/services/learn_benchmark_context_service.dart:232-267`; `lib/services/learn_teaching_analyzer.dart:42-125`; `lib/models/learn_benchmark_context.dart:8-19`; `lib/models/learn_teaching_summary.dart:10-56`; `lib/screens/variance/variance_learn_tab.dart:412-420` | Decision 13 implication not yet wired. | **Slice 1** (model extension) + follow-up for analyzer narration |
| 40 | **`baseline_manager_preview.dart` needs per-period preview math.** Manager-override preview today shows whole-day numbers up to the moment of write; post-write the cycle is per-period. Operator sees inconsistent shapes during the draft → confirm flow. | `lib/screens/baseline_manager/baseline_manager_preview.dart:33-258` | UX inconsistency during override flow. | **Slice 1** (write-path extension) or **Slice 2** |
| 41 | **`schedule_builder.dart:107-113` sentinel-0 violation of Design Rule 2.** Constructs `ActiveTargetProfile` with `targetCPLH: 0, ...` "unused on locked path". Design Rule 2 forbids sentinel zeros; should switch to nullable shape or be removed entirely once Slice 3 reads from persisted snapshot rows. | `lib/screens/schedule_builder.dart:107-113` | Latent — sentinel collides with degenerate cycles where target IS zero. | **Slice 3** (cleanup) |
| 42 | **`MeridianConfig` insufficient-recommendation fallback shape undefined.** When `recommendation.isInsufficient` returns true, what gets written to `target_cycle_dayparts`? Three options: (a) widen `MeridianConfig` to per-period, (b) write all-periods-identical fallback rows, (c) leave child table empty and fall back to parent pool at read time. | `lib/domain/constants/app_defaults.dart:36-40`; `target_cycle_service.dart:411-434` | Operator decision needed before Slice 1 dispatch. Recommend (c) — simplest. | **Slice 1** (operator decision required) |
| 43 | **`wage_at_lock_time_json` writer not explicitly named in plan.** The implicit writer is `WeeklyPlanSnapshotService` (not "WeeklyPlanSnapshotGenerator"). | `lib/services/weekly_plan_snapshot_service.dart` (verify class name during slice work) | Plan ambiguity; clarify in Slice 1 prompt. | **Slice 1** (naming clarity) |
| 44 | **`BaselineData` bridge (`baseline_authority_service.dart`) must stay whole-day.** Tempting to extend with per-period accessors during Slice 1; design rule says do not. Every per-period read goes through `ActiveTargetProfile.daypartFor(...)` or `target_cycle_dayparts`, never `BaselineData`. | `lib/services/baseline_authority_service.dart` (multiple sites) | Design rule reinforcement. | **Slice 1** (design rule callout in prompt) |

---

# Slice sequence amendments (post-audit)

Original sequence: Slice 0, 1, 2, 3, 4, 5, 6. Amended sequence after audit findings:

**Slice 0** — Cycle rollover gating + contract amendments. Unchanged.

**Slice 1** — Per-period data layer foundation. Extended to include:
- `ShiftService.closeShift._shiftRecordFromFact` timing field carry-through (Gap 23)
- `WeeklyPlanSnapshotService` named explicitly as the writer (Gap 43)
- `LearnBenchmarkContext` + `LearnTeachingSummary` per-period model extension (Gap 39 model layer)
- `MeridianConfig` insufficient-recommendation fallback decision before dispatch (Gap 42)
- `BaselineData` stays-whole-day design rule explicit in prompt (Gap 44)
- Demo seeder timing-stamp population (Gap 22)

**Slice 1.5 (NEW)** — Closed-shift aggregator → DaypartBucketer routing. Must land before Slice 6 (audit) because pool-consistency checks depend on closed-shift period stamps being byte-identical to live read.
- Replace `_bucketsToDaypart` with `DaypartBucketer.bucketPosLine` / `bucketReservation` / `bucketLaborPunch` (Gap 20)
- Add per-period accumulator with labor-punch interval splitting (Gap 21 — Promise 3)
- Add cross-(business-date) split handling (Gap 26)
- Replace stage-4 forecast fallback `/3` divide with timing-config-driven allocation (Gap 25)
- Replace `14 shifts/week` hardcode in `closeShift` with operator-period-count × 7 (Gap 24)
- Tests: aggregator unit tests + fixture vendor payloads spanning boundaries

**Slice 2** — Benchmark tab redesign. Extended to include:
- Replace `Daypart` enum + 4 UI iteration sites with resolver-driven keys (Gap 27)
- Operating Wage Mix "applies per-period" copy add (Gap 34)
- `baseline_manager_preview.dart` per-period preview math (Gap 40)
- Operator-web Benchmarks override decision: per-period override OR pool-write copy (Gap 35)
- Legacy `covers_source_*` column precedence decision (Gap 36)

**Slice 2.5 (NEW)** — Service period editor field completeness. Small slice; can run parallel to Slice 2.
- `ServicePeriodDraft` gains `applicableDays`, `shortLabel`, `sortOrder` (Gap 28)
- Operator-web editor UI accepts day-restricted periods
- `business_timing_gateway` round-trips the fields

**Slice 3** — Plan tab persistence wiring. Extended:
- Clean up `schedule_builder.dart:107-113` sentinel-0 (Gap 41)

**Slice 4** — Shift daypart card full parity. Unchanged.

**Slice 5** — Variance read-seam swap. Unchanged.

**Slice 6** — Audit scorer extension. Unchanged structurally; per-period and pool-consistency checks now have honest underlying data thanks to Slice 1.5.

**Follow-ups (separate from V1):**
- Production wiring of `CanonicalFactPeriodResolver` + `CanonicalFactPostCommitProjector` (Gap 19) — production cutover precondition
- `data_accuracy_screen.dart` HierarchyScopeNotice (Gap 29)
- Mobile settings scope chips (Gap 30)
- `shift_close_authority` operator-editing OR documented carve-out (Gap 31) — operator decision
- Wage Authority business-default scope (Gap 32)
- Hidden `_WageMixEditorScreen` cleanup (Gap 33)
- Walk-in handling per-period (Gap 37) — out of scope, documented
- Polling tier per-period (Gap 38) — out of scope, documented
- Learn analyzer narration per-period (Gap 39 narration layer)

---

# Audit Method — Surface Coverage Verification

This is the procedural method used to verify nothing was missed across the per-daypart targets V1 plan. It is reusable for any future feature that touches a per-operator-configurable dimension (daypart, scope hierarchy, timing, integrations).

## Eight audit dimensions, in order

### 1. Data ownership trace

For each architectural layer (Layers 1–12 of `core_app_architecture.md`), document what data flows in/out and who owns it.

- Which layer owns the new dimension?
- Which layers consume it as input?
- Which layers persist it?
- Which layers expose it as a read seam?

For per-daypart targets V1: Targets are owned by Layer 4 (TargetCycle). Layer 5 (ActiveTargetProfile) is the read seam. Layers 7 (SchedulePlan), 8 (WeeklyPlanSnapshot), 9 (Shift), 10 (Variance), 11 (History), 12 (Learn) consume.

### 2. Persistence layer

For each table that touches the dimension:

- Does the schema support the dimension's resolution? (Whole-day vs per-period, per-(operator, location) scope, etc.)
- Are foreign keys + indexes + RLS policies in place?
- Migration path: SQLite + Postgres, both?
- Do operator-scoped fact-table B-tree indexes lead with `operator_id` (or `(operator_id, location_id)`)?
- Does the migration drift scanner pass after the schema change?

### 3. Write paths

Enumerate every code path that produces a value for the dimension. For each:

- Does it go through the canonical write path, or bypass it?
- Does it respect the operator's configured scope (timing config, hierarchy)?
- Does it produce the new resolution, or only the legacy resolution?
- Is there exactly one canonical write path that all consumers must respect?
- Does the demo seeder / replay provider write the same shape as production sinks?

Search method: grep for assignment to the dimension's field names across `lib/`, `lib/dev/`, `lib/operator_web/`, `lib/admin/`, `lib/infrastructure/`.

### 4. Read paths

Enumerate every code path that consumes the dimension. For each:

- Does it read through the canonical read seam (ActiveTargetProfile, etc.)?
- Does it expect the new resolution, or only legacy?
- Does it have a fallback for missing data? Is the fallback honest (per `metric_card_honesty_contract.md`)?
- Is there a `0`-as-sentinel violation? Should it use `null` instead?
- Does each consumer use period-scoped naming or whole-day naming?

Search method: grep for reads of the dimension's field names across all directories.

### 5. Settings + UX surfaces

For each operator-facing settings surface that affects the dimension:

- Does it respect hierarchy scope per HP #11 — show selected scope, inherited source, effective value before mutation?
- Does its UI render the resolution correctly (per-period vs whole-day)?
- Are there hardcoded enum/list values that ignore operator-configured scope (e.g. `['lunch', 'dinner', 'late_night']`)?
- Does the displayed copy match actual behavior (e.g. "applies per-period" if relevant)?
- Is the setting editable at the right hierarchy level (operator-default vs location)?
- For settings that should be operator-editable but aren't: are they documented as backend-only carve-outs?

Inventory both mobile (`lib/screens/settings/`) and operator-web (`lib/operator_web/screens/`).

### 6. Integration plumbing

For each vendor adapter + the pipeline downstream:

- Does vendor data flow through the canonical bucketer (`DaypartBucketer`) that respects operator-configured periods?
- Do labor punches get interval-split at period boundaries (Promise 3)?
- Do cross-(business-date) events get split across days?
- Do canonical facts → aggregator → ShiftFact preserve all timing fields (`servicePeriodKey`, `businessTimingProfileId`, `businessTimingProfileVersionId`)?
- Are demo seeders byte-consistent with production write paths?
- Does the closed-shift aggregator share bucketing semantics with the live-shift bucketer (same boundary inclusivity, same interval split)?
- Is the post-commit projector wired in production, or only in harness?

### 7. Hierarchy + scope rules

For each setting that affects the dimension:

- What scope does it persist at? (Business/operator default, org-unit, location)
- Does the inheritance chain work? (Business default → org-unit ancestors root-to-leaf → location)
- Is each scope expressible by the operator UI?
- Are inheritance overrides additive or replacement?
- Does the audit surface the resolved value cleanly?

### 8. Cross-cutting concerns

- **Test coverage:** enumerate test files that read/write the dimension. Group into "direct slice surface" (must change in slice PR) and "fixture-dependent" (must update because demo reseed changes shapes).
- **Audit checks:** which alignment assertions cover the dimension end-to-end? Are there missing check shapes?
- **Sync paths (Postgres ↔ SQLite):** do all dimension fields round-trip? Do they survive proxy JSON serialization?
- **Operator-facing copy:** does it explain the new dimension correctly? Are there ambiguity gaps requiring copy adds?
- **Telemetry / analytics:** do event payloads carry the new resolution?
- **Demo data:** does the seeder produce data shapes consistent with production write paths?

## Procedure for running the audit

1. **Inventory the dimension's footprint.** Grep for the dimension's field names across all source directories. Build a consumer list.
2. **Spawn three parallel research agents:**
   - Agent A — Integration plumbing (vendor → canonical fact → bucketer → fact stamp)
   - Agent B — Operator settings surfaces + hierarchy scope compliance
   - Agent C — Whole-day → per-period read/write path coverage
3. **Each agent reads the locked plan doc first** to have context, then audits its assigned dimension.
4. **Each agent reports** with file:line citations, structured into:
   - Inventory (what exists today)
   - Gaps (what's broken or missing)
   - Orphans (surfaces not covered by slices)
5. **Orchestrator consolidates** findings into a single gaps table. Each gap is mapped to either:
   - A specific slice (existing or new)
   - A documented "out of scope" / "follow-up" classification
   - A required operator decision before slice dispatch
6. **Plan doc gets updated** with the consolidated gaps and any new slice scope (e.g. Slice 1.5, 2.5).
7. **Before dispatching the first slice,** confirm every gap has a destination — either a slice number or an explicit out-of-scope tag.

## Coverage guarantees this method provides

- No data flow path silently loses the new resolution (Dimension 1 + 2 + 6).
- No consumer reads stale or legacy data after the schema lands (Dimension 4).
- No setting becomes ambiguous or unscoped after the work (Dimension 5 + 7).
- No vendor adapter or demo seeder produces inconsistent shapes (Dimension 6).
- No test silently passes because its fixture hasn't been updated (Dimension 8).
- Every gap has a documented destination (Procedure step 5).

## What this method does NOT catch

- Behavior that depends on integration runtime conditions (the audit is static).
- Race conditions in concurrent write paths (separate audit needed).
- Performance regressions from new schema/RLS overhead (separate benchmark).
- Operator workflow regressions (separate Phase 2 walkthrough).
- Production-only failure modes (separate dark-CI / canary).

Use this method for feature design coverage. Pair with runtime acceptance and operator walkthrough for full launch readiness.
