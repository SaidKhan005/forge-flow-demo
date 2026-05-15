# Regression test — Slice 1.5 late-night crossing (intent lock)

**Branch:** `claude2/slice-1-5-regression-test-late-night-crossing`
**Base:** `master` (`88a13ebe`)
**Slice tag:** Per-Daypart Targets V1 — Slice 1.5 deferred regression test
**Owner:** worker agent (Claude 2 lane)
**Verdict:** approve-for-merge — pure-additive tests, no production code touched

---

## TL;DR

Locks the operator's stated late-night-crossing-midnight scenario into the aggregator regression-test suite as a deferred follow-up to PR #763 (Slice 1.5, merged 2026-05-15 at `d392d4d1`). One test file extended with a new group `P. Operator business-hours scenario — 23:00 Tue → 03:30 Wed (intent lock)` containing four sub-tests (P.1 POS check at both period endpoints, P.2 labor punch with non_service tail, P.3 reservation, P.4 composite). 624 lines of test code added. Zero lines of production code touched. All 33 tests in the file pass locally (29 pre-existing + 4 new).

---

## Scope

| What | Where |
|---|---|
| Group P regression tests (P.1–P.4) | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2218–2841` (624 LoC added) |
| This audit doc | `docs/_audits/per_daypart_v1/regression_test_slice_1_5_late_night_crossing.md` (new) |
| **Untouched** | All `lib/`, `tool/`, `db/migrations/`, all other test files, all trackers / ledgers / plan / brief / phase docs / index docs |

**Public API:** none changed. Pure test addition.

**Operator-facing copy:** none added.

---

## 14-lens audit (Pattern B — worker self-audit)

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Test scenario mirrors verbatim the operator's stated configuration in `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` §"End-to-end verification 2026-05-15 (post-Slice-1.5 merge)" — `business_day_start_local_time = '04:00'`, IANA `America/Toronto`, Late Night `22:00–02:00 rollsPastMidnight=true`, FOH punch 23:00 Tue → 03:30 Wed, POS check at 01:30 Wed, reservation at 01:30 Wed → all attribute to Tuesday business date / `late_night` daypart. The 02:00 Wed → 03:30 Wed sliver is a `non_service` segment excluded from per-period CPLH/SPLH denominators per the Jim Taylor rule. Honors `core_app_architecture.md` Promise 3 ("Live canonical POS/labor/reservation facts must be bucketed into the effective configured service periods first") and Layer 9 ("Whole Day rolls up from service-period buckets"). | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:488–497`; `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2218–2266` (Group P preamble) | None |
| 2 | **Hard Promises** | HP #1 (Phase 8 transport-only): no transport touched. HP #2 (kDemoMode = writer-side switch): no reader-side branch added; tests assert behavior identically across demo and prod paths. **HP #3 (No app logic before 7.58): IMPORTANT — this PR adds no app logic. It is a regression-test-only slice.** HP #4 (Per-operator isolation): tests use the same `withTenant`/`OperatorScopedRepository` seam as existing tests via `_FakePool` + `TenantTransactionWrapper`. HP #11 (Hierarchy-scoped settings): no settings touched. | `CLAUDE.md` "Hard Promises" #1, #2, #3, #4, #11; `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2308, 2479, 2658, 2772` (every aggregator call goes through `TenantTransactionWrapper(pool)` like the existing tests) | None |
| 3 | **Service-layer split** | No new files. No imports added. Tests reuse the existing imports (`DaypartBucketer`, `BucketingPosLine`, `BucketingLaborPunch`, `BucketingReservation`, `ServicePeriodDefinition`, `Daypart`, `CanonicalFactToClosedShiftInputAggregator`, `TenantTransactionWrapper`, `ReservationWalkInOverride`) from the existing test file. No `package:postgres` direct imports. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:35–46` (existing imports unchanged) | None |
| 4 | **Architecture guardrails** | `LaborModel` / `TargetCycle` / `WeeklyPlanSnapshot` untouched. `ActiveTargetProfile` untouched. The aggregator under test was not modified. The test exercises the canonical seams as-is — `_FakePool.seedLocation` writes the operator's `(timezone='America/Toronto', business_day_rollover_hour=4)` truth so the aggregator's `_readLocationMeta` derives `businessDayStartLocalTime='04:00'` per the production code path. Closed-shift truth not retroactively rewritten. | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:222–238` (production seam — unchanged); `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2261–2266` (test setup matches the production seam) | None |
| 5 | **Time guardrails** | All test instants are explicit `DateTime.utc(...)` constants — no `DateTime.now()`. Anchor business date `2026-05-12` is mid-EDT (DST 2026 starts 2026-03-08, ends 2026-11-01 in `America/Toronto`) so DST does not trip the test. Local→UTC mapping documented inline in the group preamble. Each instant carries the EDT offset of UTC-4 explicitly: `23:00 Tue local = 03:00 Wed UTC = DateTime.utc(2026, 5, 13, 3, 0, 0)`. No `TIMESTAMP WITHOUT TIME ZONE` introduced. Cross-date instants exercise the operator's cutoff (`04:00`) at the boundary — `01:30 Wed local < 04:00 cutoff → resolves to Tuesday business date`. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2240–2245` (mapping comment); `:2306–2308` (P.1 instants); `:2447–2448` (P.2 instants); `:2638` (P.3 instant) | None |
| 6 | **RLS-ready schema** | No schema touched. Tests inject tenancy via `TenantTransactionWrapper(pool)` — same path as existing tests. The Pattern B "L. RLS + tenancy injection" group's behavior is not weakened. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2330, 2485, 2668, 2790` | None |
| 7 | **Proxy & API conventions** | No proxy touched. No new routes. No idempotency keys. | n/a | None |
| 8 | **Testing seam** | Four sub-tests under group P, each ratcheting one regression scope of the operator's stated scenario:<br>**P.1** — `:2305–2443`. Sub-case A asserts a POS check at `closed_at = 23:00 Tue local` surfaces to the Tuesday `late_night` aggregator call (covers stage 2 returns 6 covers; `result.input.daypart == 'late_night'`; `result.input.businessDate == Tuesday`). Sub-case B asserts the same for `closed_at = 01:30 Wed local` (post-midnight, pre-cutoff). Sub-case C asserts `DaypartBucketer.bucketPosLine` directly returns `'late_night'` for both local instants — locks the canonical bucketer's behavior independent of the aggregator wiring. **Rules out:** future regressions of (a) the half-open vs inclusive boundary semantics that Slice 1.5 fixed via Gap 20, (b) the cutoff-aware business-date resolution at 01:30 Wed local, (c) the rolls-past-midnight period-interval construction.<br>**P.2** — `:2445–2634`. Sub-assertion (a) `:2475–2520` proxies `_businessDatesSpanning`: a Wednesday-business-date aggregator call with the same Tue-anchored punch sees ZERO `actualFohHours` because the punch's segments do not bleed onto Wednesday. Sub-assertion (b) `:2521–2600` asserts `actualFohHours == 3` (180 min late_night, NOT 4 from the rounded 270 min that would include the gap). Sub-assertion (c) `:2588–2600` asserts `actualFohLaborDollars == 3 × 22 = 66.0` — proves the Jim Taylor non_service exclusion flowed through to dollars. Sub-assertion (d) `:2602–2634` calls `DaypartBucketer.bucketLaborPunch` directly and asserts the segment shape: one `late_night` segment of 180 min `[Tue 23:00, Wed 02:00)` plus one `non_service` segment of 90 min `[Wed 02:00, Wed 03:30)` with `servicePeriodId == null` (the canonical sentinel per `LaborPunchSegment`). **Rules out:** future regressions of (a) Gap 21 (Promise 3 per-period interval splitting), (b) Gap 26 (cross-(business-date) punch attribution), (c) the Jim Taylor non_service exclusion in CPLH/SPLH denominators, (d) the `LaborPunchSegment.servicePeriodId == null` non_service sentinel.<br>**P.3** — `:2636–2717`. Asserts a reservation at `01:30 Wed local` with `business_date = Tuesday` and `seated_at = null` (Tock-shape) buckets to Tuesday `late_night` via stage 3 covers resolution (Pattern A: seated party_size + walk-in count). Direct `DaypartBucketer.bucketReservation` assertion locks the canonical reservation bucketing for the same instant. **Rules out:** future regressions of `_readReservationFactsForDaypart`'s post-filter via `bucketReservation`, the SEATED status filter, and the cutoff-aware business-date resolution for reservations.<br>**P.4** — `:2719–2839`. Composite scenario with all three facts present (POS 6+4 covers, FOH punch 4.5h crossing the boundary, reservation 4 seated). Asserts ONE `ClosedShiftInput` row keyed `(Tuesday, late_night)` with: `covers == 10` (POS sum, stage 2 wins), `actualSales == 300.0` (POS sum), `actualFohHours == 3` (180 min late_night, gap excluded), `actualFohLaborDollars == 66.0` (per-period rate × hours), `sourceSystem == 'oracle_micros_simphony'`, `coversProvenance == 'vendor_oracle_micros_simphony'`, `laborDollarsProvenance == 'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates'`, `closeAuthorityProvenance == 'vendor_oracle_micros_simphony_reliable_finalization'`. **Rules out:** future regressions of the end-to-end aggregator output for the operator's stated scenario, including the Slice 1.5 close-authority auto-derive on a reliable POS vendor. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2305–2443` (P.1); `:2445–2634` (P.2); `:2636–2717` (P.3); `:2719–2839` (P.4) | None |
| 9 | **Operator-facing copy / UX writing standard** | No copy added. No UX surface touched. Test names + comments use the same vocabulary as the plan doc (`Late Night`, `late_night`, `non_service`, `business date`, `cutoff`). | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2247–2266` (group title + preamble) | None |
| 10 | **Demo mode contract** | No new `kDemoMode` branch. Tests don't reference `kDemoMode` or `DemoScope`. Same fake pool, same aggregator, same code path demo + prod use. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart` (no `kDemoMode` / `DemoScope` references in the new group) | None |
| 11 | **Ceiling-raise rule** | No lint-tool ceiling raises. Test file grew from 2217 → 2841 LoC; no per-file cap applies to test files. | n/a | None |
| 12 | **Phase-doc hygiene** | Slice is regression-test-only, < 1 day, 1 file. No new phase doc. The deferred-test scope was already documented inline in `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` (paragraph "Deferred regression test"). This PR fulfills that deferral. The plan doc is NOT being updated by this worker (per worker contract — orchestrator owns trackers/plans). | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:496` ("Deferred regression test" paragraph that this PR satisfies) | None |
| 13 | **Anti-scope** | Confirmed via `git diff --stat HEAD` and `git status`: only one production-tree file touched (`test/services/integration/canonical_fact_to_closed_shift_input_test.dart`, +624 LoC) plus this audit doc. Zero `lib/` / `tool/` / `db/migrations/` / `scripts/` files touched. No tracker / ledger / plan / brief / phase doc updated. The existing aggregator test groups A–O were not modified. | `git diff --stat HEAD` shows `1 file changed, 624 insertions(+)` against the test file alone; the audit doc is the second file added (untracked at audit time). | None |
| 14 | **Honest disclosures** | Verification runs in this worktree (Windows 11, PowerShell 5.1, Flutter 3.x via `C:\src\flutter\bin`):<br>`pwsh scripts/install_git_hooks.ps1` → `Forge & Flow git hooks enabled for this clone.`<br>`flutter pub get` → `Got dependencies!` (53 packages have newer versions; OK per env. The `Building with plugins requires symlink support` warning is non-fatal and unrelated to this slice — every Windows worktree without dev-mode symlinks emits it).<br>`dart analyze --fatal-infos test/services/integration/canonical_fact_to_closed_shift_input_test.dart` → `No issues found!` (after fixing one Dart string-interpolation issue: `'$22'` was being parsed as a variable reference; corrected to `'\$22'` in the reason string).<br>`flutter test test/services/integration/canonical_fact_to_closed_shift_input_test.dart` → 33/33 pass (29 pre-existing + 4 new P.1–P.4).<br>**Environment caveat — worktree-path note:** the orchestrator dispatched this worker into the `agent-a57d9191b276c8e67` worktree (PowerShell working directory). The CLAUDE.md context was loaded from the parallel `infallible-tereshkova-6ef5ce` worktree (the harness's project-instructions resolution), but all editing, analyzing, testing, committing, and pushing happen against `agent-a57d9191b276c8e67`. The first edit attempt landed on the wrong worktree; was caught when test count came back at 29 instead of 33; re-applied to the correct worktree and tests pass. No production code involved in this misroute — only this test file and this audit doc. | local runs in `C:\forge-flow-demo\.claude\worktrees\agent-a57d9191b276c8e67`, 2026-05-15 | None |

---

## Pattern B re-audit — operator scenario fidelity check

| # | Operator-stated requirement | Test fidelity | Citation |
|---|---|---|---|
| A | `business_day_start_local_time = '04:00'` | `_FakePool.seedLocation` writes `business_day_rollover_hour: 4` which the aggregator's `_readLocationMeta` formats to `'04:00'` (`lib/services/integration/canonical_fact_to_closed_shift_input.dart:922–928`). The bucketer-direct sub-cases pass `BucketingLocationContext(businessDayStartLocalTime: '04:00')` literally. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2261–2266`, :2330, :2485, :2668, :2790 |
| B | IANA `America/Toronto` | `_FakePool.seedLocation` writes `'timezone': 'America/Toronto'` (existing helper, not modified). Direct bucketer calls pass `iana: 'America/Toronto'`. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2261–2266`; helper at `:2270–2274` (existing) |
| C | Late Night daypart `22:00–02:00 rollsPastMidnight=true` | `lateNightPeriod` const declares `startLocalTime: '22:00'`, `endLocalTime: '02:00'`, `rollsPastMidnight: true`. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2273–2282` |
| D | FOH labor punch `23:00 Tue local → 03:30 Wed local` | `shiftStartUtc = DateTime.utc(2026, 5, 13, 3, 0, 0)` ≡ `23:00 Tue 2026-05-12 EDT (UTC-4)`. `shiftEndUtc = DateTime.utc(2026, 5, 13, 7, 30, 0)` ≡ `03:30 Wed 2026-05-13 EDT`. `role_name: 'server'` → FOH per `_isFohPunch`. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2447–2466` (P.2 setup); `:2740–2754` (P.4 setup) |
| E | POS check closing at `01:30 Wed local` | `oneThirtyWedUtc = DateTime.utc(2026, 5, 13, 5, 30, 0)` ≡ `01:30 Wed EDT`. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2310, 2399`; `:2722` (P.4) |
| F | Reservation seated at `01:30 Wed local` | `reservationAtUtc = DateTime.utc(2026, 5, 13, 5, 30, 0)`. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2641` (P.3); `:2725` (P.4) |
| G | All three facts attribute to Tuesday business date | P.1, P.3 assert `result.input.businessDate == tuesdayBusinessDate (DateTime.utc(2026, 5, 12))`. P.2 sub-(a) proves the inverse — Wednesday call sees ZERO labor minutes. P.4 composite asserts the Tuesday-anchored row. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2358, 2429, 2685, 2799` |
| H | All three facts classify as Late Night daypart | P.1, P.3, P.4 assert `result.input.daypart == 'late_night'`. P.2 sub-(b) proves it via the per-period rollup landing on the late_night call. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2357, 2428, 2684, 2800` |
| I | The 02:00 Wed → 03:30 Wed sliver is `non_service`, excluded from CPLH/SPLH denominators | P.2 sub-(b) asserts `actualFohHours == 3` (NOT 4 from rounded gap-included 270 min). P.2 sub-(c) asserts `actualFohLaborDollars == 66.0` (3h × $22, NOT 4.5h × $22 = $99). P.2 sub-(d) directly asserts `LaborPunchSegment(servicePeriodId: null, minutes: 90)` exists in the bucketer output. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2552–2600, 2602–2634` |

