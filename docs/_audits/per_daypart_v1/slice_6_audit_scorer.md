# Slice 6 — Audit scorer per-period extension

**Branch:** `claude/per-daypart-slice-6-audit-scorer`
**Base:** `master`
**Slice tag:** per-daypart-targets-v1 Slice 6
**Owner:** worker agent (Claude lane)
**Verdict:** approve-for-merge (orchestrator audit pending)

---

## TL;DR

Extends the dev-only Data Alignment audit scorer with two new
per-period check groups and fixes the structural ordering bug.

1. **Gap 38 / known-gap #8 — structural ordering fix.** `loadSnapshot`
   previously fetched the `TargetCycle` only inside `if (snapshot !=
   null)`, so every `TargetCycle -> Profile` benchmark-authority check
   and the new pool-consistency invariant degraded to *unavailable* for
   the entire window between cycle creation and the first weekly-plan
   lock. The cycle's existence is independent of whether a weekly plan
   is locked, so the fetch is now too: snapshot present → link the
   locked `targetCycleId`; no snapshot → fall back to the active cycle.
2. **NEW group `poolConsistency` (Design Rule 4, plan Gap 14).**
   Recomputes the cover-weighted rollup
   `Σ(cover×value)/Σ(cover)` (with OPZ band = union min floor / max
   ceiling) from the persisted `target_cycle_dayparts` child rows and
   compares it against the parent `target_cycles` whole-day pool
   scalars. Drift = the pool diverged from its periods (the risk a
   future pool-only override UI would introduce).
3. **NEW group `wageAtLockTime` (Design Rule 8).** Reconciles the
   snapshot's locked theoretical FOH/BOH labor dollars and blended wage
   against `weekly_plan_snapshots.wage_at_lock_time_json`, NOT against
   `ActiveTargetProfile` current wages — so a legitimate post-lock wage
   edit never shows up as false plan drift.

No sentinel `0` anywhere (Design Rule 2): empty `dayparts` (Gap 42
fallback), null cycle, and legacy snapshots without the wage stamp all
degrade to `unavailable`, never false drift. Per-period accessors use
the `daypart*`-named model fields (Design Rule 1). No widget change —
the audit panel renders `auditGroups` generically, so the two new
groups surface automatically; no `lib/screens/learn/*` touch needed.

---

## Files changed

| File | LoC | Note |
|---|---|---|
| `lib/models/data_alignment_audit_check.dart` | +19 | Two new `DataAlignmentAuditGroup` values (`poolConsistency`, `wageAtLockTime`) + their `title` cases (`POOL CONSISTENCY`, `WAGE-AT-LOCK-TIME PROVENANCE`). |
| `lib/services/data_alignment_audit_read_service.dart` | +222 −2 | Gap 38 fix in `loadSnapshot` (cycle fetched independent of snapshot; active-cycle fallback). Two new pure static check builders `_poolConsistencyChecks` / `_wageAtLockTimeChecks` wired into `computeAuditChecks`. |
| `test/data_alignment_audit_read_service_test.dart` | +413 | 9 new scenario tests across 3 new groups + 2 test helpers (`_cycleWithDayparts`, `_makeSnapshotWithWageStamp`). |

Total: **+652 / −2** across 3 files.

---

## Verification (CI dark — local commands disclosed)

```
dart analyze lib/models/data_alignment_audit_check.dart \
             lib/services/data_alignment_audit_read_service.dart
  → No issues found!

dart analyze test/data_alignment_audit_read_service_test.dart
  → No issues found!   (after fresh package build; a pre-build
    single-file analyze reported 6 stale-cache undefined_enum_constant
    errors that vanished once flutter test compiled the package)

flutter test test/data_alignment_audit_read_service_test.dart
  → 00:00 +42: All tests passed!
    (33 pre-existing + 9 new — nearest/only test covering this surface)
```

The single-file `dart analyze` of the test before a fresh build emitted
stale-cache `undefined_enum_constant` errors for `poolConsistency` /
`wageAtLockTime`; the lib enum file analyzes clean standalone, the test
analyzes clean post-build, and `flutter test` (fresh compile) is green.
Stale analyzer cache, not a real defect.

---

