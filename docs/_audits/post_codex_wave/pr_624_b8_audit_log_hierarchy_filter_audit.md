# PR #624 Audit — B8 Audit Log Hierarchy Filter (Claude)

**Slice:** B8 (Lane B Hierarchy Finalization; ledger row 66)
**Owner:** Claude
**Branch:** `claude/b8-audit-log-hierarchy-filter`
**Base:** `master` @ `f9bc84fd`
**Gate:** **operator-approval-required** — RLS-touching (`withTenant`) + proxy-touching (3 `tool/advisor_proxy/` files + new route handler) + auth-touching (new role-gated admin endpoint) per CLAUDE.md "Agent-Led Slices"
**Risk:** **Medium** — adds new admin audit-log filter route + new repository reader + new admin screen surface; sibling-file mount pattern bypasses `advisor_proxy.dart` (headroom preserved at 88)
**Size:** 3775 additions / 1 deletion / 12 files

## Verdict

**HOLD-FOR-OPERATOR** — audit verdict approve-pending-operator; **1 genuine safety hold fires** (worker-disclosed operator decision: B8.b deferral acceptance).

Audit (delegated to sub-agent — full reasoning at this doc's summary block) returns clean structural verdict: Pattern B exemplary, scope matches ledger row 66 + Path A pick (L_A1 + L_A2 prerequisites both merged), `advisor_proxy.dart` literally 0-line diff (headroom 88 preserved via sibling-file mount pattern in `tool/advisor_proxy/audit_log_hierarchy_routes.dart`), RLS posture correct (`withTenant` via `OperatorScopedRepository`), append-only read path (no `audit_logs` writes), 73/73 tests pass, no migration, frozen paths untouched.

## The 1 genuine hold — worker-disclosed operator decision

The PR title self-flagged `[operator-approval-required]`. The worker disclosed **6 honest deferral decisions** that constitute the actual operator decision point:

1. **B8.b: Operator-web parity deferred.** Operator-web `audit_log_screen.dart` is 1,416 LoC and would balloon past the 1,665 LoC operator-web ceiling if the hierarchy filter were inlined; worker shipped admin-side only.
2. Operator-web hierarchy route NOT shipped (admin route only).
3. L_A2 cache primitive deliberately bypassed (Option b chosen per L_A1 framing — "performance projection, not structural prereq").
4. Per-pod latency recorder only (cross-pod aggregation = future slice).
5. No CSV export on admin screen.
6. InheritanceTree picker is opt-in (admin shell needs OrgUnits gateway slice for `rootNode` feed).

All 6 disclosures are **forward-looking, none silent**. The operator decision is:
- **Option 1:** approve + merge as-is. Accept B8.b deferral → adds new ledger row for operator-web parity (~500–800 LoC follow-up).
- **Option 2:** send back to extend inline. ~4,500–5,000 LoC Large slice with scope-balloon risk.

**Recommendation:** Option 1 (approve + merge). The deferral keeps the slice focused; B8.b becomes a clean own-slice that can re-use the same repository reader.

## Pattern B compliance

**✓ EXEMPLARY** — worker 14-lens table + executor 14-lens table both present in PR body with file:line citations:
- `audit_logs_repository.dart:457` — `withTenant` binding inside `AuditLogsReader.listByHierarchy`
- `tool/advisor_proxy/audit_log_hierarchy_routes.dart:110-111` — role gate `{super_admin, ff_support}`
- `tool/advisor_proxy/main.dart:1635` — sibling-file pre-check mount BEFORE `routeRequest`

## What landed (12 files / +3775 / -1)

| File | LoC | Kind |
|---|---|---|
| `tool/advisor_proxy/audit_log_hierarchy_routes.dart` | +598 / 0 | **NEW — sibling-file route handler** (NOT inlined in `advisor_proxy.dart`); `/v1/admin/auth/audit-log/hierarchy` |
| `tool/advisor_proxy/main.dart` | +43 / 0 | EXTEND — pre-check mount via `auditLogHierarchyRouter.tryHandle(request)` BEFORE `routeRequest`; region/endregion markers labeled `lane_b_b8_audit_log_hierarchy_filter`; comment at line 1615 explicitly states "advisor_proxy.dart is intentionally NOT touched (bleed-stop ceiling discipline)" |
| `tool/advisor_proxy/proxy_bootstrap.dart` | +28 / 0 | EXTEND — wire the router with admin-pool dependencies + role gate + latency recorder |
| `lib/admin/screens/audit_log_admin_screen.dart` | +597 / 0 | NEW — admin hierarchy-filter screen |
| `lib/admin/services/audit_log_admin_gateway.dart` | +323 / 0 | NEW — gateway wrapping the new route |
| `lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart` | +297 / 0 | EXTEND — `AuditLogsReader` extends `OperatorScopedRepository`; new `listByHierarchy` method; **read-only (no INSERT/UPDATE/DELETE on `audit_logs`)** |
| `tool/pressure/p4_audit_log_hierarchy_filter.dart` | +219 / 0 | NEW — library (latency recorder + bucket math); not a CLI |
| 5 test files | +1,670 / -1 | NEW + EXTEND — 73 tests total |

## Critical safety guarantees (executor-verified)

| Guarantee | Verification |
|---|---|
| `tool/advisor_proxy/advisor_proxy.dart` UNTOUCHED | ✓ — `git diff origin/master -- tool/advisor_proxy/advisor_proxy.dart` returns 0 lines; **bleed-stop ceiling preserved at 88 headroom** (19,812 → 19,812) |
| `lib/auth/` UNTOUCHED | ✓ — 0 lines |
| `db/migrations/` UNTOUCHED | ✓ — 0 lines |
| `pubspec.yaml` UNTOUCHED | ✓ — 0 lines |
| `WAVE_EXECUTION_LEDGER.md` UNTOUCHED | ✓ — 0 lines |
| Route is auth-gated | ✓ — Bearer JWT via `AuditLogHierarchyAuthResolver` (closure over `ProxyRequestGuard.requireOperatorContext`) + role gate `{super_admin, ff_support}` + required `admin_reason` header (400 if missing) |
| Repository extends `OperatorScopedRepository` | ✓ — `audit_logs_repository.dart:397` |
| `withTenant` clamps RLS via `SET LOCAL app.operator_id` BEFORE the SELECT | ✓ — `audit_logs_repository.dart:457` |
| Reader is append-only-safe (no `audit_logs` writes) | ✓ — `audit_logs_update_lint` clean per PR body |
| `withSystem` NOT used | ✓ — admin reads ride tenant context, not system bypass |
| 73/73 tests pass | ✓ disclosed |
| 3 lints clean (`dart analyze --fatal-infos`, `advisor_proxy_size_lint`, `postgres_import_lint`) | ✓ disclosed |
| Sibling-file mount pattern correct | ✓ — `main.dart:1635` pre-check returns BEFORE `routeRequest`; mirrors C-1 SendGrid + B11.2.b step-up precedent |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — row 66 scope matches |
| **Worker disclosed something operator should know** | **✓ TRIGGERED — 6 forward-looking deferrals, including B8.b operator-web parity. Operator must accept the deferral framing.** |
| Stacked PR | ❌ — base is master (baseRefOid `f9bc84fd` — predates Bundle 49 merges; mergeable=CLEAN per GitHub) |
| RLS + proxy + auth-critical surface | ✓ TRIGGERED — title self-flagged |

**Decision**: **HOLD for explicit operator decision on B8.b deferral acceptance.**

## Cross-lane notes

- **Sibling-file pattern preserved bleed-stop ceiling.** `advisor_proxy.dart` literally 0-line diff. `tool/advisor_proxy/audit_log_hierarchy_routes.dart` is the new home; main.dart's pre-check mount returns early before the monolith handler. Pattern mirrors C-1 SendGrid Event Webhook + B11.2.b step-up.
- **Triple trifecta gates honored.** Auth-critical (admin endpoint) + RLS-touching (`withTenant`) + proxy-touching (3 `tool/advisor_proxy/` files) — explicit operator approval required per CLAUDE.md regardless of audit verdict.
- **Base is f9bc84fd (Bundle 48 tip).** Mergeable CLEAN against current master post-Bundle 49; no cutoff-doc conflicts (B8 ships no migration).

## Findings

None blocking. One operator decision: accept B8.b deferral (open new ledger row for operator-web parity) or send back to extend inline. Recommendation: Option 1 (approve + merge).

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 66 — B8 ledger row (Path A pick; L_A1 + L_A2 merged)
- `docs/_execution/lane_b_hierarchy_finalization/` — B8 slice spec
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — `OperatorScopedRepository` + `withTenant` pattern
- `docs/_audits/post_codex_wave/pr_608_l_a1_inheritance_tree_primitive_audit.md` — L_A1 prerequisite
- `docs/_audits/post_codex_wave/pr_616_l_a2_inheritance_descendant_cache_audit.md` — L_A2 prerequisite (bypassed per Option b)
- `docs/_audits/post_codex_wave/pr_611_c_1_sendgrid_events_webhook_audit.md` — sibling-file mount precedent
- CLAUDE.md "Agent-Led Slices" + "Architecture Guardrails" (bleed-stop discipline)

## Status

**HELD for operator decision.** Audit verdict approve-on-sign-off (B8.b deferral acceptance).
