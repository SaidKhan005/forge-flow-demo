# Phase 7.55q.8 - Test Cleanup: Handoff Follow-Through

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed

## Goal

Bring the test suite up to date with two runtime ownership changes that
landed after `7.55q.6`:

1. `ScheduleForecastNotifier.theoreticalLaborPct` is now the
   benchmark-owned target seam (not `_plan?.theoreticalLaborPct`).
2. `_PlanImpactSection` in Baseline Manager reads wages from the active
   profile via `ActiveTargetProfileNotifier` when the provider is in
   scope (`MeridianConfig` is now a fallback only).

## Scope

- In: stale reason-comment fixes in `test/schedule_builder_widget_test.dart`;
  one new pair of tests (unit + widget) under group `E` proving the
  benchmark-owned `theoreticalLaborPct` rule; one new pair of tests
  (unit + widget) under group `S` in `test/baseline_manager_screen_test.dart`
  proving the wage-authority rule; this phase doc.
- Out: product/runtime code. No changes under `lib/`.
- Out: tracker markdown.
- Out: bridge/model migration lanes (`MeridianConfig` fallback,
  `StaticShiftDataSource`, `WeeklyPlanSnapshot` model surgery). Those
  are load-bearing for historical compatibility and stay until their
  owning seam retires.

## Runtime rule being pinned by tests

### Schedule weekly theoretical labor % — benchmark-owned

```
ScheduleForecastNotifier.theoreticalLaborPct
   └── _theoreticalLaborPct (stored field)
         ├── locked mode: captured at construction from
         │    ActiveTargetProfile.theoreticalLaborPct
         └── live/preview mode: LaborModel.theoreticalLaborPct(...)
              from the explicit CPLH/SPLH/PPA/wages that built the preview
```

It does **not** read `_plan?.theoreticalLaborPct`. A locked plan whose
`theoreticalLaborPct` differs from the active profile must not leak into
the Schedule weekly summary card.

### Manager Override preview wage authority — profile-backed

```
_PlanImpactSection.build
   └── profile = context.watch<ActiveTargetProfileNotifier?>()?.profile
   └── ManagerOverridePlanPreview.fromDraftSelection(
        selected,
        historicalWeeklyAvgCovers: ...,
        fohWage: profile?.fohWage ?? MeridianConfig.fohWage,
        bohWage: profile?.bohWage ?? MeridianConfig.bohWage,
      )
```

When the profile notifier is in scope, preview `targetBlendedWage` /
`theoreticalLaborPct` must move with the profile's wages, not stay on
the `MeridianConfig` default.

## Files touched

| File | Change |
|---|---|
| `test/schedule_builder_widget_test.dart` | Group C header + first test reason-comment updated to reflect 7.55q.8 benchmark-owned seam (replaces the stale "sources from the snapshot-locked plan's theoretical %" wording). Group D test D3 reason-comment rewritten to explain that `theoreticalLaborPct == 0.0` here because `profile.theoreticalLaborPct == 0`, not because the plan is null (plan nullity no longer influences the getter). Added new group E with two tests: a pure-Dart assertion that `notifier.theoreticalLaborPct` equals the profile's 27.5%, not the plan's 22.05%; a widget test that renders `ScheduleBuilder.testContent` with that setup and asserts `27.5%` renders under THEORETICAL LABOR %, while `22.1%` does not appear. Both would fail under the pre-7.55q.8 rule. |
| `test/baseline_manager_screen_test.dart` | Added imports for `ActiveTargetProfileNotifier`, `ActiveTargetProfile`, `package:provider/provider.dart`. Added new group S with two tests: a pure-Dart assertion that `fromDraftSelection` with distinct wages produces a preview with a different `targetBlendedWage` + `theoreticalLaborPct` than the `MeridianConfig`-default call (volume-side fields stay equal, wage-driven fields move); a widget test wrapping `BaselineManagerScreen.withCandidates` in a `ChangeNotifierProvider<ActiveTargetProfileNotifier>.value(...)` with a profile whose wages are `fohWage: 25.00 / bohWage: 32.00`, selecting a candidate, and asserting the rendered BLENDED WAGE matches the profile-driven computation rather than the `MeridianConfig`-default computation. |
| `docs/phases/7_55q/phase_7_55q_8_test_cleanup_handoff_followthrough.md` | **New** — this doc. |

## Files intentionally untouched

| File | Why |
|---|---|
| `lib/screens/schedule_builder.dart` | Runtime already correct; the test was stale. |
| `lib/screens/baseline_manager_screen.dart` | Runtime already correct; test coverage was missing. |
| `lib/models/shift_record.dart` | Runtime change listed in the prompt context, but the stored-over-fallback assertion is covered elsewhere (existing `shift_service_close_shift_test.dart` + `target_state_alignment_test.dart` groups). No new test needed here per scope. |
| Tracker markdown files | Per prompt, no tracker updates in this run. |
| `MeridianConfig` / `BaselineData` / `StaticShiftDataSource` compat paths | Out of scope — load-bearing until their owning seam retires. |

## What this slice does NOT do

- **No runtime behavior change.** Every edit is inside `test/` plus this
  doc.
- **No weakening of existing assertions.** New group E and group S add
  assertions that would fail under the pre-7.55q.8 rule — they tighten
  the contract, not loosen it.
- **No giant helper harnesses.** Group E reuses the existing `makeProfile` /
  `makePlan` helpers in its file. Group S reuses the file's existing
  navigation helpers (`_tapCalendarDate`, `_tapCandidateTile`) and adds
  a single small `makeProfileWithWages` factory.
- **No tracker truth changes.**
- **No commit.**

## Remaining gaps

- `ShiftRecord.totalLaborPct` / `blendedWage` stored-over-fallback rule:
  covered by existing tests but not with an explicit "stored wins over
  fallback" assertion. If a future slice wants that explicit proof, add
  it to `test/shift_service_close_shift_test.dart` — out of scope here.
- Unified naming pass (e.g. renaming `targetLaborPct` to
  `theoreticalLaborPct` on `ShiftDashboardReadModel`): already noted as
  a future polish in `7.55q.6`'s Remaining gaps. Not relevant here.