---

## What I ran

```
# 1. Hooks (per worker contract)
& "C:\forge-flow-demo\.claude\worktrees\infallible-tereshkova-6ef5ce\scripts\install_git_hooks.ps1"
# -> Forge & Flow git hooks enabled for this clone.
#    Active hooks: pre-commit, pre-push.

# 2. Branch
git checkout -b claude2/slice-1-5-regression-test-late-night-crossing
# (master is owned by the main worktree, so checked out new branch off the
# already-checked-out base in this worktree — same SHA as master at 88a13ebe)

# 3. Deps
flutter pub get
# -> Got dependencies! (52 packages have newer versions; OK per env.
#    Symlink-support warning is benign on Windows worktrees w/o dev-mode.)

# 4. Analyze (after fixing one '$22' string-interpolation issue → '\$22')
dart analyze --fatal-infos test/services/integration/canonical_fact_to_closed_shift_input_test.dart
# -> No issues found!

# 5. Tests
flutter test test/services/integration/canonical_fact_to_closed_shift_input_test.dart
# -> 33/33 pass:
#    +24..+28 = group O (5 existing Slice 1.5 regressions)
#    +29..+32 = group P (4 new — this PR)
#    +33: All tests passed!

# 6. Diff scope confirmation
git diff --stat HEAD
# -> 1 file changed, 624 insertions(+)
```

