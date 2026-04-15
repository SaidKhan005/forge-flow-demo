# Phase 7.55p.5f1 - Wage Mix Setup UX + Wage Authority Trickle Verification

Updated: 2026-04-13
Owner: Claude implementation
Status: Landed (follow-up cleanup `7.55p.5f1a` applied)

## Goal

Replace the low-level row-by-row fallback-role editor in Settings with a
coherent whole-mix wage setup UX for the "no integrated wage authority"
case, while preserving the exact same downstream wage-authority seam.

## Scope

- In: Settings wage UX redesign; single whole-mix editor; small summary
  helper on the wage authority service; real widget save-path tests;
  phase doc
- In: honest verification that saved entries trickle through the same
  `WageRoleRow -> WageStandardContextService -> ActiveTargetProfile`
  path into Benchmark, Variance, and Shift wage consumers
- Out: code changes to `baseline_tracker.dart`, `week_data.dart`,
  `shift_service.dart`, `shift_dashboard_read_model.dart`,
  `variance_report.dart`, or any tracker markdown file
- Out: historical actual fallback cleanup (`MeridianConfig` defaults
  when stored labor dollars are absent) — deliberately not widened
- Out: vendor connector implementation
- Out: benchmark recommendation-engine work

## UX Question

> If we cannot get wage truth from the live labor vendor, can Settings
> make whole-mix wage setup feel like one coherent pass instead of a
> sequence of isolated add/save cycles?

## Answer

**Yes, via a single whole-mix editor with the same persistence and
authority seam underneath.**

## Interaction shape

### Settings panel (read-only summary + one action)

```
WAGE AUTHORITY
─────────────
SOURCE         App Configured
FOH WAGE       $16.50
BOH WAGE       $21.35
REF BLENDED    $19.02

MIX SUMMARY
TOTAL HOURS/WK  65 h
WEEKLY COST     $1180

FRONT OF HOUSE (1)
 Server         $16.50   30h

BACK OF HOUSE (1)
 Line Cook      $20.00   35h

MANAGEMENT (0)
 —

[ Edit Wage Mix ]
```

The panel is now read-only. A single `Edit Wage Mix` button opens a
full-screen editor where the user fills the entire mix in one pass.

### Whole-mix editor (full-screen route)

```
Edit Wage Mix                                        [ Save ]
─────────────────────────────────────────────────────────────
FRONT OF HOUSE
 [Server    ] [$16.50] [30 h] X
 [Bartender ] [$18.00] [20 h] X
 + Add FOH row

BACK OF HOUSE
 [Line Cook ] [$20.00] [35 h] X
 + Add BOH row

MANAGEMENT
 (Management contributes to reference blended only.)
 + Add Management row

MIX SUMMARY
TOTAL HOURS/WK   115 h
WEEKLY COST      $2140

[!] Will fall back to Config Default on save. Add at least one FOH row
    AND one BOH row for App Configured.
```

Rules in the editor:

- All three buckets are editable on one surface. The user is not forced
  through a sequence of dialogs, one per role.
- Inline add, edit, and remove for every row.
- Live mix summary and live completeness warning update as the user
  types.
- A single `Save` action at the top-right commits the whole mix once.
- `Cancel` (close icon) discards all draft edits without touching
  persistence.

### Before this slice (what was wrong)

Before `7.55p.5f1`, Settings showed an ungrouped, flat list of
`FALLBACK ROLES` with a single `+ Add Role` button that opened a
dialog for one role at a time. There was no mix summary, no
completeness signal, and no whole-mix interaction.

The first pass of `7.55p.5f1` split the panel into FOH / BOH /
Management sections with a per-bucket `+ Add ... role` button. That
made the structure clearer but did not actually give the user a
whole-mix editing pass — each role still required its own add /
dialog / save cycle. The review rightly flagged this.

`7.55p.5f1a` landed the real whole-mix editor and demoted the
Settings panel itself to a read-only summary plus one `Edit Wage Mix`
action.

## What stayed identical

The wage authority seam is unchanged:

```
Settings whole-mix editor
   |
   v
WageRoleRow persistence (SqliteWageRoleRowRepository)
   |
   v
WageStandardContextService.resolve()
   |
   v
ActiveTargetProfile (fohWage / bohWage / theoretical %)
   |
   v
Benchmark _BaselineTargetsCard, Variance WeekData, Shift
ShiftDashboardReadModel
```

The editor's `Save` path produces a `_WageMixEditResult` diff of
upserts and deletes against the persisted rows. The Settings section
then walks that diff through `SqliteWageRoleRowRepository.upsertRow` /
`deleteRow` and calls
`WageStandardContextService.syncWagesToActiveProfile()` exactly once.
No parallel widget-only wage truth path exists.

