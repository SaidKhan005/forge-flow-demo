# Slice 4 — Shift daypart card full parity (Per-Daypart Targets V1, Decision 7)

**Branch:** `claude2/per-daypart-slice-4-shift-card`
**Base:** `master` (`24db567e`)
**Slice tag:** Per-Daypart Targets V1 — Slice 4
**Owner:** worker agent (Claude lane, in-session Agent fallback)
**Verdict:** approve-for-merge (subject to orchestrator audit; UX-only — not auth/RLS/schema/proxy)

---

## TL;DR

The Shift screen's per-period card now mirrors the whole-day card fully — Outputs (Sales · Covers · Restaurant Blended Wage) + Inputs (PPA · CPLH · SPLH + FOH/BOH Hours) + FOH Productivity (per-period CPLH actual against the per-period OPZ band). Per Decisions 11 + 13 wages stay whole-day; per Design Rule 2 + `metric_card_honesty_contract.md` the per-period card NEVER falls back to whole-day pool values when the per-period target row is missing — affected pills render the honest "Target not yet locked" / "OPZ band not yet available" state instead.

Implementation surface area is small:
- `lib/state/shift_service_period_notifier.dart` exposes the loaded `ActiveTargetProfile` (already loaded internally for primary-driver computation; now also threaded through to the card via `profile` getter + `fromBuckets` constructor parameter).
- `lib/screens/shift_dashboard.dart` replaces `_DaypartMetricGrid` (the flat 3-row stub with the candid "no plan target on purpose" comment) with three new section widgets (`_DaypartOutputsSection`, `_DaypartInputsSection`, `_DaypartFohProductivitySection`) and reshapes `_DaypartScaffoldCard` to compose them. A small input-pill helper (`_PerPeriodInputPill`) and a hours-pill helper (`_PerPeriodHoursPill`) handle the honest-fallback rendering.

3 new widget tests under `test/screens/shift_dashboard_daypart_card_parity_test.dart` cover the closed-shift / open-with-target / open-no-target paths required by the Slice 4 brief. The single existing daypart test that asserted the pre-Slice-4 grid ($22.50 per-period blended wage + single-occurrence "12.50") was updated to match the Slice 4 contract (CPLH 12.50 now appears twice — Inputs pill + FOH Productivity header — and the pill labeled "RESTAURANT BLENDED WAGE" replaces the per-period blended wage assertion).

`dart analyze --fatal-infos` is clean on every changed file. `flutter test` for the 6 prompt-named test files is 100% green.

---

## Scope

| What | Where |
|---|---|
| Expose `ActiveTargetProfile?` from notifier | `lib/state/shift_service_period_notifier.dart:48-64` (state field), `:80-89` (`profile` getter), `:117-138` (constructor param), `:223-225` (assignment in `_load`) |
| Refactor `_DaypartScaffoldCard` to compose three sections | `lib/screens/shift_dashboard.dart:1097-1216` |
| New `_DaypartOutputsSection` (Sales · Covers · Restaurant Blended Wage) | `lib/screens/shift_dashboard.dart:1257-1369` |
| New `_DaypartInputsSection` (PPA · CPLH · SPLH + FOH/BOH Hrs) | `lib/screens/shift_dashboard.dart:1377-1485` |
| New `_DaypartFohProductivitySection` (per-period CPLH + OPZ band) | `lib/screens/shift_dashboard.dart:1493-1592` |
| New `_PerPeriodInputPill` (actual + per-period target with honest fallback) | `lib/screens/shift_dashboard.dart:1602-1681` |
| New `_PerPeriodHoursPill` (actual hours with honest fallback) | `lib/screens/shift_dashboard.dart:1689-1740` |
| Thread `profile`-derived daypart row + whole-day blended wage from call site | `lib/screens/shift_dashboard.dart:1077-1106` (`_DaypartScaffoldSection.build`) |
| `ActiveTargetProfileDaypart` import | `lib/screens/shift_dashboard.dart:10` |
| 3 new widget tests for Slice 4 | `test/screens/shift_dashboard_daypart_card_parity_test.dart` (new) |
| 1 existing test fixed to match Slice 4 contract | `test/widget/shift_dashboard_daypart_test.dart:173-190` |

