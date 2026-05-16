# Audit — Shift: per-daypart targets/benchmarks on daypart metric tiles (true peer of whole-day)

**CORE item — flagged for operator review before merge.**

Branch: `claude/ux-shift-daypart-parity` · Base: `master` (off `origin/master` @ `814802e5`, PR #814 already merged — whole-day primary-driver chip + daypart header de-dup NOT redone).

## Operator finding (live walkthrough 2026-05-16, verbatim intent)

> "The whole day tiles have the targets and benchmarks on each widget/tile at the bottom of the live metric but the day part ones don't. Core app logic says the benchmark and plan form the targets and the benchmarks that Shift compares to. This currently applies to whole day but also needs to apply to day parts and be shown on the day part widgets." Also: on the daypart breakdown, targets show as a pooled **"whole-day est."** stand-in — "why are they whole-day est?".

## Root cause (verified on fresh master)

The Shift daypart lens reads its locked per-period context from `ShiftServicePeriodNotifier._safeLoadActiveTargetProfile` → `WageStandardContextService.loadOrBootstrapProfile`. That seam returned a profile with an **empty `dayparts` list**:

- It calls the bare `TargetCycleActiveTargetProfileProjector.project(cycle)` — by Slice-1 design that projector is *projection-only* and drops per-period rows (`target_cycle_active_target_profile_projector.dart:22-45`, intentionally unchanged here).
- On the cache-hit branch it returned the persisted flat profile; `ActiveTargetProfile.fromMap` (`active_target_profile.dart:221-239`) does not rehydrate per-period rows.

So `profile.daypartFor(period)` was `null` for every period → `_resolveDaypartTargets` produced `DaypartTargetContext.none` → the daypart tiles drew no per-daypart target/benchmark and the daypart breakdown fell back to the pooled `"whole-day est."` tag (`daypart_table.dart:50`, sibling-owned, fixed for free via the shared seam). The canonical write seam `TargetCycleService._syncActiveTargetProfile` (`target_cycle_service.dart:645-663`) already does a project-then-`withDayparts` reattach; the read/bootstrap seam did not. That asymmetry is the bug.

Secondary: the per-period SALES forecast used actuals (`bucket.covers × tc.targetPPA`) so it hid pre-service and was never the plan-side benchmark whole-day uses; the FOH/BOH HRS "Target N hrs" footer was passed through null for every period.

## Change summary

| File | Change |
|---|---|
| `lib/services/wage_standard_context_service.dart:178-188, 210-237` | `loadOrBootstrapProfile` now reattaches the active cycle's locked per-period rows onto the returned profile on **both** branches (projected + cache-hit) via new pure-projection helper `_reattachCycleDayparts` (`:217-238`), mirroring `TargetCycleService._syncActiveTargetProfile`. No math; persisted SQLite parent row stays the legacy flat shape (per-period rows live on the cycle child table, reattached on read). `+ import target_cycle.dart`. |
| `lib/state/shift_service_period_notifier.dart:91-122` | `DaypartTargetContext` gains read-only nullable plan-side fields `forecastSales` / `requiredFohHours` / `requiredBohHours` (+ constructor params + doc). |
| `lib/state/shift_service_period_notifier.dart:405-489` | `_resolveDaypartTargets` loads the in-force `WeeklyPlanSnapshot` once (`getSnapshotForBusinessDate`, defensive try/catch), reads the per-`(businessDate, period)` `WeeklyPlanSnapshotDayDaypart` child row, and threads `forecast_sales` / `required_foh_hours` / `required_boh_hours` into every constructed context (closed_stamp, open_profile, both none branches — the none branches now build an explicit context so plan footers survive a Gap-42 rate fallback). `+ import weekly_plan_snapshot.dart`, `+ import sqlite_weekly_plan_snapshot_repository.dart`. |
| `lib/screens/shift_dashboard.dart:822-830` | `_ShiftSectionViewData.fromPeriod` SALES forecast now prefers the locked per-daypart `tc.forecastSales` (plan-side, present pre-service — true 1:1 with whole-day `rm.forecastSales`); falls back to the prior derived `covers × targetPPA` only when no snapshot row, so no demo state regresses; absent → `0` → honest "No forecast available". |
| `lib/screens/shift_dashboard.dart:914-957` | `fromPeriod` FOH/BOH HRS fed by local `hoursColumn(...)` helper: populates `needed`/`excess` from `tc.requiredFohHours`/`requiredBohHours` only when a locked value exists AND the period has in-period labor minutes (no verdict off a phantom `0` — mirrors the OPZ "AWAITING ACTUALS" doctrine); else value-only. Shared `_CompactHoursColumn` widget untouched → whole-day byte-identical. |
| `test/wage_standard_context_service_daypart_passthrough_test.dart` | NEW unit (seeded demo): `loadOrBootstrapProfile` returns differentiated lunch/dinner/late_night rows; cache-hit branch also carries them. |
| `test/widget/shift_dashboard_daypart_target_footers_test.dart` | NEW widget: per-daypart SALES/FOH/BOH footers populate with the per-daypart value (not the pooled whole-day number); honest degrade; whole-day footers byte-unchanged. |

## Proof: footers fed from the locked benchmark + plan seam, honest degrade

**Benchmark (cycle) axis** — `WageStandardContextService._reattachCycleDayparts` (`wage_standard_context_service.dart:217-238`) maps `cycle.dayparts` (`TargetCycleDaypart`, hydrated from `target_cycle_dayparts` by `TargetCycleDao._hydrateWithDayparts`) → `ActiveTargetProfile.dayparts` (`ActiveTargetProfileDaypart`). `ActiveTargetProfile.daypartFor(period)` (`active_target_profile.dart:110-115`) then returns the locked per-period row, consumed by `_resolveDaypartTargets` (`shift_service_period_notifier.dart:449-489`) into `DaypartTargetContext.targetCPLH/SPLH/PPA/opz*` + `daypartTheoreticalLaborPctFor` (`active_target_profile.dart:142-153`). For a **closed** period the locked closed-shift stamp still wins (`shift_service_period_notifier.dart:434-455`, Promise 2 — unchanged).

**Plan axis** — `_resolveDaypartTargets` reads the in-force locked `WeeklyPlanSnapshot` (`shift_service_period_notifier.dart:415-419`) and its `WeeklyPlanSnapshotDayDaypart` child row (`weekly_plan_snapshot.dart:62-105, 356-367`) for `forecast_sales` / `required_foh_hours` / `required_boh_hours` (`:440-446`). These are read-only locked values — **no metric math** is performed (the only arithmetic is the `actual − target` delta the whole-day `_CompactHoursColumn` footer already computes inline, `shift_dashboard.dart:944`).

**Honest degrade (Design Rule 2 / Metric Honesty Doctrine):** when the cycle wrote no per-period row (Gap 42) `daypartFor` stays null → rate sub-lines/OPZ band hide exactly as before. When the snapshot has no child row, `forecastSales`/`requiredFohHours`/`requiredBohHours` are null → SALES shows "No forecast available" (`sales_forecast_card.dart:16,52-55`), FOH/BOH show the value alone — never `Forecast $0` / `Target 0 hrs`. With a locked required-hours value but **no in-period actuals**, the "Target N hrs" line + delta pill are suppressed (no verdict off a phantom `0`), consistent with the OPZ "AWAITING ACTUALS" rule (`shift_dashboard.dart:929-941`). The per_daypart_v1 seeded demo (lunch/dinner/late_night) carries per-daypart cycle rows + snapshot child rows, so on the demo build the footers populate with per-daypart values and the pooled tag does not show — proven by the two new tests + `per_daypart_v1_demo_seed_per_period_cycle_test` green.

## Pattern B — 14-lens self-audit

| # | Lens | Worker verdict + evidence | Orchestrator |
|---|---|---|---|
| 1 | Slice intent met | PASS — every daypart footer-bearing tile (SALES forecast, LABOR theoretical, FOH/BOH "Target N hrs", OPZ band) now shows the per-daypart locked target via the SAME shared widgets/footer placement as whole-day (`shift_dashboard.dart:822-830, 914-957`; LABOR/OPZ already wired, restored by the seam fix). MetricPill tiles (Covers/Wage/PPA/CPLH/SPLH) have no whole-day footer → none invented (prompt-directed). | |
| 2 | Authority order | PASS — Prompt > CLAUDE.md (Promise/Layer 9, Metric Honesty, Design Rule 2) > per_daypart_v1 plan. Projector kept projection-only per Slice-1 design; reattach mirrors the contract-endorsed `_syncActiveTargetProfile` seam. | |
| 3 | Promise 3 / Layer 9 (whole-day byte-untouched) | PASS — `fromWholeDay` (`shift_dashboard.dart:771-806`), `_CompactHoursColumn`, `SalesForecastCard`, read model unedited. Only `fromPeriod` projection changed. New test "whole-day SALES + FOH footers byte-unchanged" + `shift_dashboard_whole_day_driver_and_header_dedup_test` (14) green. | |
| 4 | Promise 2 (closed truth keeps stamp) | PASS — closed-period locked rate sub-lines still read the closed stamp (`shift_service_period_notifier.dart:434-455`, logic unchanged); plan-side fields are the in-force snapshot (parallels whole-day's live plan), not a re-grade of closed rate truth. `shift_dashboard_daypart_closed_state_test` green. | |
| 5 | Metric Honesty / Design Rule 2 | PASS — null forecast → "No forecast available"; null required-hours or no actuals → value-only, no `Target 0 hrs`; no phantom `Forecast $0`. New honest-degrade test asserts `findsNothing` for fabricated strings. | |
| 6 | Byte-consistent visual constants | PASS — no new widgets/copy; reuses `SalesForecastCard` "Forecast $X"/"No forecast available" and `_CompactHoursColumn` "Target N hrs"+delta verbatim (shared widgets, both lenses). | |
| 7 | Scope discipline | PASS — 3 source files (`git diff --stat`: shift_dashboard, shift_service_period_notifier, wage_standard_context_service) + 2 test files. `daypart_table.dart`, `baseline_tracker.dart`, `forge_flow_app.dart`, demo seed, Settings UNtouched. `target_cycle_active_target_profile_projector.dart` deliberately NOT modified. **Scope judgment for orchestrator review:** `wage_standard_context_service.dart` is not on the explicit allow-list but is the strictly-needed read-only projection seam feeding `ActiveTargetProfile.daypartFor` — the prompt's "fix the projection/wiring, not the widgets" + "add a minimal read-only accessor to expose [the locked value] (no math)". Flagged as a CORE item per prompt. | |
| 8 | No app-logic regression | PASS — `_matchesCycleProjection`/upsert decision unchanged (reattach applied only to the *returned* value, after the match decision; `wage_standard_context_service.dart:178-188`). `daypartFor`/`daypartTheoreticalLaborPctFor`/`dayDaypartFor` are pre-existing accessors; no formula added/changed. `wage_standard_context_service_test` (incl. I/M cache-hit/repair) 56/56 green. | |
| 9 | Null-safety / degrade paths | PASS — new fields `double?`; `tc.forecastSales ??` fallback; `hoursColumn` guards `requiredHours == null \|\| minutes <= 0`; snapshot read in defensive try/catch. `dart analyze` clean on all 5 touched/new files. | |
| 10 | Tests prove the seam | PASS — 5 new tests (2 unit end-to-end on seeded demo proving differentiated daypartFor through the real bootstrap seam; 3 widget proving per-daypart footers + honest degrade + whole-day unchanged). All shift_dashboard widget suites + daypart suite + seed-cycle + wage-service green (75 tests across the run). | |
| 11 | Backward compat | PASS — new `DaypartTargetContext` params optional → existing call sites, `.none`, `.fromBuckets` test ctor compile unchanged (analyze clean; `shift_dashboard_daypart_parity/_test/_true_1to1/_opz_no_actuals` green). | |
| 12 | UX writing | PASS — no new operator copy; reuses existing "Forecast $X" / "No forecast available" / "Target N hrs" wording. | |
| 13 | House rules | PASS — no `db/migrations/*` change → drift scanner N/A. Hooks installed (Step 0, `install_git_hooks.ps1`). No tracker edits. Graph not run. | |
| 14 | Contract STOP | PASS — branch → implement → self-audit → commit + push → PR → STOP. No merge, no tracker advance, no `--no-verify`. | |

## Test runs (CI dark — disclosed honestly)

- `flutter pub get` — Got dependencies (53 incompatible newer versions, pre-existing/unrelated).
- `dart analyze` on the 3 source + 2 test files — **No issues found**.
- `flutter test` (new) shift_dashboard_daypart_target_footers + wage_standard_context_service_daypart_passthrough — **5/5 pass**.
- `flutter test` (existing, regression) shift_dashboard_daypart_parity/closed_state/test/true_1to1_layout/opz_no_actuals + per_daypart_v1_demo_seed_per_period_cycle + wage_standard_context_service — **56/56 pass**.
- `flutter test` shift_dashboard_chip_foh_ux + ticker + whole_day_driver_and_header_dedup — **14/14 pass**.
- Full-repo suite NOT run (CI dark, token/time discipline); the entire touched seam's test surface is green and no PR-introduced regression observed. Latent unrelated failures: see `docs/KNOWN_FAILING_TESTS.md`.

STOP — PR opened; no merge, no tracker advance. CORE item — orchestrator + operator review before merge.