## Pattern B audit — 14 lenses

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Slice respects authority order. The active phase doc (`per_daypart_targets_v1_plan.md`, authority #5) names Slice 6 scope at lines 348–360 and Design Rules 1/2/4/8 at 276–286; the implementation mirrors them. Known-gap #8 (the prompt's "Gap 38 structural ordering bug") at plan line 375 is resolved. Gap 42 (plan line 23 / 474) empty-`dayparts` fallback handled as unavailable. No conflict with `core_app_architecture.md` (#2) — the pool/wage invariants are read-time guards, no Layer behavior changed. | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:276–286,348–360,375`; `lib/services/data_alignment_audit_read_service.dart:106–130` | None |
| 2 | **Hard Promises** | HP #1 (transport swap) untouched — no vendor wiring. HP #2 (demo writer-side switch) — no `kDemoMode` branch, no `demo_*` table; the scorer reads whatever the active scope's tables hold either way. HP #3 (no logic before 7.58) — this is a dev-only diagnostic *read* scorer, no Primary Driver decision, no app behavior change. HP #4 (per-operator isolation) — reads go through the same `restaurantId`-scoped repositories already used; no new cross-scope read. HP #6 (advisor recommends) — n/a. HP #10 (UX per phase close) — the audit panel already surfaces the two new groups generically (`data_alignment_audit_panel.dart` iterates `auditGroups`), so the new shapes are operator-visible in the Settings audit panel with no widget change. HP #11 (hierarchy scope) — the audit panel is a flat diagnostic surface, not a settings surface; no scope chip applies. | `CLAUDE.md` Hard Promises; `lib/widgets/data_alignment_audit_panel.dart:255,295,306` | None |
| 3 | **Service-layer split** | All logic added to `lib/services/data_alignment_audit_read_service.dart` (runtime orchestration) as **pure static** builders — no new I/O, every input arrives pre-resolved (same pattern as the existing `_benchmarkAuthorityChecks` etc.). Model enum lives in `lib/models/`. No `lib/data/`, no Postgres import, no `lib/auth/`, no `lib/domain/services/` touch. Widget unchanged (panel goes through the service, service touches repos — placement preserved). | `lib/services/data_alignment_audit_read_service.dart:475,624` (static, no I/O) | None |
| 4 | **Architecture guardrails** | `TargetCycle` remains the formula source; the pool-consistency check *reads* the rollup, it does not recompute or mutate it (Design Rule 4 — pool derived inside the write path only; this is the read-time guard the rule names). `WeeklyPlanSnapshot` is the locked week-in-force plan; the wage-at-lock-time check reconciles against its own stamped wages, never re-deriving from the live profile. Source facts vs derived metrics kept separate — the scorer compares persisted values, it does not author them. | `lib/domain/models/target_cycle.dart:68–149` (`TargetCycleDaypartPool` rollup, write-path-owned); `lib/services/data_alignment_audit_read_service.dart:519` | None |
| 5 | **Time guardrails** | No time math added. No `TIMESTAMP WITHOUT TIME ZONE`, no business-date manipulation, no schema. The wage-at-lock-time check uses `snapshot.lockedAt`-era stamped wages conceptually but reads the already-persisted `wageAtLockTime` object — no timestamp parsing introduced. | `lib/services/data_alignment_audit_read_service.dart:624–700` | None |
| 6 | **RLS-ready schema** | No schema change. No migration, no table, no column, no index. Reads `target_cycle_dayparts` + `weekly_plan_snapshots.wage_at_lock_time_json` via the existing Slice 1 model fields (`TargetCycle.dayparts`, `WeeklyPlanSnapshot.wageAtLockTime`); the Gap 38 fix calls the existing `SqliteTargetCycleRepository.getActiveCycle(restaurantId)` (already scope-filtered) instead of `getCycleById`. | `lib/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart:22–32`; `lib/services/data_alignment_audit_read_service.dart:128–129` | None |
| 7 | **Proxy & API conventions** | No proxy route, no idempotency key, no `/v1`/`/v2` path, no Postgres extension, no service-principal path. Entirely client-side SQLite read scorer. | n/a | None |
| 8 | **Testing seam** | 9 new tests prove the smallest set of seams: pool consistent→aligned, pool tampered→drifted (and OPZ-union still aligned), Gap 42 empty `dayparts`→unavailable, null cycle→unavailable; wage stamp reproduces→aligned, locked-dollars-reconcile-to-lock-time-not-live-profile (the Design Rule 8 proof), tampered locked FOH $→drifted, legacy-no-stamp→unavailable; plus the Gap 38 consequence test (cycle present + no snapshot still drives live authority + pool checks). Existing 33 tests unchanged and green (no regression). | `test/data_alignment_audit_read_service_test.dart:820–1095` | None |
| 9 | **Operator-facing copy / UX writing standard** | No operator-facing prose. The two new group titles (`POOL CONSISTENCY`, `WAGE-AT-LOCK-TIME PROVENANCE`) match the existing all-caps diagnostic header convention in the same enum extension (`BENCHMARK AUTHORITY`, `PLAN -> RUNTIME`). Check labels mirror the existing terse `X = Y` diagnostic vocabulary. This is a dev/diagnostic surface, not training copy. | `lib/models/data_alignment_audit_check.dart:50–86` | None |
| 10 | **Demo mode contract** | No `kDemoMode` branch, no `demo_*` table, no reader fork. The scorer reads the same `target_cycle_dayparts` / `weekly_plan_snapshots` tables under the active scope whether demo or live. Existing `CLAUDE.md` Demo Mode carve-outs untouched. | `lib/services/data_alignment_audit_read_service.dart` (no `kDemoMode` token anywhere) | None |
| 11 | **Ceiling-raise rule** | No lint-tool ceiling raised. No `advisor_proxy` touch. `data_alignment_audit_read_service.dart` grew 1386 → 1606 LoC; this file has no dedicated size-lint ceiling (the gated ceiling is `kAdvisorProxyMaxLines`, untouched). | n/a | None |
| 12 | **Phase-doc hygiene** | Slice < 1 week AND 3 files (1 model + 1 service + 1 test). Controlling phase doc `per_daypart_targets_v1_plan.md` remains in `docs/phases/`. No new phase doc, no contract amendment needed — Design Rules 4 + 8 already specify the invariants this slice merely *enforces* at read time. | `CLAUDE.md` Phase Doc Hygiene | None |
| 13 | **Anti-scope** | Did NOT touch `target_cycle_service.dart`, `weekly_plan_snapshot_service.dart`, `lib/screens/shifts/*`, `lib/screens/benchmark*`, `lib/screens/plan_*`, the variance card, `schedule_builder*`, or any vendor sink (concurrent Slices 2/3/4/5 + Claude 2 Slice 7b territory). Did NOT modify the cycle write path, the pool rollup helper, or any per-period schema. Stayed strictly in the audit-scorer + its model enum + its test. No `lib/screens/learn/*` change — the panel renders new groups generically so the narration tail needs no edit (kept minimal per prompt). | `git diff --stat` shows only the 3 in-scope files | None |
| 14 | **Idempotency / no side effects** | The two new builders are pure static functions returning `List<DataAlignmentAuditCheck>` with no I/O, no mutation, no caching — identical inputs yield identical output. The Gap 38 fix adds one extra read on the snapshot-absent path via the existing `_safeLoad` wrapper (failure → null → unavailable, never throws). No write path introduced anywhere. | `lib/services/data_alignment_audit_read_service.dart:475,624`; `:128–129` (`_safeLoad`) | None |

---

## Slice-1-schema follow-up findings (NOT fixed here per concurrency rule)

None. The Slice 1 models (`TargetCycle.dayparts`,
`TargetCycleDaypartPool.fromDayparts`, `WeeklyPlanSnapshot.wageAtLockTime`,
`SqliteTargetCycleRepository.getActiveCycle`) were inspected end-to-end
for this slice and are internally consistent with Design Rules 1/2/4/8.
No Slice 1 drift observed.

---

## Self-audit verdict

All 14 lenses clear with no findings. 42/42 tests green (33 pre-existing
+ 9 new). `dart analyze` clean on every touched lib + test file (post
fresh build). Scope held strictly to the audit scorer. Recommend
**approve-for-merge** pending independent orchestrator audit.