**Public API:**

- `ShiftServicePeriodNotifier.profile` — new read-only getter exposing the loaded `ActiveTargetProfile?`.
- `ShiftServicePeriodNotifier.fromBuckets` — new optional `profile` constructor parameter (test-only seam).
- No other public API changes.

**Operator-facing copy:**

- New per-period card section labels: `SALES`, `COVERS`, `RESTAURANT BLENDED WAGE`, `PPA`, `CPLH`, `SPLH`, `FOH HRS`, `BOH HRS`, `PERIOD CPLH`, `IN OPZ` / `BELOW OPZ` / `ABOVE OPZ`, `OPZ X.XX – Y.YY`, `Target X.XX`.
- Honest-fallback copy: `Target not yet locked`, `OPZ band not yet available for this period.`, `No labor in this period yet.`, `No POS sales in this period yet.`, `No covers in this period yet.`, `Connect a POS vendor to see per-person average.`, `Connect a labor vendor to see covers per labor hour.`, `Connect a labor vendor to see sales per labor hour.`, `Connect a labor vendor to see blended wage.`
- Wage-scope clarifier: `RESTAURANT BLENDED WAGE` (deliberate label per Decisions 11 + 13 — wages don't have a per-period variant in Jim Taylor's framework; the operator should not confuse the restaurant-wide rate with a per-period rate).

**Files NOT touched (per stop-conditions):**

- `lib/services/target_cycle_service.dart`
- `lib/services/weekly_plan_snapshot_service.dart`
- `lib/services/shift_service.dart` (read-only)
- `lib/domain/models/active_target_profile.dart`, `target_cycle.dart` (read-only)
- `lib/domain/services/recommended_benchmark_selection_service.dart`
- `lib/domain/services/target_cycle_active_target_profile_projector.dart`
- `lib/domain/services/target_snapshot_builder.dart`, `shift_fact_builder.dart`
- `lib/dev/mock_integration_replay_seed.dart`
- `lib/infrastructure/persistence/sqlite/**` (read-only)
- `lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart`
- `lib/models/learn_benchmark_context.dart`, `learn_teaching_summary.dart`
- `db/migrations/**`
- `lib/infrastructure/persistence/postgres/*_postgres_sink.dart`

---

