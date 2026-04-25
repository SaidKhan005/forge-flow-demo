# Phase 7.55q.7 - Shift Whole-Day Target Alignment

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed

## Goal

Make the whole-day Shift surface read Benchmark-owned and Plan-owned
target metrics 1:1 wherever that is honest at whole-day scope, and
remove the remaining planned-labor / blended-wage / live-plan drift from
Shift.

## Scope

- In: strict locked-plan read on the Shift screen path; whole-day target
  labor sourced from `ActiveTargetProfile.theoreticalLaborPct`; whole-day
  target blended wage sourced from `ActiveTargetProfile.targetBlendedWage`;
  focused Shift tests; this doc.
- Out: daypart-live Shift behavior, service-period-live teaching, and
  driver-card semantics (`10.5` still owns those).
- Out: new same-scope day/daypart theoretical math. Shift remains
  whole-day in this slice.

## Runtime seam

### Benchmark-owned whole-day targets

These now read the current `ActiveTargetProfile` 1:1:

- `targetPPA`
- `targetCPLH`
- `targetSPLH`
- FOH / BOH wages
- OPZ floor / ceiling
- target blended wage via `profile.targetBlendedWage`
- target labor % via `profile.theoreticalLaborPct`

### Plan-owned whole-day targets

These now read the existing locked weekly plan day row 1:1:

- forecast covers
- forecast sales
- plan FOH hours
- plan BOH hours

### Actual/current-state reads

These remain whole-day current-state truth from closed + open snapshots:

- actual covers / sales
- actual FOH / BOH hours
- actual labor dollars / labor %
- actual blended wage
- current productivity metrics

## What changed

Before this alignment:

- Shift could silently fall back from the locked current-week plan to a
  live-resolved plan.
- Shift target labor % was still planned-labor-style math.
- Shift target blended wage was still recomputed locally from the day's
  plan-hour mix.

After `7.55q.7`:

- [shift_dashboard_notifier.dart](/C:/Git%20Local%20Repos/forge_flow_demo/lib/data/shift_dashboard_notifier.dart)
  reads the existing locked weekly plan only via
  `getExistingCurrentLockedWeeklyPlan()`. If the plan is missing, the
  whole-day Shift read model degrades honestly to unavailable.
- [shift_dashboard_read_model.dart](/C:/Git%20Local%20Repos/forge_flow_demo/lib/models/shift_dashboard_read_model.dart)
  now sources:
  - `targetLaborPct` from `profile.theoreticalLaborPct`
  - target blended wage from `profile.targetBlendedWage`
- [shift_dashboard.dart](/C:/Git%20Local%20Repos/forge_flow_demo/lib/screens/shift_dashboard.dart)
  now teaches theoretical target labor instead of planned labor.

## Honest degradation

- No locked current-week plan:
  - Shift does **not** fabricate whole-day plan values from the live plan
    path.
  - The whole-day read model stays unavailable.
- No daypart/live-theoretical truth:
  - this slice does **not** invent it.
  - `10.5` still owns that future behavior.

## Files landed with this slice

| File | Landed behavior |
|---|---|
| `lib/data/shift_dashboard_notifier.dart` | locked current-week plan read tightened to `getExistingCurrentLockedWeeklyPlan()`; honest null when no locked day row exists |
| `lib/models/shift_dashboard_read_model.dart` | target labor repointed to `profile.theoreticalLaborPct`; target blended wage repointed to `profile.targetBlendedWage`; planned-labor-derived target dollars removed |
| `lib/screens/shift_dashboard.dart` | labor target line now teaches theoretical target truth from the read model |
| `test/shift_dashboard_notifier_test.dart` | covers missing-plan honest degradation on the Shift screen path |
| `test/shift_visual_widget_test.dart` | proves the Shift labor card renders the theoretical target value |
| `test/shift_whole_day_alignment_test.dart` | proves plan-owned rows remain straight reads and the target blended wage / labor target come from the benchmark seam |

## Remaining gaps

- `10.5` still owns:
  - daypart-live Shift behavior
  - live service-period awareness
  - driver-card teaching behavior
- Phase 8 / connector work still owns richer actual labor-dollar truth when
  vendors provide it directly.
- This slice is whole-day only by design.
