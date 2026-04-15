# Phase 7.55q.1 - Architecture Conformance Contract + Drift Codification

Updated: 2026-04-14
Owner: Claude contract / audit
Status: Landed (contract/audit only — no code changes)

## Goal

Codify the architecture-conformance rule set that now governs the app
and ground a repo-grounded drift audit against it so the next four
cleanup slices (`7.55q.2` through `7.55q.5`) can be implementation
work instead of more debate.

## Scope

- In: codified surface definitions + five conformance rules; surface
  ↔ source-of-truth matrix; metric ↔ owner matrix; drift findings with
  file/line citations; classification of each drift into `7.55q.2` /
  `7.55q.3` / `7.55q.4` / `7.55q.5` / `later compatibility debt`;
  implementation handoff for the next four prompts
- Out: code changes (none in this slice)
- Out: tracker markdown updates
- Out: rewriting `7.55p.5c` / `7.55p.5d` / `7.55p.5i` — those contracts
  remain in force; this doc adds the harder-edged conformance lens on
  top

## Conformance question

> Does each surface in the app read its target / plan / blended-wage
> truth from one shared object — or does each surface still derive its
> own number? And which deviations are deliberate (closed historical
> truth) vs unfinished work?

## Architecture authority — codified

The product surfaces are:

| Surface | Definition (repo language) |
|---|---|
| **Benchmark** | Set the standard — the target authority read through `ActiveTargetProfile`. Owns CPLH / SPLH / PPA / wages / OPZ / theoretical labor %. Cycle-backed geometry remains canonical; wages may also come from the sanctioned wage-authority seam (integration-first, admin-configured fallback in Settings). |
| **Plan** | Decide the week — the locked weekly comparison plan (`WeeklyPlanSnapshot`). Owns forecast covers / forecast sales / required FOH / BOH hours / day allocation. |
| **Shift** | Manage right now — the live operational surface (`ShiftDashboardReadModel`). Reads benchmark + plan; never invents a target. |
| **Variance** | Compare plan vs actual — `WeekData` (WTD) + `VarianceWeekProjection` (Full Week). |
| **History** | Preserve what closed — `WeekRecord` + `ShiftRecord` carrying locked-at-close truth. Does not re-grade old weeks. |
| **Learn** | Teach from repeated closed results — repeated-pattern surface over closed history, never live or projected. |

### Five conformance rules (the hard edges)

These rules govern **how** the surfaces above must read their target
and plan truth. They are stricter than the existing
`docs/contracts/phase_7_55_*.md` companion docs because they specify
runtime singletons.

1. **One locked weekly plan object for the in-force week.**
   The app must not carry a second competing current-week live plan
   authority. `WeeklyPlanSnapshot` (and its `SchedulePlan` projection
   via `WeeklyPlanSnapshotSchedulePlanProjector`) is the singular
   in-force week truth.

2. **One shared benchmark target object for non-volume targets.**
   Benchmark-target metrics (CPLH, SPLH, PPA, FOH wage, BOH wage,
   blended wage, FOH labor %, BOH labor %, total labor %) must not be
   recomputed differently per surface. `ActiveTargetProfile` is the
   singular benchmark-target object. Its core geometry is cycle-backed;
   its wage fields may also be refreshed from the sanctioned
   wage-authority seam (labor integration when available, otherwise the
   admin-configured wage mix fallback in Settings).

3. **Non-closed Variance rows read shared objects 1:1.**
   Variance WTD and Variance Full Week open / projected rows must
   linearly read:
   - **Benchmark target object** owns: blended wage, PPA, CPLH, SPLH,
     FOH labor %, BOH labor %, total labor %.
   - **Plan object** owns: covers, FOH hours, BOH hours.

   Surfaces must not derive their own version of any of these for
   non-closed rows.

