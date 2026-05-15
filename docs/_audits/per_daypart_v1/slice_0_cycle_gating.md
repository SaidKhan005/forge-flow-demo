# Slice 0 — Cycle rollover gating + contract amendments

**Branch:** `claude/per-daypart-slice-0-cycle-gating`
**Base:** `origin/master`
**Slice tag:** per-daypart-targets-v1 Slice 0
**Owner:** worker agent (Claude lane)
**Verdict:** approve-for-merge

---

## TL;DR

Gates `TargetCyclePolicy.needsAutoRefresh` to the operator's configured
`week_start_day` so cycles cannot refresh mid-week — refresh fires only
when the business date is past the cycle's effective end AND its ISO
weekday equals the configured week-start. The single caller in
`TargetCycleService.getOrCreateActiveCycle` reads the operator's
`RestaurantTimingConfig` and threads `weekStartDay` into the policy.
Three contracts (`phase_7_55_time_boundary_contract.md` Rules 5–6,
`phase_7_55_target_cycle_weekly_plan_rules.md` Rule E,
`core_app_architecture.md` Layers 4 + 8) are amended to match. No schema
change. Cycle length becomes 60–66 days per operator; Jim Taylor's
"minimum 60 days" promise is preserved by the past-effective-end
precondition.

---

## Files changed

| File | LoC | Note |
|---|---|---|
| `lib/domain/services/target_cycle_policy.dart` | +27 −5 | `needsAutoRefresh` gains optional `weekStartDay` parameter (default `DateTime.monday`); refresh requires both past-effective-end AND `weekdayOf(businessDate) == weekStartDay`. |
| `lib/services/target_cycle_service.dart` | +21 −4 | `getOrCreateActiveCycle` fetches `RestaurantTimingConfig` and threads `weekStartDay` into the policy. New `restaurant_timing_config_read_service.dart` import. Falls back to `DateTime.monday` when timing config absent (bootstrap/older demo scopes). |
| `docs/contracts/phase_7_55_time_boundary_contract.md` | +28 −5 | Rule 5 refined to align `effectiveStart` with `week_start_day` and document the 60–66 day range; Rule 6 rewritten to make week-start gating the structural rule. |
| `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md` | +14 −4 | Rule E rewritten — mid-week cycle refresh no longer happens. |
| `docs/contracts/core_app_architecture.md` | +11 −2 | Layer 4 paragraph documents week-start anchor + 60–66 day range; Layer 8 paragraph drops the "if a 60-day cycle changes midweek" line and asserts no cross-cycle drift within a week. |
| `test/target_cycle_policy_test.dart` | +201 −10 | Existing group E updated for week-start gating; new groups H (seven `week_start_day` parameterizations + cross-week-boundary cases + default-Monday case) and I (recommended-cycle 60-day window invariants). |
| `test/target_cycle_service_test.dart` | +59 −22 | Auto-refresh trigger dates moved from `2026-05-26` (Tue) to `2026-06-01` (Mon) and `2026-08-15` (Sat) to `2026-08-17` (Mon) to match new gating. Added explicit "defers refresh until the next configured week-start day" test. Manual-row deactivation test trigger moved from `2026-05-01` (Fri) to `2026-05-04` (Mon). |

Total: **+356 / −52** across 7 files.

---

