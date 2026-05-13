# PR #630 Audit — B6 Benchmark Overrides (Hierarchy-Inherited) (Codex)

**Slice:** B6 (Lane B Hierarchy Finalization; ledger row 64)
**Owner:** Codex
**Branch:** `codex/b6-benchmark-overrides-hierarchy`
**Base:** `master` @ `ab4606ef`
**Gate:** **operator-approval-required** — proxy-touching (`advisor_proxy.dart` +149) + schema-touching (new operator-scoped fact table + RLS policy) per CLAUDE.md "Agent-Led Slices"
**Risk:** **Medium-High** — pushes `advisor_proxy.dart` past the bleed-stop ceiling; new operator-scoped fact table with per-tenant RLS; new permission key surface used (`forgeflow.baseline.override`, already on master); new operator-web screen + 4 proxy routes
**Size:** 3972 additions / 1 deletion / 20 files

## Verdict

**HOLD-FOR-OPERATOR** — audit verdict approve-pending-operator; **1 genuine safety hold fires**.

Audit (delegated to sub-agent — full reasoning at `docs/_audits/post_codex_wave/pr_630_b6_benchmark_overrides_hierarchy_audit.md` summary block below) returns clean structural verdict: Pattern B exemplary, scope matches ledger row 64 + slice spec `docs/_execution/lane_b_features/03_execution_slices.md:108-116` exactly, additive-expand migration with proper RLS + operator-leading indexes, frozen paths untouched, no `audit_logs` UPDATE, no `pg_advisory_lock`, no destructive ops, mergeable CLEAN. The one genuine hold:

**🛑 `advisor_proxy.dart` bleed-stop ceiling breach**

- Pre-PR master: 19,812 lines.
- PR diff adds: +149 lines to `advisor_proxy.dart`.
- Post-merge projection: 19,961 lines.
- Ceiling (`tool/advisor_proxy_size_lint.dart:kAdvisorProxyMaxLines`): 19,900.
- **Overage: 61 lines.**

Worker's "pre-push lints clean" claim is technically true because the size lint runs in **CI only**, not pre-push. CI is gated to `workflow_dispatch` until 2026-06-01 (per `feedback_ci_dark_until_2026_06_01.md`), so the master tip will not auto-fail today. But the next CI dispatch or the 2026-06-01 reactivation **will** fail the size lint job.

This is an **undisclosed material concern** per the auto-merge gate. The worker did not flag the ceiling breach in the disclosure section — it surfaced via the audit agent's independent `git show origin/master:tool/advisor_proxy/advisor_proxy.dart | wc -l` + diff line count. That qualifies as a worker disclosure gap the operator should weigh.

## Pattern B compliance

**✓ EXEMPLARY** — worker 14-lens table + executor 14-lens table both present in PR body with all rows "Pass" / "None". Honest disclosure of one prior send-back cycle (base drift + missing live-UI wiring + missing `forgeflow.baseline.override` gate + incomplete audit fields + RLS authority tension — all reconciled in cycle 2).

## What landed (high-level)

| File | LoC | Kind |
|---|---|---|
| `db/migrations/202605131550_benchmark_overrides_hierarchy.sql` | +123 / 0 | **NEW** — operator-scoped `benchmark_overrides` table; per-tenant RLS via `app_current_operator()`; 3 indexes leading with `operator_id`; partial UNIQUE INDEX using `coalesce(uuid, sentinel)` to enforce one current row per `(operator, metric_key, scope_type, target)` |
| `tool/advisor_proxy/advisor_proxy.dart` | +149 / 0 | **EXTEND — ceiling breach** — 4 new operator-web routes (`GET /v1/admin/benchmarks/...`, `POST .../override`, `PATCH .../override/{id}`, `DELETE .../override/{id}`); reads `forgeflow.baseline.override` permission key via `permissionSnapshotResolver`; 403 on non-`allow` |
| `lib/operator_web/screens/benchmarks_screen.dart` | (TBD) | NEW — operator-web Benchmarks screen with Inheritance Tree picker |
| `lib/operator_web/services/benchmark_overrides_gateway.dart` | (TBD) | NEW |
| `lib/infrastructure/persistence/postgres/repositories/benchmark_overrides_repository.dart` | (TBD) | NEW — extends `OperatorScopedRepository` |
| ...12 more files | | per file list |

(Full diff details deferred to the sub-agent verification block; not duplicated here.)

## Critical safety guarantees (executor-verified)

