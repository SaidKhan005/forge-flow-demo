# PR #634 Audit — B6 Benchmark Overrides + Sibling-File Decompose (Claude, supersedes #630)

**Slice:** B6 (Lane B Hierarchy Finalization; ledger row 64) — full slice + orchestrator-applied proxy decompose
**Owner:** Codex (B6 work) + Claude (orchestrator-spawned decompose agent)
**Branch:** `claude/pr-630-fix-decompose-sibling-file`
**Base:** `master` @ `5aac538c` (post-#633 C-2-D-binding)
**Gate:** **operator-approval-required** (operator picked option (a) "decompose" 2026-05-13) — schema-touching (migration) + RLS-touching (per-tenant policy on new fact table) + proxy-touching (sibling-file route handler)
**Risk:** **Low** — original B6 risk profile was Medium-High due to the ceiling breach; decompose neutralizes the breach (advisor_proxy.dart back to 19,812 / headroom 88)
**Size:** 4280 additions / 1 deletion / 19 files

## Verdict

**approve-for-merge** — auto-merged at master `540b848c` per operator's option (a) pick on 2026-05-13. Decompose agent did smart engineering: rather than creating a parallel new file, added the missing `tryHandle(HttpRequest)` dispatch shim to the existing sibling file `tool/advisor_proxy/operator_benchmark_overrides_routes.dart` (Codex had already split out the route logic but kept the dispatch in the monolith). Net advisor_proxy.dart delta: **0 lines** (was +149 in the original #630).

## Pattern B compliance

**✓ EXEMPLARY** — both Codex's original B6 14-lens self-audit (in the supersede branch's commit history from #630) AND the decompose agent's 14-lens self-audit in PR #634 body. Honest disclosure of the wider blast radius than the original prompt anticipated (proxy_bootstrap.dart refactor mirroring B8 + B8's auditLogHierarchyRouter coexistence in main.dart).

## What landed

| File | LoC | Kind |
|---|---|---|
| `db/migrations/202605131550_benchmark_overrides_hierarchy.sql` | +123 / 0 | NEW migration — operator-scoped `benchmark_overrides` fact table with per-tenant RLS via `app_current_operator()`, 3 indexes all leading with `operator_id`, partial UNIQUE INDEX via `coalesce(uuid, sentinel)`, `service_role` + `forge_admin` grants. (Carried forward from Codex's original #630; orchestrator already audited the migration in `pr_630_b6_benchmark_overrides_hierarchy_audit.md`.) |
| `lib/infrastructure/persistence/postgres/repositories/benchmark_overrides_repository.dart` | +514 / 0 | NEW — extends `OperatorScopedRepository`; `withTenant` reads/writes |
| `lib/services/baseline/benchmark_override_resolver.dart` | +207 / 0 | NEW — pure resolver applies inheritance order (location → org_unit → operator-wide → default) |
| `lib/operator_web/screens/benchmarks_screen.dart` | +650 / 0 | NEW — operator-web Benchmarks screen with Inheritance Tree picker |
| `lib/operator_web/services/operator_web_benchmarks_gateway.dart` | +316 / 0 | NEW — operator-web gateway |
| `lib/operator_web/router/operator_web_router.dart` | +27 / 0 | EXTEND — adds Benchmarks route |
| `lib/operator_web/services/operator_web_proxy_client.dart` | +17 / 0 | EXTEND — proxy client methods |
| `lib/operator_web/services/operator_web_team_gateway_providers.dart` | +7 / 0 | EXTEND — DI providers |
| `lib/operator_web/auth/operator_web_auth_source.dart` | +8 / -1 | EXTEND — auth source plumbing |
| `lib/operator_web/auth/firebase_operator_web_auth_source.dart` | +8 / 0 | EXTEND — Firebase auth source plumbing |
| `tool/advisor_proxy/operator_benchmark_overrides_routes.dart` | +950 / 0 | **DECOMPOSED sibling-file route handler** (+284 of these are the orchestrator's decompose: `tryHandle(HttpRequest)` + `OperatorBenchmarkOverridesActor` + auth/permission typedefs + outcome enum; rest is Codex's original route logic from #630) |
| `tool/advisor_proxy/main.dart` | +106 / 0 | EXTEND — closure-bound router construction (where authGuard is in scope, mirroring B8); pre-check mount; 2 import additions |
| `tool/advisor_proxy/proxy_bootstrap.dart` | +40 / 0 | EXTEND — replaced router field with gateway + audit sink fields (mirrors B8 pattern at `proxy_bootstrap.dart:494` doc comment) |
| 6 test files | +1307 / 0 | NEW + EXTEND tests |

**Net effect:** B6 ships in full (operator-web Benchmarks screen + hierarchy-inherited override resolver + 4 admin proxy routes for set/patch/clear/list) **without** the advisor_proxy.dart ceiling breach.

## Critical safety guarantees (executor-verified)

| Guarantee | Verification |
|---|---|
| `tool/advisor_proxy/advisor_proxy.dart` UNTOUCHED | ✓ `git diff origin/master -- tool/advisor_proxy/advisor_proxy.dart` = 0 lines; **bleed-stop ceiling preserved at 88 headroom** (19,812 / 19,900) — same as master |
| `lib/auth/**` UNTOUCHED | ✓ 0 lines (uses existing `forgeflow.baseline.override` permission key on master at `lib/auth/permission_keys.dart:66`) |
| `pubspec.yaml` UNTOUCHED | ✓ 0 lines |
| `WAVE_EXECUTION_LEDGER.md` UNTOUCHED | ✓ 0 lines (orchestrator's job) |
| Migration is additive expand only | ✓ — `CREATE TABLE IF NOT EXISTS`; no DROP/ALTER COLUMN TYPE/UPDATE on existing rows |
| Operator-scoped fact table with per-tenant RLS | ✓ — `(operator_id, …)` shape; `app_current_operator()` wrapper |
| Operator-leading B-tree indexes | ✓ — all 3 lead with `operator_id` |
| No `audit_logs` UPDATE | ✓ — `audit_logs_update_lint` clean |
| No `pg_advisory_lock` | ✓ |
| Cutoff filename `202605131550_…` lex-BEFORE current master cutoff `…1900_c_2_d_…` | ✓ — applies before C-7a + C-2-D in lex order; no cutoff bump required |
| 716 proxy tests + B6 operator-web tests + resolver tests pass | ✓ disclosed |
| `dart analyze --fatal-infos` clean | ✓ disclosed |
| `advisor_proxy_size_lint` headroom = 88 (unchanged) | ✓ |
| 7 other lints clean (`postgres_import_lint`, `audit_logs_update_lint`, `migration_drift_scanner`, `migration_cutoff_lint`, `rls_policy_lint`, `index_leading_column_lint`) | ✓ disclosed |
| Pre-existing failure on `admin_integrations_response_sanitization_test` verified on clean master (NOT introduced) | ✓ disclosed |
| No `--no-verify` traces | ✓ |
| Rebase clean (1 conflict in `main.dart` between B8's router and new B6 router; resolved by stacking — both routers coexist) | ✓ disclosed |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied | ❌ — code-ready only; joins Production1 queue at slot apply-by-lex-order |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — B6 row 64 matches scope verbatim |
| Worker disclosed something operator should know | ⚠ TWO disclosures: (a) **reused existing sibling file** `operator_benchmark_overrides_routes.dart` rather than creating a parallel new one (smart — avoided 666 lines of duplicated route logic); (b) **wider blast radius on proxy_bootstrap.dart** (+40/-34) — refactored to ship `OperatorBenchmarkOverridesGateway` + `OperatorWriteAuditSink` instead of `OperatorBenchmarkOverridesRouter`; router now constructed in `main.dart` where `authGuard` is in scope. Both decisions mirror B8 exactly. |
| Stacked PR | ❌ — base is master (rebased) |
| Ceiling breach (the original #630 hold) | ✅ **RESOLVED** — advisor_proxy.dart 0-line diff |

**Decision**: auto-merged per operator's option (a) pick.

## Triple-safeguard verified

- ✅ `gh pr view 634 --json mergeCommit` → returned merge commit
- ✅ Master tip `540b848c` is ancestor of post-merge state
- ✅ `operator_benchmark_overrides_routes.dart` present on master with `tryHandle(HttpRequest)` method
- ✅ `advisor_proxy.dart` line count on master = 19,812 (independent `wc -l`)

## Cross-lane notes

- **Supersedes PR #630** — original B6 had ceiling breach; #634 fixes it via sibling-file decompose.
- **Mirrors B8 + C-1 sibling-file precedent** — router constructed in `main.dart` where `authGuard` is in scope; pre-check mount; gateway + audit sink in bootstrap.
- **PR #630 closed** with redirect comment pointing at this merge.
- **B6 → merged** for ledger flip in next bundle.

## Findings

None blocking.

## Authority anchors

- `docs/_audits/post_codex_wave/pr_630_b6_benchmark_overrides_hierarchy_audit.md` — original #630 audit (ceiling breach finding)
- `docs/_audits/post_codex_wave/pr_624_b8_audit_log_hierarchy_filter_audit.md` — B8 sibling-file precedent
- `docs/_audits/post_codex_wave/pr_611_c_1_sendgrid_events_webhook_audit.md` — C-1 sibling-file precedent
- `tool/advisor_proxy_size_lint.dart:kAdvisorProxyMaxLines` — the ceiling (19,900)
- CLAUDE.md "Architecture Guardrails" + "Agent-Led Slices"
- Operator's 2026-05-13 option (a) decompose pick

## Status

**Merged.** Master `540b848c`. B6 fully live; ceiling preserved.
