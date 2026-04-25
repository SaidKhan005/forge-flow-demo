# Phase 7.55q.4 - Variance Linearity Rewiring (Drift 4 + Drift 5)

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed (with `7.55q.4-review-fix` follow-up — see below)

## Goal

Make non-closed Variance rows read the shared Benchmark target object
and the locked weekly Plan object 1:1, row by row, value by value —
without touching the closed-truth Rule 4 exception.

## 7.55q.4-review-fix — wire profile through `_FullWeekSection`

The first pass added an optional `currentTargetProfile` parameter to
`VarianceWeekProjectionReadService.build(...)`, but the screen-side
call site at `_FullWeekSectionState.build()` was still
`_readService.build(widget.shifts)` — the parameter was never
populated in production. Group L unit tests proved the parameter
worked when supplied directly; group G widget tests proved
`_ProjectedShiftDetail` reads the profile from Provider; nothing
proved the COLLAPSED day-row aggregate path actually received the
profile end-to-end.

The review-fix:

- `_FullWeekSectionState.build()` now reads
  `context.watch<ActiveTargetProfileNotifier?>()?.profile` and passes
  it as `_readService.build(widget.shifts, currentTargetProfile:
  currentTargetProfile)`. Same Provider-based wire used by
  `_ProjectedShiftDetail` in the original `7.55q.4`, and same honest
  fallback when the notifier isn't in scope (the read service falls
  back to per-shift theoretical % — backward-compatible).
- New widget tests `G4` + `G5` in `test/variance_visual_widget_test.dart`
  prove the wire end-to-end with a deterministic
  `_ScreenWireProbeDataSource` that returns ONE all-projected day with
  zero-input shifts. That forces `totalSales = 0` in the day-row
  aggregate, which routes `laborPct` through `_meanTheoreticalPct` —
  giving a single deterministic value to assert on:
  - **G4**: with the profile in scope, the rendered day-row labor %
    equals the profile's `theoreticalLaborPct` (87.7%) — proving the
    wire delivers the profile.
  - **G5**: without the profile in scope, the rendered day-row labor
    % equals the locked shift theoretical % (33.3%) — proving the
    fallback path is honest, not silent.

This is the `7.55q.1` conformance-Rule-3 fix:

> **Non-closed Variance rows read shared objects 1:1.** Variance WTD
> and Variance Full Week open / projected rows must linearly read:
> - **Benchmark target object** owns: blended wage, PPA, CPLH, SPLH,
>   FOH labor %, BOH labor %, total labor %.
> - **Plan object** owns: covers, FOH hours, BOH hours.

## Scope

- In: `_buildLockedWeekToDate` and `_resolveProfileForFullWeek` in
  `shift_service.dart` switch from snapshot-cycle-projected profiles
  to the current `ActiveTargetProfile`. `_ProjectedShiftDetail` in
  `variance_report.dart` reads Benchmark-owned values (blended wage,
  theoretical labor %) from the current profile via Provider, with
  honest fallback when the profile hasn't loaded yet.
  `VarianceWeekProjectionReadService.build` accepts an optional
  `currentTargetProfile` and substitutes its theoretical % for
  non-closed children when computing day-row aggregates. Focused
  tests; this phase doc.
- Out: blended-wage seam design — already landed in `7.55q.3` and
  consumed here.
- Out: Schedule plan authority — already landed in `7.55q.2`.
- Out: History / `WeekRecord` / `week_detail_screen` rewiring —
  `7.55q.5` owns Drift 6 + Drift 7.
- Out: closed Full Week / `_ClosedShiftDetail` Rule 4 exception —
  preserved exactly as-is.

## Ownership matrix (codified in this slice)

