# Phase 7.55q.3 - Benchmark Target Object Cleanup (Drift 2 + Drift 3)

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed

## Goal

Land one shared benchmark-target blended-wage seam at the active-target
boundary, then make Benchmark and Variance WTD read that same seam
instead of recomputing different values per surface.

This is the `7.55q.1` conformance-Rule-2 fix for blended wage:

> Benchmark-target metrics (CPLH, SPLH, PPA, FOH wage, BOH wage,
> blended wage, FOH labor %, BOH labor %, total labor %) must not be
> recomputed differently per surface. `ActiveTargetProfile` (derived
> from the active `TargetCycle`) is the singular benchmark-target
> object.

## Scope

- In: `ActiveTargetProfile.computeTargetBlendedWage(...)` static seam +
  `targetBlendedWage` getter; Benchmark `_BaselineTargetsCard` now
  reads the seam instead of calling its own `_targetBlendedWage`
  helper; `WeekData.theoreticalBlendedWage` now reads the same seam
  instead of deriving a separate hour-weighted number; tests proving
  the two surfaces agree; this phase doc.
- Out: Variance WTD / Full Week non-blended-wage row-source rewiring
  (`7.55q.4` owns Drift 4 + Drift 5).
- Out: History `WeekRecord` / `week_detail_screen` cleanup
  (`7.55q.5` owns Drift 6 + Drift 7).
- Out: Schedule plan authority cleanup (`7.55q.2` already owns
  Drift 1).
- Out: Closed Full Week / closed-shift-detail blended-wage behaviour
  — that is the locked-historical-truth Rule 4 exception.

## Runtime seam

Before (drift):

```
Benchmark _BaselineTargetsCard
   │
   v
_targetBlendedWage(fohWage, bohWage,
                   targetCPLH, targetPPA, targetSPLH)  ← LOCAL helper
   │
   ├── modelFohHours(BaselineData.historicalWeeklyAvgCovers, CPLH)
   └── modelBohHoursFromSales(historicalWeeklyAvgCovers × PPA, SPLH)
   │
   v
(fohHours × fohWage + bohHours × bohWage) / totalHours

Variance WTD WeekData.theoreticalBlendedWage          ← LOCAL getter
   │
   ├── targetFohHoursWtd  (then: plan hours WTD when present, else model)
   └── targetBohHoursWtd  (then: plan hours WTD when present, else model)
   │
   v
(theoFoh × _targetFohWage + theoBoh × _targetBohWage) / totalHours

→ TWO different hour bases ⇒ TWO different "target blended wage"
  numbers for the same active target state.
```

Later q-lane follow-up work removed the WTD model-hour fallback entirely,
so the "else model" note above is the pre-fix drift anatomy that motivated
the shared seam, not the current runtime contract.

After (`7.55q.3`):

```
ActiveTargetProfile.computeTargetBlendedWage(
  targetCPLH, targetSPLH, targetPPA, fohWage, bohWage,
)                                                     ← SHARED seam
   │
   v
canonical formula:
    fohHourBasis = 1 / targetCPLH
    bohHourBasis = targetPPA / targetSPLH
    (fohHourBasis × fohWage + bohHourBasis × bohWage)
        / (fohHourBasis + bohHourBasis)
   │
   v  (cover count cancels — pure function of the rate inputs)
ONE benchmark-target blended wage per active target state.

Benchmark _BaselineTargetsCard
   │
   v
profile?.targetBlendedWage  ← reads the shared seam

Variance WTD WeekData.theoreticalBlendedWage
   │
   v
ActiveTargetProfile.computeTargetBlendedWage(...)  ← reads the same seam,
                                                     using WeekData's
                                                     injected target
                                                     fields (which come
                                                     from the active
                                                     profile via
                                                     ShiftService)
```

For the same active target state, Benchmark and WTD now produce the
identical blended-wage number. No per-surface drift.

## Why the canonical formula is cover-independent

The "model-hour" derivation of blended wage is

```
fohHours = covers / CPLH
bohHours = covers × PPA / SPLH
result = (fohHours × fohWage + bohHours × bohWage) / (fohHours + bohHours)
```

Substituting and factoring out `covers`:

```
result = covers × (fohWage / CPLH + PPA × bohWage / SPLH)
       ÷ covers × (1 / CPLH + PPA / SPLH)
       = (fohWage / CPLH + PPA × bohWage / SPLH)
       ÷ (1 / CPLH + PPA / SPLH)
```

`covers` cancels exactly. The blended wage is purely a function of
`CPLH`, `SPLH`, `PPA`, `fohWage`, and `bohWage` — exactly the rate
inputs already on `ActiveTargetProfile`. No demand-context coupling is
needed.