4. **Closed Full Week rows stay locked historical truth.**
   Closed `ShiftRecord` rows in the Full Week table compare against
   the per-shift locked target snapshot they carried at close
   (`lockedTargetCPLH/PPA/SPLH/FohWage/BohWage` etc.). This is the
   explicit exception — closed truth is locked truth and does not
   re-read the current shared benchmark/plan objects.

5. **History preserves locked week context / closed truth.**
   History (`WeekRecord` + `week_detail_screen`) must not re-model
   week targets from actuals and must not teach a fake blended-wage
   metric. Stored locked target fields and stored closed totals are
   the only inputs.

## Source-of-truth matrix — what each surface should own

| Surface | Should read benchmark targets from | Should read plan/volume from | Closed actuals |
|---|---|---|---|
| Benchmark (`baseline_tracker.dart`) | `ActiveTargetProfile` (already wired per `7.55p.5a`/`5g`) | n/a — Benchmark is calibration, not plan | n/a |
| Plan / Schedule (`schedule_builder.dart`) | `ActiveTargetProfile` | `WeeklyPlanSnapshot` via `SchedulePlanReadService.getCurrentLockedWeeklyPlan()` | n/a |
| Shift (`ShiftDashboardReadModel.buildWholeDay`) | `ActiveTargetProfile` | `WeeklyPlanSnapshot` (already wired) | live `OpenShiftSnapshot` |
| Variance WTD non-closed (`WeekData`) | `ActiveTargetProfile` (current-cycle truth) | `WeeklyPlanSnapshot.dayRows` for plan hours/sales WTD | aggregated closed `ShiftRecord`s |
| Variance Full Week — open / projected rows | `ActiveTargetProfile` (current-cycle truth) | `WeeklyPlanSnapshot` day/daypart allocation | n/a (not closed yet) |
| Variance Full Week — closed rows | `ShiftRecord.locked*` (Rule 4 exception) | `ShiftRecord` locked plan fields | `ShiftRecord` actuals |
| History week detail (`WeekRecord` + `week_detail_screen.dart`) | `WeekRecord.target*` stored locked fields (Rule 5) | `WeekRecord` stored aggregate totals | `WeekRecord` stored aggregate totals |
| Learn | `ActiveTargetProfile` for current benchmark context; `WeekRecord`/`ShiftRecord` provenance for historical evidence | n/a | aggregated closed `ShiftRecord`s |

## Metric ↔ owner matrix

| Metric | Benchmark / Plan / Closed-truth ownership | Notes |
|---|---|---|
| Covers | **Plan** (`WeeklyPlanSnapshot.forecastCovers/dayRows.forecastCovers`) for non-closed; closed truth for closed | Volume, not benchmark target |
| Forecast sales | **Plan** for non-closed; closed truth for closed | Volume |
| FOH hours | **Plan** for non-closed (`requiredFohHours`); closed actuals for closed | Plan owns the requirement; actuals own the result |
| BOH hours | **Plan** for non-closed (`requiredBohHours`); closed actuals for closed | Same |
| PPA | **Benchmark** (`ActiveTargetProfile.targetPPA`) for non-closed; closed locked PPA for closed | Target rate |
| CPLH | **Benchmark** (`ActiveTargetProfile.targetCPLH`) for non-closed; closed locked CPLH for closed | Target rate |
| SPLH | **Benchmark** (`ActiveTargetProfile.targetSPLH`) for non-closed; closed locked SPLH for closed | Target rate |
| Blended wage | **Benchmark** — single derivation through one shared seam from `ActiveTargetProfile.fohWage/bohWage` (formula correctness already verified per `7.55p.5e`) for non-closed; closed locked wages × locked hour mix for closed | Per `7.55p.5e` the formula is right but the per-surface re-derivation is structurally the source of drift |
| FOH labor % | **Benchmark** (`ActiveTargetProfile.theoreticalFohLaborPct`) for non-closed; closed locked theoretical FOH % for closed | Same |
| BOH labor % | **Benchmark** (`ActiveTargetProfile.theoreticalBohLaborPct`) for non-closed; closed locked theoretical BOH % for closed | Same |
| Total labor % | **Benchmark** (`ActiveTargetProfile.theoreticalLaborPct`) for non-closed; closed locked theoretical total % for closed | Same |