| Metric | Source for non-closed rows | Source for closed rows |
|---|---|---|
| Covers | Plan — locked `WeeklyPlanSnapshot.dayRows` (WTD) / `ShiftRecord.forecastCovers` (Full Week) | Closed `ShiftRecord` actuals |
| FOH hours | Plan — `WeeklyPlanSnapshot.dayRows.requiredFohHours` (WTD) / `ShiftRecord.fohHours` from snapshot conversion (Full Week open/projected) | Closed `ShiftRecord` actuals |
| BOH hours | Plan — `WeeklyPlanSnapshot.dayRows.requiredBohHours` (WTD) / `ShiftRecord.bohHours` (Full Week open/projected) | Closed `ShiftRecord` actuals |
| PPA | **Benchmark — current `ActiveTargetProfile.targetPPA`** | `ShiftRecord.lockedTargetPPA` |
| CPLH | **Benchmark — current `ActiveTargetProfile.targetCPLH`** | `ShiftRecord.lockedTargetCPLH` |
| SPLH | **Benchmark — current `ActiveTargetProfile.targetSPLH`** | `ShiftRecord.lockedTargetSPLH` |
| FOH wage | **Benchmark — current `ActiveTargetProfile.fohWage`** | `ShiftRecord.lockedTargetFohWage` |
| BOH wage | **Benchmark — current `ActiveTargetProfile.bohWage`** | `ShiftRecord.lockedTargetBohWage` |
| Blended wage | **Benchmark — current `ActiveTargetProfile.targetBlendedWage` (the `7.55q.3` shared seam)** | Closed-truth derivation from `ShiftRecord.modelFohHours × lockedTargetFohWage + ShiftRecord.modelBohHours × lockedTargetBohWage` (in `_ClosedShiftDetail`) |
| FOH labor % | **Benchmark — current `ActiveTargetProfile.theoreticalFohLaborPct`** | `ShiftRecord.lockedTheoreticalFohLaborPct` |
| BOH labor % | **Benchmark — current `ActiveTargetProfile.theoreticalBohLaborPct`** | `ShiftRecord.lockedTheoreticalBohLaborPct` |
| Total labor % | **Benchmark — current `ActiveTargetProfile.theoreticalLaborPct`** | `ShiftRecord.theoreticalLaborPct` (locked at close) |

Bold rows changed in this slice. The closed column was already correct
per Rule 4.

## Runtime seam

Before (drift):

```
WTD non-closed (shift_service._buildLockedWeekToDate)
   │
   ├── snapshot       → Plan-owned (forecast covers, plan hours WTD) ✓
   └── snapshot.cycle → projected ActiveTargetProfile
                        ↑ Benchmark-owned target fields from OLDER cycle
                          when the active cycle has rolled but the snapshot
                          stays in force ⇒ Rule 3 violation

Full Week open/projected
   ├── shift_service._resolveProfileForFullWeek
   │      → snapshot.cycle → projected profile         ↑ same drift
   │   ↓
   │   CurrentWeekState.shiftRecordFromSnapshot
   │      → ShiftRecord with snapshot-cycle target fields
   │   ↓
   ├── _ProjectedShiftDetail widget
   │      → reads shift.snapshotBlendedWage / shift.theoreticalLaborPct
   │      → those carry snapshot-cycle truth ⇒ Rule 3 violation
   │
   └── VarianceWeekProjectionReadService._weightedTheoreticalPct
          → reads r.shift.theoreticalLaborPct
          → mixes snapshot-cycle (non-closed) and locked-truth (closed)
            with no awareness of the difference ⇒ Rule 3 violation
            for the non-closed contributors
```

After (`7.55q.4` + `7.55q.4-review-fix`):

```
WTD non-closed (shift_service._buildLockedWeekToDate)
   │
   ├── snapshot      → Plan-owned (forecast covers, plan hours WTD) ✓
   └── _loadActiveProfile(restaurantId)
       → CURRENT ActiveTargetProfile           ✓ Rule 3
       ↓
   WeekData.targetCPLH/SPLH/PPA/FohWage/BohWage,
            theoreticalFohLaborPct/BohLaborPct/LaborPct
            ← all from current profile

Full Week open/projected
   ├── shift_service._resolveProfileForFullWeek
   │      → _loadActiveProfile(restaurantId)        ✓ Rule 3
   │   ↓
   │   CurrentWeekState.shiftRecordFromSnapshot
   │      → ShiftRecord with CURRENT target fields
   │
   ├── _ProjectedShiftDetail widget (per-row expanded detail)
   │      → reads ActiveTargetProfileNotifier (Provider)
   │      → blendedWage   = profile.targetBlendedWage  (7.55q.3 seam)
   │      → theoreticalLaborPct = profile.theoreticalLaborPct
   │      → falls back to shift.* only when profile not loaded yet
   │      → covers / FOH hours / BOH hours stay from shift (Plan-owned)
   │
   └── _FullWeekSectionState.build (collapsed day-row aggregate)
          ↑ 7.55q.4-review-fix: now reads
            ActiveTargetProfileNotifier (Provider) and threads it as
            currentTargetProfile into the read service. Without this
            wire, the build call was passing only the shifts list, so
            the new currentTargetProfile parameter from 7.55q.4 was
            never used in production.
          ↓
       VarianceWeekProjectionReadService.build(
            shifts, currentTargetProfile: profile)
          → for non-closed children: theoreticalLaborPct = profile.theoreticalLaborPct
          → for closed children: theoreticalLaborPct = shift.theoreticalLaborPct (locked)
          → mixed days are an honest sales-weighted blend of the two
```

