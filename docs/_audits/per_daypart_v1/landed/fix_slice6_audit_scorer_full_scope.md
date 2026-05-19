# Slice 6 (full scope) — all 8 per-period data-alignment audit checks + locked-plan authority fix

**Branch:** `claude/fix-slice6-audit-scorer-full-scope`
**Base:** `master`
**Slice tag:** per-daypart-targets-v1 Slice 6 (re-dispatch — full scope)
**Owner:** worker agent (Claude lane)
**Verdict:** approve-for-merge (orchestrator audit pending)

> **Supersedes the scope narrowing in `docs/_audits/per_daypart_v1/slice_6_audit_scorer.md`.**
> That doc shipped only 3 of the 8 plan-mandated per-period categories
> (pool-consistency, wage-at-lock-time, Gap-38 ordering fix) and narrowed
> scope WITHOUT escalation. The operator has rejected the narrowing and
> required the full 8. This slice ships the 5 missing categories and
> fixes the `_planRuntimeChecks` locked-plan-authority bug.

---

## TL;DR

`lib/services/data_alignment_audit_read_service.dart` now ships **all 8**
Slice 6 per-period check categories (plan lines 348-360) and reconciles
the Variance Full Week non-closed cells against the **locked**
`WeeklyPlanSnapshot.dayDayparts` authority instead of the retired
`DaypartPlanAllocator`.

- **Already shipped (3):** pool-consistency, wage-at-lock-time, Gap-38
  structural-ordering fix — untouched.
- **NEW (5):** per-period benchmark authority; per-period Shift runtime;
  per-period Variance runtime; per-period locked-plan day-row
  reconciliation; per-period sum-to-day + per-period actual presence.
- **BUG FIXED:** `_planRuntimeChecks` Variance Full Week block now
  reconciles non-closed cells against `snapshot.dayDayparts` (the Slice 3
  locked authority) when present; the `DaypartPlanAllocator` fallback
  runs **only** when `dayDayparts` is empty (legacy / Gap-42).

Every new check degrades **honestly** when per-period data is absent
(in demo today the seed omits `dayDayparts` — a separate queued Slice 3
seed fix): an informational "no per-period rows — whole-day only"
presence row + `unavailable` aggregates. No false PASS, no fabricated
`0` (Design Rule 2), no hard FAIL. Closed-truth immutability preserved —
locked snapshot rows reconcile against the **lock-time** cycle
(`snapshot.targetCycleId`), never re-graded under the active cycle.

---

## Files changed

| File | LoC | Note |
|---|---|---|
| `lib/models/data_alignment_audit_check.dart` | +55 | 5 new `DataAlignmentAuditGroup` values + their `title` cases. |
| `lib/services/data_alignment_audit_read_service.dart` | +723 −13 | 5 new pure-static per-period check builders wired into `computeAuditChecks`; `_planRuntimeChecks` Variance block split into locked-authority path (precedence) + allocator fallback. |
| `test/data_alignment_audit_read_service_test.dart` | +598 | 16 new scenario tests across the 5 new categories + the precedence fix + 3 helpers. |

Total: **+1363 / −13** across 3 files. Diff held strictly to the
audit-scorer surface + its model enum + its test (Concurrency honored).

---

## Verification (CI dark — local commands disclosed)

```
flutter pub get
  → Got dependencies!

dart analyze lib/models/data_alignment_audit_check.dart \
             lib/services/data_alignment_audit_read_service.dart \
             test/data_alignment_audit_read_service_test.dart
  → No issues found!

dart analyze lib/widgets/data_alignment_audit_panel.dart \
             lib/models/data_alignment_audit_snapshot.dart
  → No issues found!   (enum-consumer exhaustiveness confirmed)

flutter test test/data_alignment_audit_read_service_test.dart
  → 00:00 +58: All tests passed!
    (42 pre-existing + 16 new — nearest/only suite for this surface)
```

Baseline snapshot: at `HEAD` (pre-PR) the same suite is **+42 green**
(no `dayDayparts`/`planRuntime` tests existed). The 16 added tests are
all PR-introduced and green; no pre-existing test regressed. The single
`deprecated_member_use_from_same_package` info on
`DaypartPlanAllocator.allocate` (Slice 3 deprecated it on master after
the prior Slice 6 audit; the baseline file already calls it un-ignored)
is suppressed with an inline `// ignore:` — the allocator's own
deprecation note explicitly sanctions the "audit (Slice 6)" fallback
consumer.

---

## Explicit prompt proofs