| Guarantee | Verification |
|---|---|
| `lib/auth/permission_keys.dart` UNTOUCHED | ✓ — diff = 0 lines; existing `forgeflowBaselineOverride = 'forgeflow.baseline.override'` at `lib/auth/permission_keys.dart:66` (already on master) is the gate |
| `pubspec.yaml` UNTOUCHED | ✓ — diff = 0 lines |
| `WAVE_EXECUTION_LEDGER.md` UNTOUCHED | ✓ — diff = 0 lines (orchestrator's job) |
| Migration is additive-expand only | ✓ — `CREATE TABLE IF NOT EXISTS`; no DROP/ALTER COLUMN TYPE/UPDATE on existing rows |
| Operator-scoped fact table | ✓ — `(operator_id, …)` shape |
| Per-tenant RLS policy via `app_current_operator()` wrapper | ✓ — no bare `current_setting()` reads |
| Operator-leading B-tree indexes | ✓ — 3 indexes all lead with `operator_id` |
| No `audit_logs` UPDATE | ✓ — `audit_logs_update_lint` clean |
| No `pg_advisory_lock` | ✓ |
| Cutoff filename `202605131550_…` sorts BEFORE current master cutoff `…1900_c_2_d_…` | ✓ — final apply order will be 630 (`…1550`) before 626/631; no staging cutoff bump required, migration_cutoff_lint stays clean on rebase |
| `advisor_proxy_size_lint` — **WILL FAIL** in CI | 🛑 **HOLD** — 19,961 / 19,900 ceiling (overage 61 lines) |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied | ❌ — code-ready only |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — row 64 scope matches diff verbatim |
| **Worker disclosed something operator should know** | **✓ TRIGGERED — undisclosed proxy ceiling breach.** Worker's "pre-push lints clean" disclosure misses that size lint runs in CI only (currently dark); post-merge state breaches the 19,900 ceiling by 61 lines. |
| Stacked PR | ❌ — base is master |
| **Schema + RLS + proxy-touching** | **✓ TRIGGERED** — title self-flagged `[operator-approval-required]` |

**Decision**: **HOLD for explicit operator decision.** Two paths:
1. **Raise ceiling.** Operator approves a 100-200 line ceiling bump (e.g. 19,900 → 20,100) with rationale documented in `proxy_split_plan.md` + size lint constant updated in same PR or a tiny follow-up before merge. Merge B6.
2. **Decompose.** Operator sends back for the routes file to be moved to a sibling `tool/advisor_proxy/benchmark_overrides_routes.dart` (same pre-check mount pattern as C-1 SendGrid Event Webhook routes + B8 audit-log hierarchy routes). Estimated rework ~150-200 LoC re-shape; net advisor_proxy.dart delta drops back to ~0.

**Recommendation:** Path 2 (decompose) for parity with C-1 + B8 sibling-file precedent; the bleed-stop discipline is the load-bearing reason this entire wave's PRs have respected the ceiling.

## Cutoff-monotonic interplay

B6's migration `202605131550_benchmark_overrides_hierarchy.sql` sorts lex-BEFORE the now-current master cutoff `202605131900_c_2_d_vendor_sync_outage_state.sql` (post-Bundle 49). The migration_cutoff_lint enforces "cutoff filename in code matches the newest migration in `db/migrations/`" — newest stays at `…1900_c_2_d_…`; B6 simply adds an earlier file. Lex ordering of `db/migrations/` directory listing → B6 applies BEFORE C-7a + C-2-D, which is fine (B6 doesn't depend on them).

## Findings

1. **🛑 BLOCKING:** `advisor_proxy.dart` post-merge = 19,961 / 19,900 ceiling (61-line overage). Worker disclosure gap.
2. **NON-BLOCKING:** Audit matrix asked for `app_current_location()` clamp; B6 uses operator-wide RLS clamp because `operator_wide` and `org_unit` rows legitimately have null `location_id`. Location authority enforced at proxy via `operator_owner/admin` + `forgeflow.baseline.override`. Documented in migration comments lines 103-111. Worker disclosed this design tension; verdict OK.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 64 — B6 ledger row
- `docs/_execution/lane_b_features/03_execution_slices.md:108-116` — B6 slice spec
- `tool/advisor_proxy_size_lint.dart:kAdvisorProxyMaxLines` — current ceiling (19,900)
- `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` — sibling-file pre-check mount pattern (C-1 + B8 precedents)
- `~/.claude/projects/.../memory/feedback_ci_dark_until_2026_06_01.md` — CI dark window
- CLAUDE.md "Agent-Led Slices" + "Architecture Guardrails"

## Status

**HELD for operator decision.** Audit verdict approve-pending-operator-with-ceiling-resolution. Audit doc: `docs/_audits/post_codex_wave/pr_630_b6_benchmark_overrides_hierarchy_audit.md`.
