# Slice 5 — Variance read-seam swap (per-period)

**Branch:** `claude/per-daypart-slice-5-variance-read`
**Base:** `master`
**Slice tag:** per-daypart-targets-v1 Slice 5
**Owner:** worker agent (Claude lane)
**Verdict:** approve-for-merge (worker self-audit; orchestrator audits independently)

---

## TL;DR

Swaps the WTD / Full-Week-Projection variance card's theoretical-%
read seam from the whole-day pool scalar to per-period. For non-closed
rows, `VarianceWeekProjectionReadService._theoreticalPctForRow` now
reads `currentTargetProfile.daypartTheoreticalLaborPctFor(row.daypart)`
— a new read-only accessor on `ActiveTargetProfile` that derives the
period's theoretical % from the period row's rate targets and the
profile's whole-day wages (wages stay whole-day, Design Rule 5). When
the active cycle wrote no per-period row for that period (Gap 42
insufficient-data fallback) the accessor returns `null` and the seam
falls back to the whole-day pool `theoreticalLaborPct` exactly as
before — never a `0` sentinel (Design Rule 2). Closed rows are
untouched (Rule 4 locked-stamp exception). `_laborDollarsForRow` is
unchanged (wages have no per-period variant, plan line 344). No UX
change — the layout stays visually flat (Option B); only the variance
math underneath becomes period-accurate (Gap 7 resolved). The period
set + sort order continue to come from the operator's persisted
`servicePeriodDefinitions` (timing config), never hardcoded.

---

## Files changed

| File | LoC | Note |
|---|---|---|
| `lib/domain/models/active_target_profile.dart` | +38 | New read-only `daypartTheoreticalLaborPctFor(servicePeriodId)` accessor: returns `null` when no per-period row (Gap 42 / Design Rule 2), else derives `fohPct + bohPct` from the period row's rate targets and the profile's whole-day wages using the same canonical formula as `build()`. Preserves the legacy `0.0` divide-by-zero boundary for a present-but-degenerate row (parity with the whole-day scalar; broader sentinel follow-up still tracked against `build`). `daypart`-prefixed name satisfies Design Rule 1. |
| `lib/services/variance_week_projection_read_service.dart` | +35 −4 | `_theoreticalPctForRow`: non-closed rows now read `currentTargetProfile.daypartTheoreticalLaborPctFor(row.daypart) ?? currentTargetProfile.theoreticalLaborPct`. Closed rows + `currentTargetProfile == null` path unchanged. Class + method docstrings updated for the Slice 5 seam swap. No write path touched. |
| `test/active_target_profile_dayparts_test.dart` | +94 | New group `ActiveTargetProfile.daypartTheoreticalLaborPctFor`: (a) null when no per-period row (Gap 42); (b) per-period derivation matches `build()` formula AND differs from the whole-day pool scalar (proves genuinely per-period) + unknown-id → null; (c) present-but-degenerate row keeps the legacy `0.0` boundary (parity, not a new sentinel). |
| `test/variance_week_projection_read_service_test.dart` | +196 | New group `Q — per-period variance read-seam (Slice 5 / Gap 7)`: single-period non-closed day reads period %; mixed-period day weights each row by its own period %; **empty `dayparts` → whole-day pool fallback (Gap 42, asserts not 0)**; period present for one row + absent for another → independent per-row fallback; closed rows keep locked stamp (Rule 4). |

Total: **+359 / −4** across 4 files (2 lib, 2 test).

---

## Verification (CI dark — local commands disclosed)

Toolchain: Dart SDK 3.9.2 stable, Flutter (worktree-isolated; ran
`flutter pub get` first — the fresh worktree had no
`.dart_tool/package_config.json`, which initially made `dart analyze`
report stale `undefined_method` on the new accessor; resolved after
pub get).

```
dart analyze lib/domain/models/active_target_profile.dart \
  lib/services/variance_week_projection_read_service.dart \
  test/active_target_profile_dayparts_test.dart \
  test/variance_week_projection_read_service_test.dart
=> No issues found!

flutter test test/active_target_profile_dayparts_test.dart \
  test/variance_week_projection_read_service_test.dart
=> All tests passed!  (55 tests: 8 new + all pre-existing variance/profile tests green)

flutter test test/variance_visual_widget_test.dart
=> All tests passed!  (21 tests — nearest variance widget test, unchanged behaviour)

flutter test test/target_snapshot_builder_test.dart
=> All tests passed!  (1 test — nearest consumer of the same model, unaffected)
```

