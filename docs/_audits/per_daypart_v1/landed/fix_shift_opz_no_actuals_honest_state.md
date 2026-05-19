# Audit — Shift daypart OPZ: honest "actuals not in yet" for a locked band with no labor

**Slice:** Per-Daypart Targets V1 — kill phantom BELOW-OPZ verdict.
**Branch:** `claude/fix-shift-opz-no-actuals` · **Base:** `master`
**Files:** `lib/screens/shift_dashboard.dart`, `lib/widgets/zone_status_card.dart`,
`test/widget/shift_dashboard_daypart_opz_no_actuals_test.dart` (new).

## The gap (re-confirmed on current master, post-#799)

`_ShiftSectionViewData.fromPeriod` (`shift_dashboard.dart`): when
`tc.hasOpzBand == true` but the period had no in-period labor minutes
(`hasLabor == false`), `currentCplh` defaulted to `0.0`, which is
`< floor` → `status = 'below'` → `'BELOW OPZ'` label + "Productivity is
below the OPZ floor. Too many labor hours for the volume." sub-line +
`currentCPLH: 0.0` fed into `ZoneStatusCard` as a real needle. A period
with a locked standard but no actuals yet rendered an alarming verdict
computed off a sentinel zero — a Metric Honesty / Design Rule 2
violation. `_FohProductivitySection` only degraded honestly when
`opz == null` (no band), never for band-exists/no-actuals.

## The fix

1. `fromPeriod` OPZ branch split by `hasLabor`. `tc.hasOpzBand &&
   !hasLabor` now produces an honest pending `_OpzBandData`
   (`opzStatus: 'pending'`, `opzLabel: 'AWAITING ACTUALS'`, neutral
   sub-label, sentinel `currentCPLH: 0.0` that is **not** rendered). The
   `hasLabor == true` branch is the prior logic verbatim (real verdict /
   needle preserved). The `opz == null` (no band) path is untouched.
2. `ZoneStatusCard` honors `opzStatus == 'pending'`: neutral
   `AppColors.textMuted` verdict color, CURRENT CPLH renders `'—'`
   instead of `0.00`, and `_CplhGauge` gets a `showCurrent` flag
   (default `true`) that suppresses **only** the current-position dot in
   both the normal and ultra-narrow render paths. The band, zones,
   floor/ceiling/target ticks + labels, and the CPLH×SPLH matrix still
   render — the operator still sees the locked standard; the band is not
   silently hidden.

The band-still-drawn choice also keeps the Slice-4 operator decision
("Full card, dashes — maximum 1:1 parity"; closed-stamp + zero actuals
must still mount `ZoneStatusCard`, not the no-zone line) intact.

## Pattern B — 14-lens self-audit (file:line)

| # | Lens | Verdict | Evidence |
|---|------|---------|----------|
| 1 | Slice intent met | PASS | `shift_dashboard.dart:824-878` — `tc.hasOpzBand && !hasLabor` → `opzStatus:'pending'`, `opzLabel:'AWAITING ACTUALS'`, sentinel CPLH not scored. |
| 2 | No phantom verdict (Metric Honesty / DR2) | PASS | No `status = currentCplh < floor` path reachable with `currentCplh == 0.0`; pending branch never computes a `below/above/in` status. `zone_status_card.dart:60-72` neutral color; `:93` value → `'—'`. |
| 3 | Real-actuals case unchanged | PASS | `shift_dashboard.dart:849-878` `else` branch is the pre-fix logic byte-for-byte (`bucket.cplh`, same status/label/sub strings, same `_OpzBandData`). Test (b) green: CPLH 12.50 → `IN OPZ` + `12.50`. |
| 4 | No-band case unchanged | PASS | `fromPeriod` only enters the OPZ block under `tc.hasOpzBand`; `_FohProductivitySection.build` `opz == null` no-zone line untouched (`shift_dashboard.dart:1071-1093`). Test (c) green. |
| 5 | Whole-day byte-identical | PASS | `fromWholeDay` (`:749`) unchanged; `_computeOpzStatus` only returns `below/above/in` (`shift_dashboard_read_model.dart:532-540`) so whole-day never hits the new `'pending'` branch. Test (d) green: no `AWAITING ACTUALS` in whole-day, `ZoneStatusCard` still mounts. |
| 6 | No silent band hide | PASS | Pending still renders `ZoneStatusCard` with band/ticks/matrix; only the needle + numeric value are suppressed. `zone_status_card.dart:108-114`, `:424-439`, `:548-565`. |
| 7 | Reused existing affordance, no new visual | PASS | `showCurrent` only gates the existing dot `Positioned`; band/labels/matrix code paths unmodified. Mirrors the matrix grid's existing null-input "no active marker" honesty. |
| 8 | Concurrency boundary respected | PASS | Only `shift_dashboard.dart` + `zone_status_card.dart` + new test touched. `sqlite_database_seed.dart`, `learn_teaching_analyzer.dart`, `variance_learn_tab.dart`, `shift_service_period_notifier.dart` untouched (`git diff --stat`). |
| 9 | `DaypartTargetContext` read-only | PASS | `tc.hasOpzBand`/`opzFloorCPLH`/`opzCeilingCPLH`/`targetCPLH` read only; no notifier edits. |
| 10 | Static analysis | PASS | `dart analyze lib/screens/shift_dashboard.dart lib/widgets/zone_status_card.dart` → "No issues found!". |
| 11 | Tests prove the seam | PASS | New `shift_dashboard_daypart_opz_no_actuals_test.dart` — 4 cases (a/b/c/d). Full suite below all green. |
| 12 | No regression in OPZ consumers | PASS | `target_consistency_opz_test.dart` + `baseline_override_propagation_test.dart` → 28/28. `daypart_closed_state` + `daypart_parity` + `true_1to1_layout` + new → 21/21. |
| 13 | No new RenderFlex overflow in OPZ | PASS | Test (a) `tester.takeException()` is null at phone width post-toggle. Residual overflow logs originate in `metric_pill.dart` / `data_source_health_pill.dart` (untouched whole-day widgets) at the 800×600 default test viewport — pre-existing, present on master, unrelated to OPZ. |
| 14 | Copy is operator-grade, non-alarming | PASS | "AWAITING ACTUALS" + "Locked productivity zone is set. Waiting on labor punches for this period before scoring." — plain-English, reads as status not alarm (UX writing standard). |

## Local verification (CI dark — disclosed)

```
flutter pub get                                            → Got dependencies!
dart analyze lib/screens/shift_dashboard.dart \
             lib/widgets/zone_status_card.dart              → No issues found!
flutter test test/widget/shift_dashboard_daypart_opz_no_actuals_test.dart \
             test/widget/shift_dashboard_daypart_closed_state_test.dart \
             test/widget/shift_dashboard_daypart_parity_test.dart \
             test/widget/shift_dashboard_daypart_true_1to1_layout_test.dart
                                                            → All 21 tests passed!
flutter test test/target_consistency_opz_test.dart \
             test/baseline_override_propagation_test.dart   → All 28 tests passed!
```

## Verdict

Phantom BELOW-OPZ verdict + 0.0 needle for a locked band with no
in-period labor is eliminated; the band is still shown with an honest
"actuals not in yet" state. Real-actuals, no-band, and whole-day paths
are unchanged. Scope held to `shift_dashboard.dart` +
`zone_status_card.dart` + the new test.