## Closed Rule 4 exception preserved

`_ClosedShiftDetail` (variance_report.dart lines ~936–1099) reads
exclusively from `ShiftRecord.lockedTarget*` fields:

- `s.lockedTargetCPLH` / `s.lockedTargetPPA` / `s.lockedTargetSPLH`
- `s.lockedTargetFohWage` / `s.lockedTargetBohWage`
- `s.lockedTheoreticalFohLaborPct` / `s.lockedTheoreticalBohLaborPct`
- closed-shift blended wage = `s.modelFohHours × lockedFohWage + s.modelBohHours × lockedBohWage`

This branch is **not touched** in `7.55q.4`. Closed Full Week rows
remain locked historical truth.

## Honest degradation

- **WTD path with no current profile**: `_loadActiveProfile` already
  bootstraps via `WageStandardContextService.loadOrBootstrapProfile`,
  so a current profile always exists by the time WTD runs. No new
  fallback needed.
- **Full Week path with no current profile**: same — bootstrap path
  already covers it.
- **`_ProjectedShiftDetail` with `ActiveTargetProfileNotifier?` not
  in scope (e.g. legacy widget tests)**: the `context.watch` returns
  null, the widget falls back to `shift.snapshotBlendedWage ??
  shift.blendedWage` and `shift.theoreticalLaborPct`. Under the
  rewired `_resolveProfileForFullWeek` path, those `shift.*` values
  ALSO reflect the current profile, so the rendered number is the
  same — the Provider read is just the structurally correct path.
- **`VarianceWeekProjectionReadService.build` with
  `currentTargetProfile: null`**: backward-compatible — falls back to
  per-shift `theoreticalLaborPct` (the existing behaviour) so the
  pure-data tests in `variance_week_projection_read_service_test.dart`
  keep working without restructuring.

## Files touched

| File | Change |
|---|---|
| `lib/data/shift_service.dart` | `_buildLockedWeekToDate` no longer projects the profile from the snapshot's cycle — it now calls `_loadActiveProfile(restaurantId)` for current Benchmark-owned targets. The `cycle` parameter and the cycle load in `getLiveWeekToDate` are dropped (the cycle is no longer needed for this path; closed-truth still reads its own per-shift `lockedTarget*` fields elsewhere). `_resolveProfileForFullWeek` now always returns the current `ActiveTargetProfile` so open/projected `ShiftRecord` conversions inherit current Benchmark-owned target fields. Unused imports for `TargetCycleActiveTargetProfileProjector`, `SqliteTargetCycleRepository`, and `TargetCycle` removed. |
| `lib/screens/variance_report.dart` | Added `import '../data/active_target_profile_notifier.dart';`. `_ProjectedShiftDetail` now reads the current `ActiveTargetProfile` via Provider and uses `profile.targetBlendedWage` for the Blended Wage row and `profile.theoreticalLaborPct` for the Labor % row, with honest fallback to the previous `shift.snapshot­BlendedWage ?? shift.blendedWage` / `shift.theoreticalLaborPct` chain when the profile isn't in scope. Plan-owned reads (covers / FOH hours / BOH hours) stay from `shift.*`. `_ClosedShiftDetail` (Rule 4 exception) is untouched. **review-fix:** `_FullWeekSectionState.build()` now reads `context.watch<ActiveTargetProfileNotifier?>()?.profile` and passes it as `_readService.build(widget.shifts, currentTargetProfile: currentTargetProfile)` so the collapsed day-row aggregate path actually receives the profile end-to-end. |
| `lib/services/variance_week_projection_read_service.dart` | `build(...)` now accepts an optional `ActiveTargetProfile? currentTargetProfile`. When provided, day-row aggregate `_weightedTheoreticalPct` / `_meanTheoreticalPct` substitute `currentTargetProfile.theoreticalLaborPct` for non-closed children's contribution; closed children continue to contribute their own `shift.theoreticalLaborPct` (locked truth). When `currentTargetProfile` is null, the previous per-shift behaviour is preserved (backward compatibility for the pure-data tests). |
| `test/wtd_variance_logic_test.dart` | No new tests added — the existing `WeekData` getters all delegate cleanly to the injected target fields; the new shift_service injection is exercised via integration tests below. |
| `test/variance_week_projection_read_service_test.dart` | Added group `G` — proves the new `currentTargetProfile` parameter: G1 closed rows still use locked `shift.theoreticalLaborPct` even when a current profile is passed; G2 non-closed rows use `profile.theoreticalLaborPct` when passed; G3 mixed days produce a sales-weighted blend with closed-locked + non-closed-current contributions; G4 omitting the parameter preserves the legacy per-shift behaviour. |
| `test/variance_visual_widget_test.dart` | Added group `G` — proves `_ProjectedShiftDetail` reads the current Benchmark-owned values via the `ActiveTargetProfileNotifier` provider (blended wage from `profile.targetBlendedWage`, theoretical labor % from `profile.theoreticalLaborPct`); plan-owned values (covers / FOH hours / BOH hours) still come from the `ShiftRecord` Plan-side; the `_ClosedShiftDetail` branch is unaffected. **review-fix:** added `G4` + `G5` plus a `_ScreenWireProbeDataSource` that returns ONE all-projected day with zero-input shifts; G4 with the profile in scope verifies the rendered collapsed day-row labor % equals the profile's `theoreticalLaborPct` (87.7%, distinct from the locked shift value 33.3%) — proves the wire delivers the profile end-to-end. G5 without the notifier verifies the day-row falls back honestly to the locked shift theoretical (33.3%). |
| `docs/archive/phases/7_55q/phase_7_55q_4_variance_linearity_rewiring.md` | **New** — this doc. |