The new `computeTargetBlendedWage(...)` evaluates the cover-independent
form directly and returns `0.0` when `targetCPLH <= 0` or
`targetSPLH <= 0` (avoids divide-by-zero / NaN at honest "no targets
yet" boundaries).

## Closed-truth exception preserved

The Rule 4 closed exception stays untouched:

| Surface | Blended wage source | Touched in `7.55q.3`? |
|---|---|---|
| Benchmark `_BaselineTargetsCard` | `profile.targetBlendedWage` (new shared seam) | yes — reads the seam |
| Variance WTD `WeekData.theoreticalBlendedWage` | `ActiveTargetProfile.computeTargetBlendedWage(...)` (new shared seam) | yes — reads the seam |
| Variance Full Week — open / projected (`_ProjectedShiftDetail`) | `shift.snapshotBlendedWage ?? shift.blendedWage` from `ShiftRecord` | no — `7.55q.4` |
| Variance Full Week — closed (`_ClosedShiftDetail`) | `s.modelFohHours × s.lockedFohWage + s.modelBohHours × s.lockedBohWage` from per-shift locked snapshot | **no — Rule 4 closed-truth exception** |
| History `week_detail_screen` `targetBlendedWage` | unweighted `(storedTargetFohWage + storedTargetBohWage) / 2` | no — Drift 7 belongs to `7.55q.5` |
| Shift `ShiftDashboardReadModel` | profile-derived inputs (already shared) | no — already conformant |

## Files touched

| File | Change |
|---|---|
| `lib/domain/models/active_target_profile.dart` | Added `static double computeTargetBlendedWage({required double targetCPLH, required double targetSPLH, required double targetPPA, required double fohWage, required double bohWage})` — the canonical cover-independent formula with safe zero-input handling. Added `double get targetBlendedWage` instance getter that calls the static method with profile fields. No persistence change — it's a pure derived getter. |
| `lib/screens/baseline_tracker.dart` | `_BaselineTargetsCard.build` now resolves blended wage via `profile?.targetBlendedWage ?? ActiveTargetProfile.computeTargetBlendedWage(...)` (using `BaselineData` config-default fallbacks when the profile hasn't loaded yet). Deleted the local `_targetBlendedWage(...)` helper that derived its own hour mix from `BaselineData.historicalWeeklyAvgCovers`. |
| `lib/models/week_data.dart` | `theoreticalBlendedWage` now delegates to `ActiveTargetProfile.computeTargetBlendedWage(...)` using `WeekData`'s injected target fields. The previous plan-hour-weighted derivation is gone — WTD's blended wage is now the same number Benchmark shows. |
| `test/wtd_variance_logic_test.dart` | Updated the three pre-existing `theoreticalBlendedWage` tests to reflect the shared-seam contract: zero `totalCovers` no longer drives blended wage to zero (the seam is volume-independent); plan WTD hours no longer change blended wage; the seam matches Benchmark for the same target inputs. |
| `test/target_consistency_opz_test.dart` | Added group `D` — proves the shared-seam contract end-to-end: the static seam is cover-independent, the profile-getter wraps it, Benchmark reads the profile getter, and `WeekData.theoreticalBlendedWage` returns the same number for the same target inputs (no per-surface drift). |
| `docs/archive/phases/7_55q/phase_7_55q_3_benchmark_target_object_cleanup.md` | **New** — this doc. |

## Files intentionally untouched

| File | Why |
|---|---|
| `lib/data/shift_service.dart` | `WeekData` construction sites at lines 179 and 730 already inject target fields directly from the active profile. The shared seam is consumed inside `WeekData` from those injected fields — no change needed at the injection point. |
| `lib/data/target_cycle_service.dart` | Profile build path unchanged — the new blended-wage getter is computed from existing profile fields. No persisted column needed. |
| `lib/data/wage_standard_context_service.dart` | Same — no persisted column. |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | No additive column — blended wage is a pure derived getter. |
| `lib/screens/variance_report.dart` | Drift 5 — owned by `7.55q.4`. Closed `_ClosedShiftDetail` (Rule 4 exception) and open/projected `_ProjectedShiftDetail` both use blended-wage values from `ShiftRecord`, not from the active profile. Out of this slice's scope. |
| `lib/models/week_record.dart` | Drift 6 — owned by `7.55q.5`. |
| `lib/screens/week_detail_screen.dart` | Drift 7 — owned by `7.55q.5`. |
| `lib/screens/schedule_builder.dart` | Drift 1 — already landed in `7.55q.2`. |
| Tracker markdown files | Per prompt, no tracker updates in this run. |

## Remaining gaps (handed off to later slices)

- **`7.55q.4`** — Variance WTD non-closed and Variance Full Week open
  / projected rows must read benchmark targets from the current
  `ActiveTargetProfile` (Drift 4 + Drift 5). After `7.55q.3`,
  `WeekData.theoreticalBlendedWage` already reads from the profile
  via the shared seam, so the WTD blended-wage piece of `7.55q.4` is
  pre-paid — `7.55q.4` will own the snapshot-cycle vs current-cycle
  tension for CPLH / SPLH / PPA and the open/projected `ShiftRecord`
  read-source rewiring.
- **`7.55q.5`** — History `WeekRecord` / `week_detail_screen`
  conformance: stop re-modeling target hours from actuals (Drift 6),
  stop the unweighted `(FOH + BOH) / 2` blended-wage average (Drift
  7). When that lands, it should also adopt
  `ActiveTargetProfile.computeTargetBlendedWage(...)` for the
  current-cycle teaching context, while preserving locked closed truth
  for closed weeks.
- **Persisting blended wage** — not needed today. The seam is a pure
  derived getter; persistence would only matter if we wanted to lock
  the blended wage at TargetCycle creation time independent of the
  CPLH/SPLH/PPA fields. That's a `7.55l`-scope concern, not this
  slice's.
- **Blended wage in `WeeklyPlanSnapshot`** — `WeeklyPlanSnapshot`
  already carries its own `targetBlendedWage` field (locked at
  snapshot time, used by Schedule / Variance Full Week). That field
  represents the locked-week truth at snapshot creation and is not
  affected by this slice — the new seam is for the CURRENT-cycle
  Benchmark / WTD reading, not historical/locked weeks.
