# PR #552 Audit — A4.2 Performance Fixes (R1 + R2 + R3)

**Slice:** A4.2 (Lane A — Code Health)
**Owner:** Claude lane executor
**Branch:** `claude/a4-2-performance-fixes`
**Base:** `master` (verified — not stacked)
**Gate:** `operator` per ledger row 37 (Postgres pool default change = infrastructure-touching, though prod runtime is env-pinned)
**Size:** 608 additions / 288 deletions / 11 files (medium)
**Chunking:** light variant
**Dependency:** A4.1 merged ✓ (PR #517 — performance audit pass that produced R1/R2/R3 ranked recs)

## Verdict

**approve-pending-operator** — escalating per ledger row 37 Gate=operator. Audit clean. Production runtime behavior is unchanged (env vars already pin the operative values); the changes harden the fail-safe fallback and consolidate timer state. Low-risk slice despite the gate flag.

## Pattern B compliance

**❌ MISSING — second occurrence of Pattern B drift from this Claude session.**

PR body has narrative sections (Summary / Files changed / Behavior preservation / Disposal hygiene / Test plan / Operator gate / Authority) but does NOT include:
- ❌ Worker self-audit table (14 lenses with file:line citations)
- ❌ Executor independent audit table

Substance is honest (explicit "behavior preservation" framing, dispose-hygiene callout, baseline-snapshot doctrine honored for known-failing tests, A4.1 R1/R2/R3 traceability). Counter increments to **2/3** for this Claude lane session. One more occurrence triggers the prompt-drift flag.

## What landed (mapped to A4.1 ranked recs)

| Rec | Severity | Change | File |
|---|---|---|---|
| **R1** | P0 | `kPostgresDefaultMaxConnectionsPerPool` constant `4 → 20` | `lib/infrastructure/persistence/postgres/postgres_executor.dart:58` |
| **R2** | P0 | Four 30s `Timer.periodic` instances → one shared `_ShiftDashboardTicker` (`ValueNotifier<DateTime>`) | `lib/screens/shift_dashboard.dart` |
| **R3** | P1 | `healthProducerConcurrency` resolved through `resolvePostgresMaxConnectionsPerPool()` instead of in-process fallback constant | `tool/advisor_proxy/proxy_bootstrap.dart` |

Plus 5 inline-comment sweep files (no logic changes) + 3 test files (1 new + 2 updated).

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Base = master** (not stacked) | ✓ — `baseRefName=master`, mergeable=true, mergeStateStatus=CLEAN |
| **R1: pool constant change** | ✓ — `lib/infrastructure/persistence/postgres/postgres_executor.dart:58`: `const int kPostgresDefaultMaxConnectionsPerPool = 20;` (was 4) |
| **R1: fallback path uses the new constant** | ✓ — `:96`: `return kPostgresDefaultMaxConnectionsPerPool;` is the fallback when no env override is set |
| **R1: behavior preservation claim** ("prod already pins POSTGRES_POOL_MAX_CONNECTIONS=20") | ✓ — runbook-anchored claim. Production runtime unchanged; only the misconfigured-deploy fallback hardens |
| **R2: single Timer.periodic in shift_dashboard.dart** | ✓ — `lib/screens/shift_dashboard.dart:403`: `_timer = Timer.periodic(_interval, (_) { ... });` inside `_ShiftDashboardTicker`. Only one site in the file (verified via grep) |
| **R2: ticker is `ValueNotifier<DateTime>`** | ✓ — `:398`: `class _ShiftDashboardTicker extends ValueNotifier<DateTime>` |
| **R2: disposal hygiene** (audit-doc-disclosed claim) | ✓ — `_ShiftDashboardState.dispose()` at `:81-83` calls `_ticker.dispose()` before `super.dispose()`. `_ShiftDashboardTicker.dispose()` at `:415` cancels the `Timer.periodic` and nulls the reference before `super.dispose()`. Audit chain preserved |
| **R2: consumer widgets converted to listen via shared ticker** | ✓ — comment-block annotations at `:380-381`, `:436`, `:994-995`, `:1364-1366` all reference `[_ShiftDashboardTicker]`. Consumer pattern is `ValueListenableBuilder<DateTime>` per the worker disclosure |
| **R2: per-widget `_tickInterval` constants removed** (test guard claim) | ✓ — test asserts this at `test/widget/shift_dashboard_ticker_test.dart` (per PR body) |
| **R2: static-source guard** (test asserts `Timer.periodic(` count = 1 in `shift_dashboard.dart`) | ✓ — claim verifiable; ensures regression-resistance to future re-introductions |
| **R3: health producer concurrency env-resolved** | ✓ per claim — `tool/advisor_proxy/proxy_bootstrap.dart` now calls `resolvePostgresMaxConnectionsPerPool()` instead of using the bare constant. With prod env `POSTGRES_POOL_MAX_CONNECTIONS=20`, fan-out = 20 (was 4) |
| **5 inline-comment-sweep files are comment-only** | ✓ — diff: each is `1+/1-` (single line change), all in `tool/*_worker/main.dart` + `tool/cutover/preflight_smoke.dart` + `tool/audit_anchor/main.dart`. No logic changes |
| **Test coverage updated** | ✓ — disclosed: 3 new ticker tests pass; existing 8 daypart tests pass without modification; postgres_executor_test default-constant assertion updated from `equals(4)` to `equals(20)` (9/9 pass); health-check-store source-string assertion updated (15/15 pass); broader regression check (60/60 pass) |
| **Baseline-snapshot doctrine** (per `feedback_audit_baseline_test_snapshot.md`) | ✓ — worker disclosed: "Pre-existing master test failures in `shift_visual_widget_test.dart` and `shift_dashboard_empty_state_widget_test.dart` confirmed via `git stash` baseline check; not introduced by this PR." Discipline preserved |
| **CI-dark-window discipline** (per `feedback_ci_dark_until_2026_06_01.md`) | ✓ — touches `lib/infrastructure/persistence/postgres/**` (high-risk) + `tool/advisor_proxy/**` (high-risk). Worker disclosed `flutter analyze --fatal-infos` clean on 11 changed files + targeted `flutter test` runs on 5 test files + broader regression on 3 more. Local hook coverage sufficient |
| **No auth/RLS/schema/migration touched** | ✓ — diff scope: no `db/migrations/**`, no `lib/auth/**`, no RLS policy files |
| **`dart analyze` clean** + lints clean | ✓ — worker disclosed: `flutter analyze --fatal-infos` clean on 11 changed files; `dart run tool/release_dart_defines_lint.dart` clean; pre-push `postgres_import_lint` clean |
| **A4.1 traceability** | ✓ — `docs/_audits/code_health/a4_performance_audit.md` section 6 ranked R1/R2/R3 — this PR lands all three in execution order, no scope creep |
| **No tracker / ledger / lane-index touches** | ✓ — diff scope confirms |
| **No `--no-verify` traces** | ✓ — commit message clean; pre-push hooks ran |

## What operator should confirm

1. **Pool constant 4 → 20 is a fallback-only change.** Production deploys pin `POSTGRES_POOL_MAX_CONNECTIONS=20` via runbook, so prod runtime is unchanged. The fix prevents a future deploy that forgets the env var from silently regressing to a pool of 4 (the runbook-flagged "silent degradation" failure mode). Low risk.

2. **R2 ticker coalescing is behavior-preserving.** Same 30s cadence, identical render output, `ShiftDashboard.clockOverride` test seam unchanged. The existing 8 daypart tests pass without modification — strong signal that visible behavior is unchanged.

3. **R3 health producer concurrency** — `/health` is manual per `PERFORMANCE_FRAMEWORK.md` golden rule (no routine traffic), so the fan-out change has zero impact on routine production traffic; only on the rare ops-driven health probe.

## Recommendation

**approve-for-merge.** The slice is mechanically clean, A4.1-traceable, and behavior-preserving in production. Operator-gate per ledger is correct (Postgres pool config touches infra config) but the change is low-risk in practice.

If approved, I will merge + update the ledger (A4.2 → merged).

## Cross-slice implication

**A4.2 merging unblocks B11.2.b** — the deferred B11.2 wiring slice depends on A3.2 + A4.2 merged (file isolation, per B11.2 audit). With A4.2 merged, only A3.2 remains as the wiring slice's gating dependency.

## Authority anchors verified

- `docs/_audits/code_health/a4_performance_audit.md` section 6 — R1/R2/R3 ranked recs
- `docs/_execution/lane_a_code_health/03_execution_slices.md` Slice A4.2 (scope match)
- `docs/_indices/WAVE_EXECUTION_LEDGER.md:37` — A4.2 row, Gate=operator
- `docs/frameworks/PERFORMANCE_FRAMEWORK.md` — golden rule on `/health` cadence + pool sizing
- `~/.claude/projects/.../feedback_audit_baseline_test_snapshot.md` — pre-existing failure discipline
- `~/.claude/projects/.../feedback_ci_dark_until_2026_06_01.md` — local-test-disclosure discipline

## Findings

- **P3 nit**: Pattern B drift — second occurrence from this Claude session (counter 2/3). Substance is honest; if next Claude PR also lacks the audit tables, flag prompt drift for operator.

## Status

Awaiting operator approval.
