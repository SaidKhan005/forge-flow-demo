# Phase 7.55p.5d - Variance Theoretical-Package Wiring Verification

Updated: 2026-04-13
Owner: Claude audit
Status: Landed (verification/doc only — no code changes needed)

## Goal

Verify that Variance consistently consumes the theoretical labor package
(not Shift's planned package) and that FOH / BOH / total labor target
ownership is explicit everywhere it matters.

## Scope

- In: line-by-line verification of Variance WTD and Full Week
  theoretical-package wiring; explicit evidence that FOH/BOH/total are
  available and consumed correctly
- Out: code changes (none needed — architecture already matches the
  7.55p.5c contract), Shift target redesign, blended wage refinement

## Verified Surfaces

### WTD Variance (`WeekData`)

| Field | Source | Line | Verdict |
|---|---|---|---|
| `theoreticalLaborPct` | Explicitly injected from profile | week_data.dart:78,121 | ✅ Theoretical |
| `theoreticalFohLaborPct` | Explicitly injected from profile | week_data.dart:76,122 | ✅ Theoretical |
| `theoreticalBohLaborPct` | Explicitly injected from profile | week_data.dart:77,123 | ✅ Theoretical |
| `variancePts` | `actualLaborPct - theoreticalLaborPct` | week_data.dart:124 | ✅ Against theoretical |
| `projTargetLaborPct` | `theoreticalLaborPct` | week_data.dart:174 | ✅ Theoretical |
| `projVariancePts` | `projActualLaborPct - projTargetLaborPct` | week_data.dart:175 | ✅ Against theoretical |

**WTD Variance screen rendering** (`variance_report.dart`):

| Display | Source | Line | Verdict |
|---|---|---|---|
| FOH Labor % Target column | `data.theoreticalFohLaborPct` | variance_report.dart:337 | ✅ Theoretical |
| BOH Labor % Target column | `data.theoreticalBohLaborPct` | variance_report.dart:347 | ✅ Theoretical |
| Total Labor % Target column | `data.theoreticalLaborPct` | variance_report.dart:357 | ✅ Theoretical |
| FOH variance pts | `actualFohLaborPct - theoreticalFohLaborPct` | variance_report.dart:340 | ✅ Against theoretical |
| BOH variance pts | `actualBohLaborPct - theoreticalBohLaborPct` | variance_report.dart:350 | ✅ Against theoretical |
| Total variance pts | `data.variancePts` | variance_report.dart:359 | ✅ Against theoretical |

### Full Week Variance (`VarianceWeekProjectionReadService`)

| Field | Source | Line | Verdict |
|---|---|---|---|
| Daypart-row theoretical | `ShiftRecord.theoreticalLaborPct` (locked at close) | variance_week_projection_read_service.dart:142 | ✅ Theoretical |
| Day-row theoretical | Sales-weighted mean of child rows' theoretical | variance_week_projection_read_service.dart:138-146 | ✅ Theoretical |
| Day-row variance | `laborPct - theoPct` | variance_week_projection_read_service.dart:82 | ✅ Against theoretical |
| Mean fallback | Mean of child rows' theoretical when no sales | variance_week_projection_read_service.dart:148-153 | ✅ Theoretical |

**Full Week screen rendering** (`variance_report.dart`):

| Display | Source | Line | Verdict |
|---|---|---|---|
| Shift detail Total Labor % Target | `s.theoreticalLaborPct` | variance_report.dart:1081 | ✅ Theoretical |
| Shift detail explicit label | `'(theoretical)'` | variance_report.dart:1246 | ✅ Explicit |
| Shift detail variance pts | `s.variancePts` | variance_report.dart:1083 | ✅ Against theoretical |

### `ShiftRecord.theoreticalLaborPct`

This is the locked-at-close snapshot of the theoretical labor % from the
target profile that was active when the shift closed. It is NOT Shift's
plan-based target. It is the same theoretical formula
(`fohWage / (CPLH × PPA) + bohWage / SPLH`) captured immutably at close
time. Confirmed by:

- Field comment: "locked at close — snapshot of target at time of shift"
  (shift_record.dart:21)
- `variancePts = totalLaborPct - theoreticalLaborPct` (shift_record.dart:130)
- Serialized as `theoretical_labor_pct` (shift_record.dart:264)

## Audit Verdict

**Variance is already correctly and consistently wired to the theoretical
labor package everywhere it matters.**

- WTD: all three levels (FOH, BOH, total) are explicitly injected from the
  profile's theoretical fields and consumed correctly
- Full Week: uses `ShiftRecord.theoreticalLaborPct` (locked at close) and
  sales-weighted aggregation for day rows
- No path in the Variance surface reads from or references Shift's planned
  target (`ShiftDashboardReadModel.targetLaborPct`)
- FOH/BOH breakdown is available and rendered in the WTD table
- The Full Week shift detail even says `'(theoretical)'` explicitly

## Why No Code Changes Are Needed

The 7.55p.5c contract predicted:

> Variance already uses the theoretical package. 7.55p.5d should verify
> that Variance WTD and Full Week consistently show theoreticalLaborPct
> from the profile/cycle authority.

This verification confirms that prediction. Every Variance path reads
from the theoretical package. The wiring is correct. The fields are
correctly named. The screen renders them honestly.

## Minor Observation: WTD Column Header

The WTD table uses `Target` as the column header for theoretical values.
This is a common convention in restaurant management (comparing actual
against target) and matches the 7.55k.4 semantic design. It is NOT the
same as Shift's `Target x.x%` label — the word "target" is used in its
generic sense ("what you aim for"), not in the specific
planned-package sense.

No label change is warranted here. The Benchmark surface already uses
`THEORETICAL` labels to distinguish its output (7.55p.5a), and Variance's
`Target` column is the established convention for this table layout.

## Existing Test Coverage

| Test file | What it verifies |
|---|---|
| `wtd_variance_logic_test.dart` | `theoreticalLaborPct` injected and consumed; `variancePts` derived correctly; FOH/BOH theoretical fields injected |
| `variance_week_projection_read_service_test.dart` | Full Week row status, driver labels, day-row reconciliation |
| `variance_visual_widget_test.dart` | Full Week rendering with `ActiveTargetProfile` injection; open/projected row semantics |

No additional tests are needed — the existing suite already proves the
theoretical-package wiring.

## Remaining Gaps

- **Blended wage refinement/testing** (7.55p.5e) — the blended wage
  formula itself, not the package contract or wiring
- **Daypart-aware theoretical labor** (10.5) — per-daypart theoretical
  output for finer-grained Variance