## Computed Outputs Shown

- SOURCE (`App Configured` vs `Config Default`)
- FOH WAGE (resolved)
- BOH WAGE (resolved)
- REF BLENDED (resolved reference blended wage across all buckets)
- TOTAL HOURS/WK (sum of `weightedHours` across all buckets)
- WEEKLY COST (sum of `hourlyRate × weightedHours` across all buckets)

The mix summary is derived by a small static helper on
`WageStandardContextService` (`summarizeMix`) so both the Settings
panel and the editor read from one derivation path. The helper is
independently testable.

## Authority Seam Verification

| Step | Entry point | Notes |
|---|---|---|
| Editor save diff | `_WageMixEditResult` (local to Settings) | Pure result object; no DB calls |
| Persistence (upsert) | `SqliteWageRoleRowRepository.upsertRow(row)` | Same table, same schema |
| Persistence (delete) | `SqliteWageRoleRowRepository.deleteRow(id)` | Same table, same schema |
| Authority resolve | `WageStandardContextService.resolve(restaurantId)` | Still weights FOH rows, BOH rows, and all rows for blended; manager-only / single-bucket still degrades to `configFallback` |
| Active profile sync | `WageStandardContextService.syncWagesToActiveProfile()` | Called exactly once per save |
| Benchmark consumer | `_BaselineTargetsCard` reads `profile.fohWage`, `profile.bohWage`, `profile.theoreticalFohLaborPct`, etc. | Unchanged |
| Variance WTD consumer | `WeekData._targetFohWage / _targetBohWage` injected from `profile.fohWage / profile.bohWage` in `shift_service.dart` | Unchanged |
| Variance Full Week consumer | `ShiftRecord.theoreticalLaborPct` locked at close | Unchanged |
| Shift planned-package consumer | `ShiftDashboardReadModel.buildWholeDay()` reads `profile.fohWage / profile.bohWage` | Unchanged |

No widget directly overrides Benchmark / Variance / Shift with ad-hoc
computed wages. The UI purely renders resolved values.

## Honesty Rules Preserved

- **Manager rows contribute to reference blended wage only.**
  Manager rows are allowed in the editor, counted in the totals, and
  visible in the Settings summary, but they do not count as FOH or BOH
  standards. Manager-only setups still degrade to `configFallback`.
- **FOH and BOH standards require their own resolved buckets.**
  Single-bucket setups (FOH-only or BOH-only) still degrade to
  `configFallback`.
- **Incomplete setups degrade honestly, not silently.**
  Both the Settings panel and the editor show an explicit warning band
  when FOH or BOH is missing.
- **Source provenance stays explicit.**
  The `SOURCE` row in Settings still labels `App Configured` vs
  `Config Default`.
- **Invalid draft rows are dropped, not silently persisted.**
  Draft rows with empty role names or non-numeric rate/hours are
  skipped on save and do not become fake `WageRoleRow` records.

## Real widget save-path proof

`test/settings_screen_widget_test.dart` now includes save-path tests
that drive the actual UI:

- **Complete mix via real UI** — tap `Edit Wage Mix`, fill in FOH and
  BOH rows inline (three `TextField`s per row), tap `Save`, then assert
  SQLite has exactly those two rows and the `ActiveTargetProfile`
  fields downstream consumers read (`fohWage`, `bohWage`,
  `theoreticalFohLaborPct`, `theoreticalBohLaborPct`,
  `theoreticalLaborPct`) reflect the new wages.
- **Incomplete mix via real UI stays honest** — drive the editor with
  only a manager row, save, and assert the persisted row exists AND
  `resolve()` still returns `configFallback`, AND the `SOURCE` label
  in Settings still reads `Config Default`, AND the warning band is
  visible.

These replace the earlier repo-seeded tests that never tapped through
the UI.

## What Was NOT Done (Intentional)

- The historical-actual fallback paths in `ShiftRecord` / `WeekRecord`
  that still use `MeridianConfig` defaults when stored labor dollars
  are absent remain untouched. That cleanup is a separate lane.
- The vendor labor-integration path
  (`laborDerivedFromActualDollars` / `laborDerivedFromRatesAndHours`)
  remains a clean seam waiting for Phase 8.
- The benchmark recommendation-engine work (`7.55p.5g` and beyond) is
  separate and out of scope.

## Remaining Gaps

- **Vendor-fed wage authority path** — still an integration follow-up.
- **Per-daypart wage mix** — `10.5` may eventually want lunch vs
  dinner wage nuance.
- **Historical actual fallback** — `ShiftRecord` / `WeekRecord` config
  fallback when stored dollars are absent is still open debt.
- **Role templates / quick-setup presets** — seeding a blank mix with a
  recommended role list is still deferred as polish.