Volume metrics belong to **Plan**. Rate metrics belong to **Benchmark**.
Non-closed rows must read both objects 1:1; closed rows read the
locked snapshot fields they carried at close.

## Drift findings — repo-grounded

Each finding cites the file + line ranges where the drift lives and
classifies the next-slice owner.

### Drift 1 — Second live current-week plan authority

**File:** `lib/screens/schedule_builder.dart`
**Lines:** notifier construction at lines 40–82; `_rebuildPlan` at
156–166; `updateDemandCovers` at 132–153; `updateTargets` at 117–125
**Authority used:** `SchedulePlanReadService.resolveFromInputs(...)`
(the **live-resolved** path, not the locked path)

The Schedule Builder's `ScheduleForecastNotifier` always builds and
rebuilds via the live path
(`SchedulePlanReadService.resolveFromInputs`). The locked path
(`getCurrentLockedWeeklyPlan` at `lib/data/schedule_plan_read_service.dart:82`)
exists and is consumed by Shift / Audit, but Schedule Builder bypasses
it. So the Schedule surface presents a second competing live plan
authority for the in-force week.

This is internally consistent (the SchedulePlan math is correct) but
**violates conformance rule 1**.

**Classification:** `must fix in 7.55q.2`.

### Drift 2 — Benchmark blended-wage recomputation

**File:** `lib/screens/baseline_tracker.dart`
**Lines:** `_targetBlendedWage(...)` helper at 597–620; called from
`_BaselineTargetsCard.build` around 480–485

Benchmark recomputes its blended wage locally as
`(modelFohHours × fohWage + modelBohHours × bohWage) / totalModelHours`
where the model hours are derived from
`BaselineData.historicalWeeklyAvgCovers × targetCPLH / targetPPA /
targetSPLH`. The numerator wages come from the profile (per
`7.55p.5a`), but the hour basis is Benchmark's own derivation.

`7.55p.5e` already verified the **formula** is correct. The drift here
is structural: the blended wage is computed inside the widget seam
instead of from a single shared seam, so any future drift in either
input quietly diverges from Variance / Shift.

**Classification:** `must fix in 7.55q.3`.

### Drift 3 — WTD blended-wage recomputation

**File:** `lib/models/week_data.dart`
**Lines:** `theoreticalBlendedWage` getter at 194–200 (and
`avgBlendedWage` at 102–105 for the actual side)

WTD's `theoreticalBlendedWage` recomputes
`(targetFohHoursWtd × _targetFohWage + targetBohHoursWtd ×
_targetBohWage) / totalHours`. The hour basis is plan hours WTD when
available (line 134-135), model hours otherwise. So WTD blended wage
uses a different hour basis than Benchmark blended wage and produces a
different number for the same week.

Per Rule 2 the blended wage must come from one shared benchmark
seam. The current per-surface getter is the structural drift.

**Classification:** `must fix in 7.55q.3`.

### Drift 4 — WTD snapshot-cycle target drift vs shared benchmark object

**File:** `lib/data/shift_service.dart`
**Lines:** `_buildLockedWeekToDate` at 557–759, especially line 564
`final profile = TargetCycleActiveTargetProfileProjector.project(cycle)`
and the `targetCPLH/SPLH/PPA/FohWage/BohWage` injection at lines
750–757

When the locked weekly snapshot's `targetCycleId` points at an older
cycle than the currently active cycle, `_buildLockedWeekToDate`
projects targets from the **snapshot's** cycle, not the current shared
benchmark object. So Variance WTD shows snapshot-cycle CPLH while
Benchmark shows current-cycle CPLH.