**(a) All 8 categories present (3 prior + 5 new).** `computeAuditChecks`
wires, in order: `_liveActualsChecks`, `_benchmarkAuthorityChecks`,
`_benchmarkRuntimeChecks`, `_planLockedProjectionChecks`,
`_planRuntimeChecks`, `_poolConsistencyChecks` (prior #1),
`_wageAtLockTimeChecks` (prior #2) — Gap-38 fix (prior #3) lives in
`loadSnapshot:122-129` — then the **5 new**:
`_perPeriodBenchmarkAuthorityChecks`, `_perPeriodShiftRuntimeChecks`,
`_perPeriodVarianceRuntimeChecks`,
`_perPeriodLockedPlanReconciliationChecks`,
`_perPeriodSumAndActualPresenceChecks`
(`data_alignment_audit_read_service.dart:490-514`). Each maps to a
distinct `DataAlignmentAuditGroup` enum value
(`data_alignment_audit_check.dart:64-110`).

**(b) `_planRuntimeChecks` reconciles to the locked snapshot authority,
not the retired allocator.** The Variance Full Week block is now
`if (snapshot.dayDayparts.isNotEmpty && fullWeekShifts != null)` →
reconcile each non-closed shift against
`snapshot.dayDaypartFor(businessDate, servicePeriodId)` (labels
`"… = locked dayDayparts"`); `else if (… servicePeriodDefinitions …)`
→ `DaypartPlanAllocator.allocate` fallback (labels
`"… = DaypartPlanAllocator (fallback — no locked dayDayparts)"`); the
precedence is documented in-code at
`data_alignment_audit_read_service.dart:2105-2121`. Test
`_planRuntimeChecks authority precedence` proves the locked path runs
(and the fallback labels are absent) when `dayDayparts` is present, and
the allocator fallback runs when it is empty.

**(c) Honest degradation when per-period data absent.** Every new
builder, on `targetCycle == null || dayparts.isEmpty` (or
`snapshot.dayDayparts.isEmpty`), emits a single
`DataAlignmentAuditCheck.presence(actualLabel: null)` → detail `—`
(`DriftCheckStatus.unavailable`) plus `unavailable` numeric/aggregate
rows — never a false PASS, never a hard FAIL, never a fabricated `0`.
Per-period **actuals** (no feed wired into this read path — owned by the
parallel `shift_service_period_read_service.dart`) are reported as 3
`presence(actualLabel: null)` rows = `—`/unavailable, proven by test
`per-period ACTUAL absence → reported missing (—), NEVER a 0 pass
(Design Rule 2)`.

**(d) Closed-truth immutability preserved.**
`_perPeriodLockedPlanReconciliationChecks` reconciles each
`snapshot.dayDayparts` row against the **lock-time** cycle — the
`targetCycle` `loadSnapshot` fetches by `snapshot.targetCycleId`
(`:122-125`), i.e. the cycle the plan was generated under, NOT the
now-active cycle. `_perPeriodVarianceRuntimeChecks` audits only the
non-closed read seam (`daypartTheoreticalLaborPctFor`); closed Variance
rows keep their locked `shift.theoreticalLaborPct` (Rule 4 exception)
and are not graded here. In-code rationale at
`data_alignment_audit_read_service.dart` per-period-locked-plan and
per-period-variance group headers.

---

## Pattern B audit — 14 lenses

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Slice obeys authority order. Prompt #1 + plan #2 (Slice 6 lines 348-360, the 8 categories) drive scope; Design Rules 1/2/4 + Gap-42 + closed-truth honored. No conflict with `core_app_architecture.md` (#2) — read-time diagnostic guards only, no Layer behavior changed. | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:348-360`; `lib/services/data_alignment_audit_read_service.dart:490-514` | None |
| 2 | **Hard Promises** | HP #2 (demo writer-side switch) — no `kDemoMode` branch, no `demo_*` table; scorer reads whatever the active scope holds. HP #3 (no logic before 7.58) — dev-only diagnostic READ scorer, no Primary Driver decision, no app behavior change. HP #4 — reads via existing scope-filtered repos only. HP #10 — the audit panel renders `auditGroups` generically (`data_alignment_audit_panel.dart:255,306`), so the 5 new groups surface in the Settings audit panel with no widget change. | `CLAUDE.md` Hard Promises; `lib/models/data_alignment_audit_snapshot.dart:110-140` | None |
| 3 | **Service-layer split** | All logic added to `lib/services/…` as **pure static** builders, no I/O — inputs arrive pre-resolved (same pattern as `_poolConsistencyChecks`). Model enum lives in `lib/models/`. No `lib/data/`, no Postgres import, no `lib/auth/`, no widget edit. | `data_alignment_audit_read_service.dart:706,…` (all `static`, no `await`) | None |
| 4 | **Architecture guardrails** | `TargetCycle` stays the formula source; per-period checks **read** `daypartFor`/`TargetCycleDaypartPool.fromDayparts`, never recompute or mutate the write path (Design Rule 4). `WeeklyPlanSnapshot` is the locked week-in-force authority — the precedence fix reconciles against `snapshot.dayDayparts` (the locked truth), demoting the live allocator to fallback exactly per Slice 3. Source facts vs derived metrics kept separate. | `data_alignment_audit_read_service.dart:2105-2121,2122-2185`; `lib/domain/models/target_cycle.dart:102-148` | None |
| 5 | **Time guardrails** | No time math, no `TIMESTAMP` handling, no business-date manipulation. Closed-truth: locked rows reconciled against the lock-time cycle (`snapshot.targetCycleId`), never re-graded under the active cycle. | `data_alignment_audit_read_service.dart:122-125`; per-period-locked-plan group header | None |
| 6 | **RLS-ready schema** | No schema change, no migration, no table/column/index. Consumes existing Slice 1 model fields (`TargetCycle.dayparts`, `ActiveTargetProfile.dayparts`/`daypartFor`/`daypartTheoreticalLaborPctFor`, `WeeklyPlanSnapshot.dayDayparts`/`dayDaypartFor`). | `lib/domain/models/active_target_profile.dart:110-153`; `lib/domain/models/weekly_plan_snapshot.dart:356-367` | None |
| 7 | **Proxy & API conventions** | No proxy route, no idempotency key, no `/v1`/`/v2`, no Postgres extension, no service-principal path. Client-side SQLite read scorer only. | n/a | None |
| 8 | **Testing seam** | 16 new tests prove the smallest seam per category: aligned→PASS, deliberate per-period mismatch→that category drifts with the specific label, absent `dayDayparts`/cycle→honest unavailable (presence detail `—`), per-period actual absence→`—` never `0`-PASS, and the `_planRuntimeChecks` locked-vs-fallback precedence both directions. 42 pre-existing tests unchanged + green. | `test/data_alignment_audit_read_service_test.dart:1099-…` | None |
| 9 | **Operator-facing copy / UX writing standard** | No operator-facing prose. The 5 new group titles (`PER-PERIOD …`) match the existing all-caps diagnostic header convention; check labels mirror the existing terse `X = Y` vocabulary. Dev/diagnostic surface, not training copy. | `lib/models/data_alignment_audit_check.dart:120-133` | None |
| 10 | **Demo mode contract** | No `kDemoMode` branch, no `demo_*` table, no reader fork. The honest-degradation paths are demo-aware only in the sense that they report "no per-period rows" truthfully — exactly what Metric Honesty / Design Rule 2 demand while the queued Slice 3 seed fix is pending. | `data_alignment_audit_read_service.dart` (no `kDemoMode` token) | None |
| 11 | **Ceiling-raise rule** | No lint-tool ceiling raised. No `advisor_proxy` touch. `data_alignment_audit_read_service.dart` grew ~1604 → ~2314 LoC; this file has no dedicated size-lint ceiling (gated ceiling is `kAdvisorProxyMaxLines`, untouched). | n/a | None |
| 12 | **Phase-doc hygiene** | Slice < 1 week, 3 files. Controlling phase doc unchanged. No new contract — Design Rules 1/2/4 + Gap-42 + closed-truth already specify the invariants this slice enforces at read time. | `CLAUDE.md` Phase Doc Hygiene | None |
| 13 | **Anti-scope** | Did NOT touch `mock_integration_replay_seed.dart`/`sqlite_database_seed.dart`, `shift_dashboard.dart`/`shift_service_period_notifier.dart`, demo auth fixture/`settings_screen.dart`, `benchmark_tracker_read_service.dart`/`daypart_table.dart`, `shift_service_period_read_service.dart`, demo-mode-state gateway, operator-web vendor fixture, `active_target_profile.dart`/snapshot models, or any vendor sink. Read-only consulted `variance_week_projection_read_service.dart` + `shift_service_period_read_service.dart` to mirror their resolution rules; modified none. Stayed strictly in the audit scorer + its enum + its test. | `git diff --stat` = 3 in-scope files | None |
| 14 | **Idempotency / no side effects** | All 5 builders are pure static functions returning `List<DataAlignmentAuditCheck>` — no I/O, no mutation, no caching; identical inputs → identical output. The `_planRuntimeChecks` fix adds no write path; it only reorders which read source the existing aggregate consumes. | `data_alignment_audit_read_service.dart:706,…` | None |

---

## Concurrency / Slice-1-schema follow-up findings

None. The Slice 1 models consumed (`TargetCycle.dayparts`/`daypartFor`,
`TargetCycleDaypartPool.fromDayparts`, `ActiveTargetProfile.daypartFor`/
`daypartTheoreticalLaborPctFor`, `WeeklyPlanSnapshot.dayDayparts`/
`dayDaypartFor`) were inspected end-to-end and are internally consistent
with Design Rules 1/2/4/5. No Slice 1 drift observed. No
parallel-worker-owned file touched (Concurrency list honored).

---

## Self-audit verdict

All 14 lenses clear, no findings. 58/58 tests green (42 pre-existing +
16 new). `dart analyze` clean on every touched lib + test file and on
the two enum consumers. Scope held strictly to the audit scorer. All 8
plan categories present; `_planRuntimeChecks` now reconciles to the
locked snapshot authority; honest degradation + closed-truth proven by
test. Recommend **approve-for-merge** pending independent orchestrator
audit.