---

## Risks / follow-ups

1. **None expected.** This is a pure-additive test. No production behavior changed. No schema, no migration, no proxy, no UI. If a future change to `DaypartBucketer`, `_splitLaborPunchesByPeriod`, `_resolveCovers`, `_readReservationFactsForDaypart`, or the `_isoDate` business-date helper inadvertently regresses any of the locked behaviors, one of the four P sub-tests will fail with a clear message naming the regressed seam.

2. **DST window.** The test scenario is anchored at `2026-05-12` which is mid-EDT in `America/Toronto` (DST starts `2026-03-08`, ends `2026-11-01`). If a future contributor moves the anchor date into a non-DST window, the UTC offset comments in the group preamble will need to update from `UTC-4` to `UTC-5`. The test helper structure (explicit `DateTime.utc(...)` constants) makes this trivially auditable — the tests do not call `DateTime.now()` or any timezone-resolution helper at runtime.

3. **One worktree-path quirk surfaced and resolved.** Documented in Lens 14. Not a code risk; an environment note for future workers operating in this orchestrator setup.

---

## Files changed

**Tests:**

- `test/services/integration/canonical_fact_to_closed_shift_input_test.dart` (+624 LoC; new group P with four sub-tests P.1, P.2, P.3, P.4 plus group preamble comment)

**Audit:**

- `docs/_audits/per_daypart_v1/regression_test_slice_1_5_late_night_crossing.md` (this file; new)

**Production source (lib/, tool/, db/migrations/):** none.