## Files intentionally untouched

| File | Why |
|---|---|
| `lib/models/week_data.dart` | The `7.55q.3` blended-wage seam already routes WTD blended wage to the canonical formula. The fields are injected by `shift_service.dart`; this slice fixes the injection source, not the model. |
| `lib/models/shift_record.dart` | No additive non-closed read seam needed — `_ProjectedShiftDetail` reads the current profile directly via Provider, and `VarianceWeekProjectionReadService` accepts the profile as a parameter. |
| `lib/domain/models/active_target_profile.dart` | `7.55q.3` already added `targetBlendedWage` and the static `computeTargetBlendedWage` seam; this slice consumes them. |
| `lib/domain/models/weekly_plan_snapshot.dart` | No new helper needed — Plan-owned reads were already correct. |
| `lib/data/weekly_plan_snapshot_service.dart` | No new read seam needed. |
| `lib/data/schedule_plan_read_service.dart` | Untouched — Schedule's `7.55q.2` read-only path is unchanged. |
| `lib/models/week_record.dart` | Drift 6 — owned by `7.55q.5`. |
| `lib/screens/week_detail_screen.dart` | Drift 7 — owned by `7.55q.5`. |
| `lib/screens/baseline_tracker.dart` | Already conformant after `7.55q.3`. |
| `lib/screens/schedule_builder.dart` | Already conformant after `7.55q.2`. |
| `_ClosedShiftDetail` block in `lib/screens/variance_report.dart` | Rule 4 exception — closed Full Week rows stay locked historical truth. |
| Tracker markdown files | Per prompt, no tracker updates in this run. |

## Remaining gaps (handed off to later slices)

- **`7.55q.5`** — History `WeekRecord` / `week_detail_screen`
  conformance: stop re-modeling target hours from actuals (Drift 6),
  stop the unweighted `(FOH + BOH) / 2` blended-wage average (Drift 7).
  Should adopt `ActiveTargetProfile.computeTargetBlendedWage(...)` for
  the current-cycle teaching context while preserving locked closed
  truth for closed weeks.
- **Persisting current-profile read on the open snapshot's
  `snapshotBlendedWage` field**: out of scope. The widget-level read
  via Provider is the structurally correct path.
- **Rewriting projected `ShiftRecord` rows in the database to current
  targets**: not done. The widget reads the current profile via
  Provider; aggregation reads through the read service's profile
  parameter. Stale `ShiftRecord` target fields on projected rows are
  no longer authoritative for non-closed rendering.
- **Daypart-aware breakdowns** (`Phase 10.5`): out of scope.
- **Variance audit trail** (showing "snapshot was originally locked
  to cycle X but Benchmark has since rolled to cycle Y"): out of
  scope. Could be added later as a non-blocking provenance overlay.
