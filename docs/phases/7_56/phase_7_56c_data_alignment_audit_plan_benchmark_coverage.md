# Phase 7.56c.1 - Data Audit Plan + Benchmark Coverage

Updated: 2026-04-24
Owner: Codex planning / tracker truth
Status: Complete - phase close landed alongside `7.56c.0`

## Closeout Note

The dev-only `DataAlignmentAuditPanel` now answers both architecture
questions in grouped sections:

1. Where did the live / actual value come from? (`liveActuals` group:
   presence / source-label checks for Shift + WTD actuals.)
2. Where did the target / comparison value come from? (`benchmarkAuthority`,
   `benchmarkRuntime`, `planLockedProjection`, `planRuntime` groups.)

The original 9 q-lane numeric drift checks remain present and are still
rendered above the new grouped sections. New diagnostic surface:
`DataAlignmentAuditCheck` (with numeric / intCount / presence / aggregate
factories) plus `DataAlignmentAuditGroupSummary`. Header summary now
combines q-lane + audit-check totals; missing data renders unavailable,
not false drift.

Accepted test evidence (2026-04-24):

- `dart analyze` — clean
- `flutter test test/data_alignment_audit_read_service_test.dart` — 33 tests
- `flutter test test/settings_screen_widget_test.dart` — 13 tests
- `flutter test test/current_state_alignment_test.dart` — 40 tests

## Goal

Expand the dev-only `DataAlignmentAuditPanel` from a partial drift sampler
to a full source-alignment monitor for live actuals plus Plan / Benchmark
targets.

Plain English: this audit is not checking whether the restaurant hit the
target. It is checking whether each displayed value came from the authority
the architecture says owns it. Example: if Sat Dinner actual covers are 54 and
the locked plan target is 60, the audit should confirm actual covers came from
shift truth and target covers came from the locked plan; it should not flag
54 vs 60 as architectural drift.

The audit should answer two questions:

1. Where did the live / actual value come from?
2. Where did the target / comparison value come from?

It should not flag expected operational differences such as live actuals
versus targets, or rolling demand moving after a weekly plan has already
locked.

## Current Gap

The audit currently computes 9 drift pairs:

- Shift target CPLH / PPA / theoretical labor %
- WTD target CPLH / PPA / theoretical labor % / blended wage
- FOH / BOH wage authority

That is useful, but incomplete. It displays more Plan and Benchmark data than
it checks, so architectural drift can still hide in un-checked fields.

## Dependency

Run `7.56c.0` plus its projection-sales and target-hour field follow-ups first.
The audit expansion should validate the repaired production read path rather
than encode older Full Week plan-target drift as the baseline.

## Coverage Target

### Live / Actual Provenance

- Shift Dashboard current covers, sales, PPA, CPLH, SPLH, actual hours, actual
  wage, and actual labor % come from closed/open operational shift truth, not
  from Plan or Benchmark targets.
- Variance WTD actual covers, sales, FOH hours, BOH hours, blended wage, and
  actual labor % come from finalized closed `ShiftRecord` truth through the
  current locked-week finalization window.
- Variance Full Week closed rows keep closed `ShiftRecord` actual truth for
  actual covers, actual sales, actual hours, actual wage, and actual labor %.
- Variance Full Week open rows keep current open-snapshot truth for actual /
  current facts where present, while projected rows remain plan context only.
- History and Week Detail actuals come from preserved closed `WeekRecord` /
  `ShiftRecord` truth, not regenerated current-week data.
- Learn evidence comes from closed historical shift evidence only, not open or
  projected current-week rows.

### Benchmark / TargetCycle / ActiveTargetProfile

- TargetCycle target CPLH -> ActiveTargetProfile target CPLH
- TargetCycle target SPLH -> ActiveTargetProfile target SPLH
- TargetCycle target PPA -> ActiveTargetProfile target PPA
- TargetCycle FOH wage -> ActiveTargetProfile FOH wage
- TargetCycle BOH wage -> ActiveTargetProfile BOH wage
- TargetCycle OPZ floor -> ActiveTargetProfile OPZ floor
- TargetCycle OPZ ceiling -> ActiveTargetProfile OPZ ceiling
- ActiveTargetProfile theoretical FOH % matches its formula
- ActiveTargetProfile theoretical BOH % matches its formula
- ActiveTargetProfile theoretical total % equals FOH % + BOH %
- ActiveTargetProfile target blended wage matches shared formula
- Active target cycle has its benchmark-selection summary when the summary
  table is available

### Benchmark -> Runtime Surfaces

- Shift target CPLH / SPLH / PPA / wages / OPZ / theoretical labor %
  match ActiveTargetProfile
- WTD target CPLH / SPLH / PPA / theoretical FOH % / theoretical BOH % /
  theoretical total % / blended wage match ActiveTargetProfile

### Locked Weekly Plan / SchedulePlan Projection

- WeeklyPlanSnapshot weekly values match projected SchedulePlan weekly values:
  forecast covers, forecast sales, required FOH hours, required BOH hours,
  FOH labor dollars, BOH labor dollars
- SchedulePlan day rows match WeeklyPlanSnapshot day rows
- Snapshot day rows reconcile to weekly totals for covers, sales, FOH hours,
  and BOH hours
- Plan formula invariants hold against the active profile values used by the
  snapshot: sales from covers x PPA; labor dollars from hours x wages

### Plan -> Runtime Surfaces

- Shift current-day forecast covers / forecast sales / plan FOH hours /
  plan BOH hours match the locked plan row for the open shift business date
- WTD forecast covers / target FOH hours / target BOH hours match the sum of
  locked snapshot day rows through the last closed business date
- WTD projected remaining sales match locked snapshot remaining forecast sales
  (`snapshot.forecastSales - wtdForecastSales`), not remaining forecast covers
  multiplied by current Benchmark PPA
- WTD total-week forecast covers matches the locked weekly snapshot forecast
  covers
- WTD total-week forecast sales matches the locked weekly snapshot forecast
  sales
- Variance Full Week daypart target covers / forecast sales / FOH hours / BOH
  hours match the shared `DaypartPlanAllocator` output used by Schedule for
  the same locked snapshot day row
- Variance Full Week closed-row actual fields remain closed shift truth while
  closed-row target fields match the locked Plan / Benchmark authority for the
  row context

## Implementation Notes

- Keep the panel dev-only.
- Prefer grouped checks over one long flat list.
- Existing `DataAlignmentDriftCheck` is numeric-only; adding a second
  diagnostic check type for identity/string/presence checks is allowed if it
  keeps the UI honest.
- To check plan projection fully, the audit snapshot may need to carry the raw
  `WeeklyPlanSnapshot` or an audit-only projection of its weekly/day values.
- To check live / actual provenance, prefer source labels and presence checks
  over comparing actual values to targets. Actual-vs-target differences are
  operational variance, not architectural drift.
- Degrade honestly when a source is missing; unavailable is not drift.

## Out Of Scope

- No production behavior changes.
- No target math, plan math, wage math, or snapshot generation changes.
- No live POS/labor/reservation transport.
- Do not treat rolling demand vs locked plan differences as drift.

## Acceptance

- The audit covers every stable Plan + Benchmark equality/invariant listed
  above.
- The audit covers live / actual provenance separately from target provenance.
- The header/group summaries count aligned, drifted, and unavailable checks.
- Missing data renders as unavailable, not as false drift.
- Existing 9 checks remain covered.
- Focused audit read-service and Settings panel tests pass.