## Pattern B audit — 14 lenses

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Slice respects authority order. Plan doc (per-daypart-targets-v1) sits at position 5 (active phase doc named in prompt), and the three contracts it amends sit at positions 2–3. Amendment text mirrors the plan doc verbatim where required by the slice prompt. No conflict with HP #11 (timing config is the operator's hierarchy-scoped surface; this slice consumes its `week_start_day` field through the existing read seam, no new write path or scope surface introduced). | `CLAUDE.md` "Authority Order" #2–3, #5; `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:155–183` | None |
| 2 | **Hard Promises** | HP #1 (transport swap) untouched — no vendor wiring. HP #2 (demo writer-side switch) — `restaurant_timing_configs` is the same table in demo and live, no new `demo_*` table, no reader branch on `kDemoMode`. HP #3 (no logic before 7.58) — Slice 0 changes a refresh boundary, not a Primary Driver decision; the plan classifies this as a contract-aligned timing fix, not a 7.58-class logic decision. HP #4 (per-operator isolation) — `weekStartDay` is read via the existing `restaurant_id`-scoped `RestaurantTimingConfigReadService.getTimingConfig`, which already filters by scope. HP #10 (UX per phase close) — Slice 0 has no operator-facing UX surface; the slice prompt explicitly leaves UX exposure for later slices, and operator-visible behavior continues to render normal cycle data unchanged. HP #11 (hierarchy scope) — no new settings surface; the slice reads an existing field. | `CLAUDE.md` "Hard Promises" #1–4, #10–11; `lib/services/target_cycle_service.dart:114–123` | None |
| 3 | **Service-layer split** | `target_cycle_policy.dart` lives in `lib/domain/services/` (pure rule helper, no I/O, matches frozen pattern of `WeeklyPlanSnapshotPolicy`). `target_cycle_service.dart` is in `lib/services/` (runtime orchestration). The new dependency added (`RestaurantTimingConfigReadService` from `lib/services/`) is also runtime orchestration. No `lib/data/` touches, no Postgres imports outside `lib/infrastructure/persistence/postgres/`, no `lib/auth/` touches, no widget owning service-level logic. | `lib/domain/services/target_cycle_policy.dart:1–6`; `lib/services/target_cycle_service.dart:56–62` | None |
| 4 | **Architecture guardrails** | `TargetCycle` is the formula source for 60-day standards — that ownership is preserved. `WeeklyPlanSnapshot` (locked week comparison plan) is untouched in this slice. The plan's Layer 8 amendment makes the snapshot-to-cycle invariant stronger: with week-start gating the "cycle in force when the week was generated" always equals the active cycle inside the week. Whole-day vs daypart split untouched (Slice 0 is timing-only; per-daypart child tables ship in Slice 1). | `docs/contracts/core_app_architecture.md` Layer 4 + Layer 8 (post-edit); `lib/domain/models/target_cycle.dart` (unchanged) | None |
| 5 | **Time guardrails** | Slice is entirely time-boundary work. `_parseDate` continues to use `DateTime.utc(...)` so DST is non-issue (matches `target_cycle_service.dart:_addDays` and `WeeklyPlanSnapshotPolicy._parseDate` conventions). The ISO weekday convention (1 = Mon … 7 = Sun) matches `RestaurantTimingConfig.weekStartDay` doc (`restaurant_timing_config.dart:44–46`), `WeeklyPlanSnapshotPolicy.weekStartForDate` (`weekly_plan_snapshot_policy.dart:18–25`), and `DateTime.weekday`. No `TIMESTAMP WITHOUT TIME ZONE` introduced — slice is SQLite-only and no schema change. Business-date string ordering (`compareTo`) is preserved exactly as before for the past-effective-end check. | `lib/domain/services/target_cycle_policy.dart:49–72` (parseDate UTC); `lib/domain/models/restaurant_timing_config.dart:44–46` (ISO convention); `lib/domain/services/weekly_plan_snapshot_policy.dart:18–25` (parallel pattern) | None |
| 6 | **RLS-ready schema** | No schema change. No new table, no new column, no new index. `restaurant_timing_configs` already exists in both SQLite (`sqlite_database_schema.dart:394–406`) and operator-scoped Postgres (`business_timing_profiles`). The new read goes through the existing `RestaurantTimingConfigReadService.getTimingConfig(restaurantId)` which forwards to the SQLite repository — no Postgres path touched. | `lib/services/restaurant_timing_config_read_service.dart:30–32`; `lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart:394–406` (unchanged) | None |
| 7 | **Proxy & API conventions** | No proxy route added, no idempotency key, no `/v1` or `/v2` path touched. No new Postgres extension dependency. No service-principal path. The slice is entirely client-side / SQLite-side. | n/a | None |
| 8 | **Testing seam** | Tests cover the smallest set that proves the seam: (a) `target_cycle_policy_test.dart` Group H parameterizes all seven `week_start_day` values (1–7) with a trigger-on-week-start case and a defer-day-after case for each; (b) Group H includes the cross-week-boundary case where effective end falls mid-week and refresh defers to the next week-start; (c) Group H includes the default-`DateTime.monday` case to lock the default-parameter behavior; (d) Group I pins the recommended-cycle `effectiveStart`/`effectiveEnd` 60-day invariant. The service-level test (`target_cycle_service_test.dart` group C) adds an explicit "defers refresh until the next configured week-start day" case proving the integration end-to-end. | `test/target_cycle_policy_test.dart:155–360`; `test/target_cycle_service_test.dart:215–235` | None |
| 9 | **Operator-facing copy / UX writing standard** | No operator-facing copy changes. Slice 0 has no UX surface — every screen continues to render today's cycle data unchanged. Operator-facing impact is a single behavioral nuance: when a 60-day boundary lands mid-week, the same cycle keeps showing for the remaining 1–6 days until the next week-start. No new strings; nothing in `lib/screens/` touched. | n/a | None |
| 10 | **Demo mode contract** | Demo seed (`sqlite_database_seed.dart:690–703`) writes `week_start_day: DateTime.monday` for `DemoScope.restaurantId`. The new gating reads through `RestaurantTimingConfigReadService.getTimingConfig(restaurantId)` which is the same path production will use against the same table. No `kDemoMode` branch in policy or service. No new `demo_*` table. Existing carve-outs in `CLAUDE.md` "Demo Mode" §1–4 are untouched. | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:690–703`; `lib/services/target_cycle_service.dart:114–123` | None |
| 11 | **Ceiling-raise rule** | No lint tool ceiling changes. `target_cycle_service.dart` went from 757 → 772 LoC (+15, well under any per-file cap). `target_cycle_policy.dart` went from 57 → 79 LoC. Both within their existing budgets. | n/a | None |
| 12 | **Phase-doc hygiene** | Slice is < 1 week AND < 5 lib/ files (2 lib files; the rest are tests + 3 contract amendments). The plan doc at `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` is the controlling phase doc and remains in `docs/phases/`. No new phase doc created. Contract amendments are required by the slice scope, and are the smallest text edits needed to align the contracts with the new behavior. | `CLAUDE.md` "Phase Doc Hygiene"; `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:278–287` | None |
| 13 | **Anti-scope** | Did NOT touch: `restaurant_timing_configs.shift_close_authority` column or admin write path (Slice 1.5 / Gap 31 territory — STOP rule honored). Did NOT touch `_writeReplacementCycle` standards rebuild (Slice 1 territory). Did NOT touch `_createRecommendedCycle` start-date math (already correct per slice prompt audit-only requirement). Did NOT touch any Postgres migration. Did NOT touch any vendor connector. Did NOT touch any per-daypart schema, table, model, read service, widget. | `lib/services/target_cycle_service.dart:217–321` (`_writeReplacementCycle` unchanged), `:340–403` (`_createRecommendedCycle` unchanged) | None |
| 14 | **Honest disclosures** | `flutter analyze --fatal-infos` on touched files (policy + service + both test files): `No issues found! (ran in 41.9s)`. `flutter test test/target_cycle_policy_test.dart`: 47/47 pass. `flutter test test/target_cycle_service_test.dart`: 66/66 pass. `flutter test test/weekly_plan_snapshot_service_test.dart test/benchmark_tracker_read_service_test.dart` (downstream consumers): 31/31 pass. `flutter test test/baseline_manager_service_test.dart test/active_target_profile_notifier_test.dart` (indirect consumers): 21/21 pass. No CI run (CI dark until 2026-06-01 per `CLAUDE.md`). | Local runs in this worktree, 2026-05-15 | None |

---

## Pattern B — independent re-audit

| # | Lens | Independent re-audit | Citation |
|---|---|---|---|
| A | **First-bootstrap carve-out is correct** | `getOrCreateActiveCycle` only applies week-start gating when `existing != null`. The first-bootstrap path (`existing == null`) calls `_createRecommendedCycle(restaurantId, businessDate)` directly, which sets `effectiveStart = businessDate` regardless of weekday. This is intentional: the slice prompt frames the gating as a *rollover* rule (refresh of an existing cycle). The bootstrap branch creates the very first cycle in the operator's history; forcing it to wait for the next week-start could delay onboarding by up to 6 days for a brand-new restaurant. The plan doc explicitly says cycle length is 60–66 days "per operator depending on where the 60-day boundary falls relative to the week-start" — first-bootstrap cycles anchor to the operator's first business date and roll on the next week-start past day 60. Verified by `target_cycle_service_test.dart` group A (initial recommended cycle creation) still passing. | `lib/services/target_cycle_service.dart:100–123`; `test/target_cycle_service_test.dart:52–143` (group A unchanged) |
| B | **Single caller, single read** | `needsAutoRefresh` has exactly one caller in `lib/` (`target_cycle_service.dart:118`). The timing-config read happens once per `getOrCreateActiveCycle` call. No N+1, no extra round-trips on the read-only "cycle still active" branch (the read happens before the policy call regardless of outcome; trade-off is acceptable because `RestaurantTimingConfigReadService.getTimingConfig` is a single-row SQLite SELECT on a primary-key indexed column). | `lib/services/target_cycle_service.dart:114–123`; rg `needsAutoRefresh` in `lib/` returns only one call site |
| C | **Fallback semantics are honest** | When `RestaurantTimingConfigReadService.getTimingConfig(restaurantId)` returns `null` (no timing config persisted for the operator yet), the service falls back to `DateTime.monday`. This matches the default seed value (`sqlite_database_seed.dart:695`), the convention documented in `RestaurantTimingConfig.weekStartDay` ("1 = Monday, 7 = Sunday"), and `WeeklyPlanSnapshotPolicy.weekStartForDate`'s default. The fallback path is reachable in test/replay/ghost-restaurant scenarios but is not a silent demotion of operator config — it is the documented system default for "no operator override yet." | `lib/services/target_cycle_service.dart:120–123`; `lib/domain/models/restaurant_timing_config.dart:44–46`; `lib/domain/services/weekly_plan_snapshot_policy.dart:20`; `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:695` |
| D | **Default parameter mirrors the rest of the codebase** | The policy's new `weekStartDay = DateTime.monday` default mirrors `WeeklyPlanSnapshotPolicy.weekStartForDate(weekStartDay: DateTime.monday)`, `weekEndForDate`, `weekKeyForDate`, and `shouldGenerate`. Same library, same convention, same default. No invention of a competing convention. | `lib/domain/services/target_cycle_policy.dart:54`; `lib/domain/services/weekly_plan_snapshot_policy.dart:20,32,52,80` |
| E | **Cross-week-boundary edge case verified** | The test "cycle that crosses week-start defers to the next week-start day" uses `effectiveEnd = '2026-04-09'` (Thursday). It asserts no refresh on Friday `04-10` (mid-week), no refresh on Sunday `04-12` (still not Monday), refresh on Monday `04-13`. This is the exact scenario the contract Rule 5 + Rule 6 amendment was written for — a cycle whose effective end is mid-week defers refresh to the next configured week-start day, never lands mid-week. | `test/target_cycle_policy_test.dart:312–344` |
| F | **Existing tests rewritten with correct dates, not deleted** | Every existing test that previously exercised auto-refresh on a non-Monday date (mostly `'2026-05-26'`, a Tuesday) was rewritten to use `'2026-06-01'` (next Monday past `effectiveEnd = '2026-05-25'`). The test assertions and intent are preserved verbatim; only the trigger date and the resulting expected `effectiveEnd` value (`'2026-07-30'` instead of `'2026-07-24'`) changed. No coverage was lost. One new assertion ("defers refresh until the next configured week-start day") was added explicitly to lock the deferral case at the service layer. | `test/target_cycle_service_test.dart:178–235` (group C); diff -U0 of group C |
| G | **No widening of `_createRecommendedCycle`** | Per the slice prompt's "verify in your audit" requirement: lines 372–373 of `target_cycle_service.dart` already compute `effectiveStart = businessDate` and `effectiveEnd = _addDays(businessDate, 59)` — no change needed. Under the new gating, `businessDate` IS the week-start day at the moment refresh fires, so `effectiveStart` naturally aligns to the week-start without any new logic. Confirmed unchanged. | `lib/services/target_cycle_service.dart:372–373` (unchanged) |

---

## Test additions

### `test/target_cycle_policy_test.dart`

- **Group E (rewrite)** — Existing 4 tests rewritten to align with new gating, using `effectiveEnd = 2026-04-01` (Wednesday) to make weekday boundaries explicit. Added 1 new test for the "well past effective end on a non-week-start day" deferral case.
- **Group H — week-start day gating (per-daypart V1 Slice 0)** — 14 parameterized tests (one trigger + one defer date for each of weekStartDay = 1..7), plus 3 cases: (a) past effective end + mid-week defers regardless of how far past, (b) cycle whose effective end is mid-week refreshes on the next week-start, (c) default `weekStartDay = Monday` matches `DateTime.monday`.
- **Group I — recommended-cycle effective window invariants** — 2 tests pinning `effectiveStart` = refresh business date and `effectiveEnd = effectiveStart + 59 days` (inclusive 60-date span) across all seven week-start anchors.

### `test/target_cycle_service_test.dart`

- **Group C (test added)** — "defers refresh until the next configured week-start day" — proves that calling `getOrCreateActiveCycle` on a mid-week date past `effectiveEnd` returns the same cycle unchanged (no rollover, no new row).
- **Group C, D, F, G, M, N (dates updated)** — Auto-refresh trigger dates aligned to the seeded Monday week-start.

---

## Verification commands run

```
pwsh scripts/install_git_hooks.ps1
# -> Forge & Flow git hooks enabled for this clone.