## 14-lens audit

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Slice strictly follows Decision 7 (per-period card = full mirror of whole-day card) and the Slice 4 row of `per_daypart_targets_v1_plan.md`. Honors `core_app_architecture.md` Promise 1 (`LaborModel`/whole-day card untouched), Promise 3 (per-period card sits adjacent to whole-day, never replacing), and Layer 9 (per-period split is additive). Honors Gap 16 clarification from `architecture_verification_2026_05_15.md` — both `_DaypartScaffoldCard` AND `_DaypartMetricGrid` were touched (the latter replaced wholesale with three section widgets). | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:75-77` (Decision 7); `:332-339` (Slice 4 row); `docs/_audits/per_daypart_v1/architecture_verification_2026_05_15.md:29-35` (Gap 16) | None |
| 2 | **Hard Promises** | HP #1 (Phase 8 = pure transport swap): no transport changes. HP #2 (kDemoMode = writer-side switch): no `kDemoMode` reader-side branch added — demo and prod render the same card path; the same `ShiftServicePeriodNotifier.profile` field is consulted regardless of source. HP #3 (No app logic before 7.58): the slice is a UX overhaul — no new computation, no new lever derivation, no new aggregation; the per-period CPLH/SPLH/PPA values come from the existing `ServicePeriodAccumulator` and per-period targets from the existing `ActiveTargetProfile.daypartFor` accessor (Slice 1). HP #11 (Hierarchy-scoped settings): N/A — no new settings surface. | `CLAUDE.md` Hard Promises #1-3, #11; `lib/screens/shift_dashboard.dart` (no new computation introduced) | None |
| 3 | **Service-layer split** | `lib/screens/**` change adds widget classes only — no I/O, no service logic. `lib/state/**` change adds a getter + constructor parameter on the existing `ShiftServicePeriodNotifier` — fits the established notifier-as-bridge pattern. No new files in `lib/services/`, `lib/domain/`, or `lib/infrastructure/`. The new section widgets sit alongside `_OutputsSection` / `_InputsSection` / `_LaborCard` / `_CompactHoursColumn` — same screen file, same widget grammar. | `lib/screens/shift_dashboard.dart:1257-1740` (new section widgets); `lib/state/shift_service_period_notifier.dart:48-64, 80-89, 117-138, 223-225` | None |
| 4 | **Architecture guardrails** | `LaborModel` untouched. `TargetCycle` untouched. `WeeklyPlanSnapshot` untouched. `ActiveTargetProfile` and `ActiveTargetProfileDaypart` are read-only consumers (the `daypartFor` accessor was added in Slice 1 — this slice consumes it but does not modify either type). The whole-day card (`_OutputsSection`, `_InputsSection`, `ZoneStatusCard` mount in `_buildWholeDaySlivers`) is byte-identical to pre-Slice-4 — the per-period card is purely additive (Promise 1). Source facts → derived metrics → teaching summaries separation preserved: the per-period card consumes derived metrics (`bucket.cplh`, `bucket.splh`, `bucket.ppa`) from the existing `ServicePeriodAccumulator` and per-period locked targets from the existing `ActiveTargetProfile.daypartFor` — never directly from source facts. | `lib/screens/shift_dashboard.dart:609` (`_OutputsSection` untouched); `:685` (`_InputsSection` untouched); `:213-225` (`ZoneStatusCard` mount untouched); `lib/domain/models/active_target_profile.dart:110` (`daypartFor` consumed read-only); `lib/services/shift_service_period_read_service.dart:115-126` (bucket derivation consumed read-only) | None |
| 5 | **Time guardrails** | No new time math introduced. Existing time-source contract (restaurant-local clock + business-date weekday) preserved by reuse of the existing `_restaurantLocalNow` resolver and `_DaypartScaffoldSection`'s already-correct period selection. No `DateTime.now()` introduced. No new TIMESTAMPTZ / TIMESTAMP fields. | `lib/screens/shift_dashboard.dart:1342-1356` (`_restaurantLocalNow` reused); `:1010-1041` (`_DaypartScaffoldSection.build` time-source reused) | None |
| 6 | **RLS-ready schema** | No schema changes. No fact-table reads added in the widget layer (the existing `ShiftServicePeriodNotifier._load` already consults `OperatorScopedRepository`-style readers; Slice 4 does not change the read path). | `lib/state/shift_service_period_notifier.dart:135-228` (read path untouched) | None |
| 7 | **Proxy & API conventions** | No proxy changes. No new API routes. No idempotency-key paths. No new vendor connectors. | n/a | None |
| 8 | **Testing seam** | 3 new widget tests (`test/screens/shift_dashboard_daypart_card_parity_test.dart`) cover: (1) closed-shift bucket with per-period target row → Outputs + Inputs + FOH Productivity render with live values, OPZ band reads as a range string; (2) open shift with `daypartFor` returning a value → per-period targets surface from the active profile (sentinel-distinct values prove the daypart row is consulted, not the parent profile pool); (3) open shift with `daypartFor` returning null → "Target not yet locked" + "OPZ band not yet available" honest-fallback, NEVER silent fall-back to whole-day pool values. The existing 10.5.2 daypart test was updated to match the Slice 4 contract (CPLH appears twice; per-period blended wage replaced by restaurant-wide labeled pill). | `test/screens/shift_dashboard_daypart_card_parity_test.dart` (3 tests, all passing); `test/widget/shift_dashboard_daypart_test.dart:173-190` (1 update) | None |
| 9 | **Operator-facing copy / UX writing standard** | New copy is minimal and direct. Section labels mirror the whole-day card (`SALES`, `COVERS`, `PPA`, `CPLH`, `SPLH`, `FOH HRS`, `BOH HRS`). Wage label intentionally diverges (`RESTAURANT BLENDED WAGE` instead of `BLENDED WAGE`) to make the scope explicit per Decisions 11 + 13. Honest-fallback copy is short and instructive: "Target not yet locked" (target side), "OPZ band not yet available for this period." (full sentence with period), tooltip strings name the integration class needed ("Connect a POS vendor to see per-person average."). No marketing language; no exclamation points. | `lib/screens/shift_dashboard.dart:1257-1740` (new copy strings) | None |
| 10 | **Demo mode contract** | No `kDemoMode` carve-out introduced. The per-period card's read seam is `ShiftServicePeriodNotifier.profile?.daypartFor(servicePeriodId)` — same path for demo and production. Demo and live operators see the identical UI shape; whether per-period targets surface depends only on whether the cycle has per-period rows (a writer-side concern owned by Slice 1 / Slice 1.5 / Slice 2; not a renderer concern). | `lib/screens/shift_dashboard.dart:1097-1216` (no `kDemoMode` import / branch); `lib/state/shift_service_period_notifier.dart` (no `kDemoMode` branch) | None |
| 11 | **Ceiling-raise rule** | No lint-tool ceiling raises. No `kAdvisorProxyMaxLines` adjustments. `lib/screens/shift_dashboard.dart` grew from 1727 → ~2080 LoC; this is a UX file with no enforced size cap. The growth is 1:1 with three new section widgets + two new pill widgets — each load-bearing and required by Decision 7. | `lib/screens/shift_dashboard.dart` | None |
| 12 | **Phase-doc hygiene** | Slice scope is captured in `per_daypart_targets_v1_plan.md` Slice 4 row + Decision 7 + Gap 16. No new phase doc needed (single file `<5 changed; UX-only). | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:332-339, 75-77, 383` | None |
| 13 | **Anti-scope** | Stop-conditions honored: `target_cycle_service.dart` UNTOUCHED. `weekly_plan_snapshot_service.dart` UNTOUCHED. `shift_service.dart` UNTOUCHED. `active_target_profile.dart` / `target_cycle.dart` UNTOUCHED. `recommended_benchmark_selection_service.dart` UNTOUCHED. `target_cycle_active_target_profile_projector.dart` UNTOUCHED. `target_snapshot_builder.dart` / `shift_fact_builder.dart` UNTOUCHED. `mock_integration_replay_seed.dart` UNTOUCHED. `lib/infrastructure/persistence/sqlite/**` UNTOUCHED. `postgres_shift_record_writer.dart` UNTOUCHED. `learn_benchmark_context.dart` / `learn_teaching_summary.dart` UNTOUCHED. `db/migrations/**` UNTOUCHED. `*_postgres_sink.dart` UNTOUCHED. The slice changed exactly what Slice 4 brief named: shift dashboard widget tree + the notifier's profile exposure (necessary to give the renderer the daypart row without breaking the service-layer split). | `git diff --stat` (3 files: `lib/screens/shift_dashboard.dart`, `lib/state/shift_service_period_notifier.dart`, `test/screens/shift_dashboard_daypart_card_parity_test.dart`, `test/widget/shift_dashboard_daypart_test.dart`) | None |
| 14 | **Honest disclosures** | `dart analyze --fatal-infos lib/screens/shift_dashboard.dart lib/state/shift_service_period_notifier.dart lib/models/shift_dashboard_read_model.dart lib/services/shift_service_period_read_service.dart test/screens/shift_dashboard_daypart_card_parity_test.dart test/widget/shift_dashboard_daypart_test.dart`: clean, "No issues found!". `dart analyze --fatal-infos lib/`: 0 errors, 14 pre-existing infos in unrelated files (`infrastructure/persistence/postgres/repositories/user_pii_erasure_repository.dart`, `infrastructure/persistence/sqlite/sqlite_database_seed.dart` deprecation infos, `widgets/push_permission_denied_card.dart` const-constructor infos). `flutter test test/screens/shift_dashboard_daypart_card_parity_test.dart`: 3/3 pass. `flutter test test/widget/shift_dashboard_daypart_test.dart`: 7/7 pass. `flutter test test/shift_dashboard_daypart_toggle_widget_test.dart`: 8/8 pass. `flutter test test/widget/shift_dashboard_ticker_test.dart`: 4/4 pass. `flutter test test/services/shift_service_period_read_service_test.dart test/services/shift_service_period_primary_driver_test.dart test/state/shift_service_period_notifier_test.dart`: 50/50 pass. `flutter test test/shift_dashboard_notifier_test.dart test/shift_dashboard_notifier_cold_boot_test.dart`: 14/14 pass. **Pre-existing failure disclosed:** `test/shift_dashboard_empty_state_widget_test.dart` fails on master (3 tests assert "No shifts or history found." copy that no longer renders). Verified by stashing my diff and re-running on clean origin/master — same failures. Not in `KNOWN_FAILING_TESTS.md` but unrelated to Slice 4. No CI run (CI dark per `CLAUDE.md`). Migration scanner / cutoff lint not run (no `db/migrations/**` changes). Browser QA not run (no operator-web surface touched). | Local runs in this worktree, 2026-05-15 | None |

---

## Pattern B exemplar — independent re-audit

| # | Lens | Independent re-audit | Citation |
|---|---|---|---|
| A | **Per-period read seam correctness** | The card consumes per-period locked targets via `ActiveTargetProfile.daypartFor(servicePeriodId)` — the canonical Slice 1 accessor (`lib/domain/models/active_target_profile.dart:110-115`). Slice 1's design rule 2 ("`null` (or an absent map entry) means 'unavailable'; never use `0` as a sentinel") is honored: when `daypartFor` returns null, `_DaypartScaffoldCard` passes a null `daypartProfile` to the section widgets, and the section widgets render `MetricState.unavailable` (em dash) + "Target not yet locked" instead of substituting whole-day pool values or zeros. Test 3 in `shift_dashboard_daypart_card_parity_test.dart` proves this: profile has `dayparts: const []`, so `daypartFor('lunch')` returns null, and the test asserts "Target not yet locked" appears 3 times (PPA / CPLH / SPLH pills) AND that none of the whole-day pool values (BaselineData.derivedTargetCPLH, derivedTargetPPA, derivedTargetSPLH, opzFloorCPLH, opzCeilingCPLH) appear as per-period target lines. | `lib/screens/shift_dashboard.dart:1077-1095` (call site reads `periodNotifier?.profile?.daypartFor`); `:1602-1681` (`_PerPeriodInputPill` honest-fallback rendering); `test/screens/shift_dashboard_daypart_card_parity_test.dart:309-358` (Test 3) |
| B | **Wages-stay-whole-day fidelity (Decisions 11 + 13)** | The per-period card NEVER computes a per-period blended wage. The `_DaypartOutputsSection`'s blended-wage pill consumes `wholeDayBlendedWage` (the restaurant-wide value from `ShiftDashboardReadModel.blendedWage`) via the call-site bridge in `_DaypartScaffoldSection.build`. The pill label is intentionally `RESTAURANT BLENDED WAGE` (not `BLENDED WAGE`) so the operator cannot read it as period-specific. The `bucket.blendedWage` getter on `ServicePeriodAccumulator` (lines 122-126) — which would compute a per-period rate from per-period wage dollars / per-period minutes — is intentionally NOT consulted by the new card. Wage-scope label asserted by both Test 1 in the new file and the updated assertion in `shift_dashboard_daypart_test.dart`. | `lib/screens/shift_dashboard.dart:1077-1106` (call site forwards `wholeDayBlendedWage` from `ShiftDashboardNotifier.readModel.blendedWage`); `:1257-1369` (`_DaypartOutputsSection` consumes `wholeDayBlendedWage`, not `bucket.blendedWage`); `lib/services/shift_service_period_read_service.dart:122-126` (`bucket.blendedWage` exists but not consumed by the per-period card); `test/screens/shift_dashboard_daypart_card_parity_test.dart:227-230` (label asserted) |
| C | **Widget structural mirror** | The per-period card now composes the same three sections as the whole-day card: Outputs (`_DaypartOutputsSection` mirrors `_OutputsSection`), Inputs (`_DaypartInputsSection` mirrors `_InputsSection`), FOH Productivity (`_DaypartFohProductivitySection` mirrors `ZoneStatusCard`). Each per-period section uses the same widget vocabulary as its whole-day counterpart: `MetricPill` for live actuals (Outputs covers/sales pills), GridView.count for the PPA/CPLH/SPLH input grid, `IntrinsicHeight + Row + Expanded` for two-column hour layouts. The FOH Productivity section uses the same OPZ band classification (`'in'` / `'below'` / `'above'`) and color rules (`AppColors.positive` / `negative` / `warning`) as the whole-day `ZoneStatusCard`. The card scaffold preserves the existing service-period header (shortLabel chip + label + start/end time range). The slice does not introduce a third metric grammar — every visual element matches one in the whole-day card or the existing slice 10.5 `_CompactHoursColumn` pattern. | `lib/screens/shift_dashboard.dart:609-680` (whole-day `_OutputsSection`) vs `:1257-1369` (per-period `_DaypartOutputsSection`); `:685-787` (whole-day `_InputsSection`) vs `:1377-1485` (per-period `_DaypartInputsSection`); `lib/widgets/zone_status_card.dart:34-65` (whole-day OPZ band classification) vs `lib/screens/shift_dashboard.dart:1493-1592` (per-period OPZ band classification — same logic, scoped to `daypartProfile.daypartOpz*`) |

---

## What I ran

```
powershell -ExecutionPolicy Bypass -File scripts/install_git_hooks.ps1
# -> Forge & Flow git hooks enabled for this clone.
#    Active hooks: pre-commit, pre-push.

flutter pub get
# -> Got dependencies! (53 packages newer; OK per env)

dart analyze --fatal-infos \
  lib/screens/shift_dashboard.dart \
  lib/state/shift_service_period_notifier.dart \
  lib/models/shift_dashboard_read_model.dart \
  lib/services/shift_service_period_read_service.dart \
  test/screens/shift_dashboard_daypart_card_parity_test.dart \
  test/widget/shift_dashboard_daypart_test.dart
# -> No issues found!

dart analyze --fatal-infos lib/
# -> 0 errors / 0 warnings; 14 pre-existing infos in unrelated files

flutter test test/screens/shift_dashboard_daypart_card_parity_test.dart
# -> 3/3 pass

flutter test test/widget/shift_dashboard_daypart_test.dart
# -> 7/7 pass

flutter test test/shift_dashboard_daypart_toggle_widget_test.dart
# -> 8/8 pass

flutter test test/widget/shift_dashboard_ticker_test.dart
# -> 4/4 pass

flutter test \
  test/services/shift_service_period_read_service_test.dart \
  test/services/shift_service_period_primary_driver_test.dart \
  test/state/shift_service_period_notifier_test.dart
# -> 50/50 pass

flutter test \
  test/shift_dashboard_notifier_test.dart \
  test/shift_dashboard_notifier_cold_boot_test.dart
# -> 14/14 pass
```

---

## Baseline failure snapshot

Per the "Audit Baseline Test Snapshot" doctrine: `test/shift_dashboard_empty_state_widget_test.dart` fails 3/4 on master (asserts "No shifts or history found. Load demo data or connect a source." copy that no longer renders in the no-data path). Verified by stashing my diff and re-running on clean `origin/master` — identical failures with identical line numbers. Not in `docs/KNOWN_FAILING_TESTS.md` but unrelated to Slice 4 — no shift dashboard widget tree touched in that test's path. Out of scope for this slice; flagging here for orchestrator triage.

---

## Risks / follow-ups

1. **Existing per-period blended wage from `ServicePeriodAccumulator.blendedWage` is now unused at the renderer.** The getter on `ServicePeriodAccumulator` (lines 122-126) computes a per-period blended wage from per-period wage dollars / per-period minutes. Slice 4 deliberately ignores it (Decisions 11 + 13). Follow-up could deprecate this getter if no other consumer surfaces; orchestrator should grep before removal.
2. **Hours pills don't yet render per-period required-hours targets** ("scheduled / needed / excess" delta from the whole-day Inputs section). The Slice 4 brief explicitly says per-period required hours land in Slice 3's persisted `weekly_plan_snapshot_day_dayparts` table. Today the per-period hours pills render only the actual hours; when Slice 3 ships, a follow-up can extend `_PerPeriodHoursPill` (or replace it with a per-period `_CompactHoursColumn`) to consume the persisted required-hours per period.
3. **No per-period closed-shift `daypartTarget*` stamp consumption yet.** The Slice 4 brief lists `shift_record.daypartTarget*` as a potential read seam for closed shifts. The current implementation reads everything via `profile.daypartFor(servicePeriodKey)` — which is correct for both open and closed shifts when the active cycle is the same as the close-time cycle (the universal case post-Slice-1 demo reseed). For History (Decision 12) where each closed shift may need to be graded against ITS close-time stamp (not the current cycle), a follow-up read seam will need to consult `shift_record.daypartTarget*` directly. Out of scope for Slice 4 (which is the live Shift surface, not History).
4. **Restaurant Blended Wage label in production may want operator review.** Decisions 11 + 13 are clear that wages stay whole-day, but the explicit "RESTAURANT BLENDED WAGE" wording is a copy choice. Operator-web copy review (or an inline tooltip) could be added in a follow-up if launch feedback says the label is too verbose.

---

## Files changed

**Production source (lib/):**

- `lib/screens/shift_dashboard.dart` — `_DaypartScaffoldCard` reshaped (lines 1097-1216); `_DaypartMetricGrid` + `_MetricCell` removed; `_DaypartOutputsSection` (1257-1369), `_DaypartInputsSection` (1377-1485), `_DaypartFohProductivitySection` (1493-1592), `_PerPeriodInputPill` (1602-1681), `_PerPeriodHoursPill` (1689-1740) added; `ActiveTargetProfileDaypart` import (line 10); call site in `_DaypartScaffoldSection.build` updated (1077-1106).
- `lib/state/shift_service_period_notifier.dart` — `_profile` field (`:48-64`), `profile` getter (`:80-89`), `fromBuckets` accepts optional `profile` (`:117-138`), `_load` assigns `_profile` (`:223-225`).

**Tests:**

- `test/screens/shift_dashboard_daypart_card_parity_test.dart` — new file; 3 tests covering closed-shift / open-with-target / open-no-target paths.
- `test/widget/shift_dashboard_daypart_test.dart:173-190` — updated assertion: `12.50` now `findsNWidgets(2)` (CPLH appears in both Inputs section and FOH Productivity header), per-period `$22.50` blended-wage assertion replaced by `RESTAURANT BLENDED WAGE` label assertion.

**Migrations / schema / proxy / browser QA:** none.