Pre-PR baseline: the new accessor + seam are additive; the only
pre-existing tests that exercise `_theoreticalPctForRow` with a
profile (`L — 7.55q.4 currentTargetProfile rewires...`) pass a profile
with **no** `dayparts`, so they exercise the Gap 42 fallback and stay
green (whole-day pool path is byte-for-byte the prior behaviour). No
regressions introduced; no pre-existing failures masked.

---

## Pattern B audit — 14 lenses

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Slice respects authority order. Plan doc sits at position 5; its Slice 5 section (`per_daypart_targets_v1_plan.md:341-346`) and Gap 7 row (`:374`) are the controlling scope. The plan text says read `currentTargetProfile.daypartFor(row.daypart).theoreticalLaborPct`; `ActiveTargetProfileDaypart` carries only rate/OPZ fields (no `theoreticalLaborPct`) since Slice 1, so the intent is realized via the new derived accessor using the same canonical formula as `ActiveTargetProfile.build` + Slice 1's weekly-plan path (`slice_1_per_period_data_foundation.md:115-118`). No contract conflict. | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:341-346,374`; `lib/domain/models/active_target_profile.dart:137-159` | None |
| 2 | **Hard Promises** | HP #1 (transport swap) untouched — no vendor wiring. HP #2 (demo writer-side switch) — no `kDemoMode` branch, no `demo_*` table, reads the same `ActiveTargetProfile` in demo + live. HP #3 (no logic before 7.58) — this is a read-seam swap that makes existing variance math period-accurate; it decides no Primary Driver. HP #4 (per-operator isolation) — accessor reads only fields already on the scoped profile; no new fetch. HP #6 (advisor recommends) — n/a. HP #10 (UX per phase close) — Option B, no UX surface change; numbers become accurate underneath, layout flat. HP #11 (hierarchy scope) — period set + sort come from operator `servicePeriodDefinitions` (timing config), not hardcoded; no new settings surface. | `CLAUDE.md` "Hard Promises" #1-4,#10-11; `lib/services/variance_week_projection_read_service.dart:235-245` | None |
| 3 | **Service-layer split** | `active_target_profile.dart` is in `lib/domain/models/` (pure model + pure derived getter, no I/O). `variance_week_projection_read_service.dart` is in `lib/services/` (runtime orchestration). No `lib/data/` touch, no Postgres import outside `infrastructure/persistence/postgres/`, no `lib/auth/` touch, no widget owning service logic. | `lib/domain/models/active_target_profile.dart:1-20`; `lib/services/variance_week_projection_read_service.dart:1-22` | None |
| 4 | **Architecture guardrails** | `LaborModel`/`TargetCycle`/`WeeklyPlanSnapshot` ownership untouched. Source facts vs derived metrics stays separated — the accessor is a pure derived view over the already-locked `ActiveTargetProfile`; no widget owns source-truth. Shift whole-day authority untouched (Slice 4 territory). The whole-day pool remains the cover-weighted rollup; this slice only changes which scalar a non-closed variance row reads, honestly preferring the period scope and falling back to the pool. | `lib/domain/models/active_target_profile.dart:142-153`; `lib/services/variance_week_projection_read_service.dart:235-245` | None |
| 5 | **Time guardrails** | No timestamp/business-date code touched. No `TIMESTAMP WITHOUT TIME ZONE`. Period resolution still flows through `servicePeriodDefinitions` / `ServicePeriodDefinitionResolver` (restaurant-local timing), unchanged. `row.daypart` is the shift's resolved service-period key (saved timing identity or `shift.daypart`) via `ClosedTimingLabelResolver.bucketKeyFor` — the same key Slice 1 stamps `ActiveTargetProfile.dayparts` under (`target_cycle_service.dart:580-605`), so the join is key-consistent. | `lib/services/closed_timing_label_resolver.dart:46-51`; `lib/services/target_cycle_service.dart:580-605` | None |
| 6 | **RLS-ready schema** | No schema change. No table, column, index, or migration. Pure in-memory derivation over an already-fetched scoped profile. No Postgres path. | n/a | None |
| 7 | **Proxy & API conventions** | No proxy route, no idempotency key, no `/v1`/`/v2` path, no service-principal path, no AI surface. Entirely client-side read math. | n/a | None |
| 8 | **Testing seam** | Smallest set proving the seam: model-level (null on no row / formula parity & differs-from-pool / degenerate-row 0.0 parity) + service-level (single-period read-back, mixed-period independent weighting, **empty-`dayparts` whole-day fallback asserting not 0**, mixed present/absent independent per-row fallback, closed-row Rule-4 invariance). Both required tests (per-period read-back + empty-`dayparts` fallback) present and green; total 8 new, all 55 in the two files pass; nearest variance widget + model-consumer tests green. | `test/variance_week_projection_read_service_test.dart` group Q; `test/active_target_profile_dayparts_test.dart` group `daypartTheoreticalLaborPctFor` | None |
| 9 | **Operator-facing copy / UX writing standard** | No copy changes, no new strings, nothing in `lib/screens/` touched. Option B honored — the variance card layout is unchanged; the only operator-visible effect is more accurate variance points on non-closed rows when the active cycle has per-period standards. | n/a | None |
| 10 | **Demo mode contract** | No `kDemoMode` branch, no `demo_*` table, no reader fork. Demo + live both read the same `ActiveTargetProfile`; the demo path simply has per-period `dayparts` once Slice 1's reseed populated them, and falls back to the pool when it didn't (same code path either way). Existing carve-outs untouched. | `lib/services/variance_week_projection_read_service.dart:235-245`; `CLAUDE.md` "Demo Mode" | None |
| 11 | **Ceiling-raise rule** | No lint-tool ceiling changed. `active_target_profile.dart` 281 → 319 LoC; `variance_week_projection_read_service.dart` 307 → ~342 LoC. Both small, well under any per-file cap; no `kAdvisorProxyMaxLines`-class raise. | n/a | None |
| 12 | **Phase-doc hygiene** | Slice is < 1 week AND < 5 lib files (2 lib, 2 test). Controlling phase doc (`per_daypart_targets_v1_plan.md`) stays in `docs/phases/`. No new phase doc; no contract change needed (the plan text's `.theoreticalLaborPct` shorthand is realized via the derived accessor — documented in the accessor docstring and lens 1). Audit doc filed at the prompt-specified path. | `CLAUDE.md` "Phase Doc Hygiene"; `docs/_audits/per_daypart_v1/slice_5_variance_read_seam.md` | None |
| 13 | **Anti-scope** | Did NOT touch `target_cycle_service.dart`, `weekly_plan_snapshot_service.dart`, `data_alignment_audit_read_service.dart`, shift card widgets, `lib/screens/benchmark*`, `lib/screens/plan_*`, `schedule_builder*`, or vendor sinks (concurrency STOP list honored). Did NOT touch `_laborDollarsForRow` (wages stay whole-day — plan line 344). Did NOT touch closed-row behaviour (Rule 4). Did NOT change the legacy `build()` `0.0`-vs-`null` sentinel (read-only Slice 5, Design Rule 4; follow-up still owned by the `build` site). Did NOT add a write path or a parallel stack. | `git diff --stat` (4 files: 2 lib + 2 test only); `lib/services/variance_week_projection_read_service.dart:290-306` (`_laborDollarsForRow` unchanged) | None |
| 14 | **Design Rules (Slice-specific)** | Rule 1 — per-period accessor is `daypart`-prefixed (`daypartTheoreticalLaborPctFor`); a caller cannot substitute the whole-day scalar without changing the call site. Rule 2 — missing per-period row → `null`, caller falls back to whole-day pool; tests assert the fallback is the pool, never `0`. Rule 4 — read-only; the canonical cycle/profile write path is untouched. Rule 5 — wages stay whole-day; the per-period % uses the profile's whole-day `fohWage`/`bohWage` with per-period rate targets only; `_laborDollarsForRow` unchanged. | `lib/domain/models/active_target_profile.dart:142-153`; `test/variance_week_projection_read_service_test.dart` group Q | None |

---

## Open items / follow-ups

- **Whole-day `0.0`-vs-`null` sentinel (pre-existing, out of scope):**
  `ActiveTargetProfile.build` still returns `0.0` for a degenerate
  whole-day profile (`active_target_profile.dart:137-140`). Slice 5's
  new accessor deliberately mirrors that boundary for a
  present-but-degenerate *period* row (parity, not a new sentinel) and
  flags it in its docstring. The broader nullable-everywhere change
  remains owned by the Slice 1 audit follow-up against the `build`
  site (`slice_1_per_period_data_foundation.md:241`). No action needed
  in this slice.

- None blocking. Verdict: **approve-for-merge** pending orchestrator
  independent audit.