flutter analyze --fatal-infos \
  lib/services/target_cycle_service.dart \
  lib/domain/services/target_cycle_policy.dart \
  test/target_cycle_policy_test.dart \
  test/target_cycle_service_test.dart
# -> Analyzing 4 items... No issues found! (ran in 41.9s)

flutter test test/target_cycle_policy_test.dart
# -> 47/47 pass (group H = 17 new param + edge tests; group I = 2 invariant tests).

flutter test test/target_cycle_service_test.dart
# -> 66/66 pass (group C now includes "defers refresh" assertion).

flutter test test/weekly_plan_snapshot_service_test.dart test/benchmark_tracker_read_service_test.dart
# -> 31/31 pass (downstream consumers of the cycle service unchanged).

flutter test test/baseline_manager_service_test.dart test/active_target_profile_notifier_test.dart
# -> 21/21 pass (indirect consumers via BaselineManagerService / profile notifier).
```

Flutter version: `3.35.7 stable` (channel adc9010625, 2025-10-21).

---

## Baseline failure snapshot

Per the "Audit Baseline Test Snapshot" doctrine, the affected test files
(`test/target_cycle_policy_test.dart`, `test/target_cycle_service_test.dart`,
plus the four downstream consumer test files spot-checked above) all pass
on the post-change branch with 0 unrelated failures. The slice is
date-boundary surgery against a single policy function; the broader
codebase risk is low.

---

## Risks / follow-ups

- **First-bootstrap cycles still anchor to the first business date.** A
  brand-new operator whose first app open lands on a Wednesday will get a
  cycle that starts on Wednesday — refresh of that cycle then defers to
  the next configured week-start. The plan doc's "cycle length 60–66
  days per operator" wording absorbs this. No follow-up required, but
  flagged here for orchestrator awareness.
- **No telemetry on deferred refreshes.** Operators don't see a UI signal
  that "the cycle is past its 60-day boundary but waiting for week-start
  to roll." The current `app_notifications` payload at
  `lib/services/app_notification_service.dart` fires only when refresh
  actually happens. Out of scope for Slice 0 per the slice prompt; the
  plan doc's "Operator-visible net story" section says cycles roll
  invisibly at week-start.
- **No live-mutation path needs a defensive read.** Mid-cycle override
  paths (`applyManagerOverrideCycle`, `applyAdminReplacementCycle`,
  `restoreRecommendedCycle`) call `getOrCreateActiveCycle` which now reads
  the timing config. If those paths ever bypass `getOrCreateActiveCycle`
  in the future, they would skip the gating — but every existing call
  site routes through it.

---