This is **internally consistent with the existing time-boundary
contract Rule E** ("weekly plan stays stable even if the target cycle
refreshes") for closed truth. But the conformance rule the user is
codifying says non-closed Variance rows read from the shared benchmark
object 1:1. For the in-force week's still-running portion, Rule 3 wins
and the snapshot-cycle drift breaks linearity with Benchmark.

**Classification:** `must fix in 7.55q.4`. The fix should preserve
Rule 4 (closed shifts stay locked to their per-shift cycle snapshot)
while making non-closed WTD comparisons read the current
`ActiveTargetProfile`.

### Drift 5 — Full Week open/projected mixed target authorities

**File:** `lib/screens/variance_report.dart`
**Lines:** `_ProjectedShiftDetail` at 1103–1293

Open and projected Full Week rows render their cells from
`shift.forecastCovers`, `shift.fohHours`, `shift.bohHours`,
`shift.snapshotBlendedWage ?? shift.blendedWage`, and
`shift.theoreticalLaborPct` — all from the persisted `ShiftRecord`,
which captured the locked cycle in force when the row was generated.
That diverges from the current benchmark + plan objects when targets
or the weekly snapshot have changed since.

Same architectural tension as Drift 4. Open/projected is **not
closed**, so Rule 3 says these rows should read the shared objects.

**Classification:** `must fix in 7.55q.4`.

### Drift 6 — History week target-hour regeneration from actuals

**File:** `lib/models/week_record.dart`
**Lines:** `targetFohHours` at 109–110, `targetBohHours` at 111–112

```dart
int get targetFohHours =>
    LaborModel.modelFohHours(totalCovers, storedTargetCPLH);
int get targetBohHours =>
    LaborModel.modelBohHours(totalCovers, avgPPA, storedTargetSPLH);
```

These getters re-model "target" hours from the post-close
`totalCovers` and `avgPPA` — i.e. they recompute what the target hours
"should have been given what actually happened", not the hours the
locked plan actually targeted. The week's locked plan hours
(`requiredFohHours/requiredBohHours` from the snapshot in force at the
time) are not preserved on `WeekRecord` and therefore not used here.

Per Rule 5 History must preserve closed truth without re-modeling.
Today the displayed week-level "target FOH / BOH hours" are an
actuals-anchored derivation. **Internally consistent** (the formula is
clean) but **violates the conformance contract**.

**Classification:** `must fix in 7.55q.5`. Fix likely needs the
weekly plan hours to be locked into `WeekRecord` at close time.

### Drift 7 — History blended-wage simple average

**File:** `lib/screens/week_detail_screen.dart`
**Lines:** 147–150

```dart
final actualBlendedWage = (week.blendedFohWage + week.blendedBohWage) / 2;
final targetBlendedWage =
    (week.storedTargetFohWage + week.storedTargetBohWage) / 2;
final wageVar = actualBlendedWage - targetBlendedWage;
```

Both the "actual blended wage" and the "target blended wage" rendered
on the History week detail are unweighted means of the FOH and BOH
wages — the disallowed averaging shortcut. The honest blended wage
(per `7.55p.5e` Jim Taylor Ch. 1) is
`(FOH hours × FOH wage + BOH hours × BOH wage) / total hours`, not
`(FOH wage + BOH wage) / 2`.

This is genuinely incorrect math for the metric being shown, not just
a structural drift. Rule 5 explicitly forbids "fake blended wage
metric".

**Classification:** `must fix in 7.55q.5`.

## Drift triage at a glance

| # | Drift | File | Conformance rule | Classification |
|---|---|---|---|---|
| 1 | Second current-week live plan authority | `schedule_builder.dart` | Rule 1 | `7.55q.2` |
| 2 | Benchmark blended-wage local derivation | `baseline_tracker.dart` | Rule 2 | `7.55q.3` |
| 3 | WTD blended-wage local derivation | `week_data.dart` | Rule 2 | `7.55q.3` |
| 4 | WTD snapshot-cycle vs current benchmark | `shift_service.dart` | Rule 3 | `7.55q.4` |
| 5 | Full Week open/projected mixed authorities | `variance_report.dart` | Rule 3 | `7.55q.4` |
| 6 | History week target-hour regeneration | `week_record.dart` | Rule 5 | `7.55q.5` |
| 7 | History blended-wage simple average | `week_detail_screen.dart` | Rule 5 | `7.55q.5` |

### Closed truth preserved (the Rule 4 exception)

The `_ClosedShiftDetail` block in `variance_report.dart` (lines
936–1099) reads everything from `s.lockedTargetCPLH/PPA/SPLH/FohWage/
BohWage/TheoreticalFohLaborPct/TheoreticalBohLaborPct` and computes
the closed-shift blended wage from `s.modelFohHours × lockedFohWage +
s.modelBohHours × lockedBohWage`. That is locked closed truth and is
**conformant**. Do not change it in `7.55q.2`-`5`.

`ShiftRecord` carries the per-shift locked target snapshot; closed
historical comparison reads from those locked fields instead of the
current shared objects. That is the architecture's explicit exception
to Rules 2 and 3 and stays as-is.

## Implementation handoff for the next four prompts

Each subsequent slice should be narrow and concrete. Drift IDs from
the table above are the canonical scoping anchor.

### `7.55q.2` — Plan authority cleanup

**Owns:** Drift 1.

**Concrete asks:**
- `ScheduleForecastNotifier` (and the Schedule Builder widgets that
  consume it) must read the in-force week's plan from the locked
  `WeeklyPlanSnapshot` via `SchedulePlanReadService.getCurrentLockedWeeklyPlan()`.
- The live `resolveFromInputs` path remains valid for the
  preview-from-draft-targets flow (Manager Override preview), but
  must not be the default current-week authority for the running app.
- Keep `7.55p.5j` planned-package wiring intact: the planned package
  reads from whichever `SchedulePlan` projection is current.

**Out of scope:** Variance / Benchmark / History changes;
recommendation engine; Shift redesign.

### `7.55q.3` — Benchmark target object cleanup

**Owns:** Drift 2 + Drift 3.

**Concrete asks:**
- One shared seam exposes the cycle-locked blended wage at the
  `ActiveTargetProfile` boundary (read or computed once, surfaced as
  a single getter / read-model field).
- `_BaselineTargetsCard` reads that seam instead of calling its own
  `_targetBlendedWage` helper.
- `WeekData.theoreticalBlendedWage` reads that same seam (or is
  removed in favor of the seam) so WTD shows the same number as
  Benchmark for the current cycle.
- Closed-shift blended wage in `_ClosedShiftDetail` keeps reading
  locked closed truth (Rule 4 — do not unify it across the closed
  exception).

**Out of scope:** Plan authority cleanup (Drift 1 belongs to
`7.55q.2`); Variance row wiring (Drift 4/5 belong to `7.55q.4`);
History cleanup (Drift 6/7 belong to `7.55q.5`).

### `7.55q.4` — Variance linearity rewiring

**Owns:** Drift 4 + Drift 5.

**Concrete asks:**
- Variance WTD non-closed comparisons read benchmark targets from the
  **current** `ActiveTargetProfile`, not the snapshot-projected old
  cycle. The plan-side fields (forecast covers, plan hours WTD)
  continue to come from the locked `WeeklyPlanSnapshot`.
- Variance Full Week open and projected rows read benchmark targets
  from the current `ActiveTargetProfile` and plan/volume from the
  current `WeeklyPlanSnapshot` day/daypart allocation. Stop reading
  them from `ShiftRecord.theoreticalLaborPct/forecastCovers/etc.` for
  non-closed rows.
- Closed Full Week rows continue to read `ShiftRecord.locked*` truth
  (Rule 4 exception).
- Provenance must remain visible — the Variance UI should still
  distinguish closed / open / projected rows so a manager can see
  which are which.

**Out of scope:** Benchmark blended-wage seam (Drift 2/3 are
`7.55q.3`'s job — `7.55q.4` should consume the cleaned-up seam);
History (`7.55q.5`); Schedule (`7.55q.2`).

### `7.55q.5` — History conformance cleanup

**Owns:** Drift 6 + Drift 7.

**Concrete asks:**
- `WeekRecord` must store and surface the locked plan FOH / BOH hours
  for the week (likely an additive `requiredFohHoursLocked` /
  `requiredBohHoursLocked` field set at week-close from the
  `WeeklyPlanSnapshot` in force). The `targetFohHours` / `targetBohHours`
  getters should read those locked fields, not re-model from
  `totalCovers` × stored target rates.
- Migration path: pre-existing rows without the locked plan-hour
  fields must degrade honestly (e.g. show `—` or "legacy") rather
  than re-model from actuals. Pick the smallest honest fallback.
- `_GroupedSummaryTable` in `week_detail_screen.dart` must compute
  blended wage as the proper hour-weighted formula — using stored
  closed FOH / BOH hours for the actual side and stored locked plan
  hours for the target side — not the unweighted FOH+BOH/2 mean.
- If the necessary inputs are not on `WeekRecord` for either side,
  the row must be hidden / show `—` rather than display a misleading
  number.

**Out of scope:** Variance / Benchmark / Plan / Schedule changes;
Learn-surface changes.

## Audit honesty notes

- **Internally consistent ≠ conformant.** Drifts 1, 2, 3, 6 are each
  internally consistent in isolation but still violate the conformance
  contract because they create per-surface authorities. Drift 7 is
  not even internally consistent — the unweighted-mean blended wage
  is mathematically wrong as a "blended wage" metric.
- **No drift is currently "intentional" outside the closed exception.**
  Each of Drifts 1-7 above represents unfinished work, not a deliberate
  product choice supported by the architecture docs.
- **Drift 4 has real architecture tension.** The existing
  `target_cycle_weekly_plan_rules.md` Rule E says the locked weekly
  snapshot stays attached to the cycle in force when generated; the
  new conformance Rule 3 says non-closed Variance rows read the
  current benchmark object. The honest resolution: closed shifts in
  the snapshot keep their locked cycle (Rule 4), but non-closed
  comparisons in the same week read the current `ActiveTargetProfile`.
  `7.55q.4` should encode that resolution explicitly.
- **Closed Full Week rows stay locked** — the `_ClosedShiftDetail`
  block is conformant per Rule 4 and must not be touched by
  `7.55q.2`-`5`. `7.55q.5` History cleanup is about the week-level
  preserved truth, not closed-shift cycle drift.

## Remaining gaps

- **Daypart-aware everything** — `Phase 10.5` still owns per-daypart
  surfaces (Shift live service-period behavior, daypart Variance
  drill-down, daypart Learn). Out of scope for `7.55q.*`.
- **Learn surface conformance** — Learn currently relies on Repeatable
  Wins / closed shift-pattern reads; partially-migrated surfaces
  (Benchmark Set / Recurring Leak / Coach Next Week) still use
  compatibility seams. `7.55q.*` does not own Learn cleanup.
- **Vendor/connector path** — Phase 8 still owns the live integration
  swap; nothing in `7.55q.*` depends on it.
- **Long-term plan-snapshot persistence of locked plan hours per
  week** — `7.55q.5` will land the additive `WeekRecord` field; a
  later slice may also want to persist the per-day plan hour split
  for historical rendering at finer granularity. Not blocking.

## What this slice did NOT do

- No code changes (intentional — this is the contract + audit slice)
- No tests written or run
- No tracker markdown updates
- No revisions to existing `7.55p.*` contracts — they remain in force
- No new product surfaces or workflows
