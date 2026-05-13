# PR #635 Audit — B8.b Operator-Web Hierarchy Filter Parity + Orchestrator Inline Fix (Claude)

**Slice:** B8.b (Lane B — operator-web parity follow-up to B8)
**Owner:** Claude (orchestrator-dispatched agent) + Claude (orchestrator inline fix)
**Branch:** `claude/b8-b-operator-web-audit-log-hierarchy-parity` (rebased onto master)
**Base:** `master` @ `55bbacc3` (post-C-7)
**Gate:** **operator-approval-required** — proxy-touching (sibling-file decompose) + auth-critical (operator-facing audit log read with `team.audit_log.view` gate)
**Risk:** **Low** — sibling-file decompose (advisor_proxy.dart 0-line diff, headroom preserved); reuses B8's `AuditLogsReader.listByHierarchy`; orchestrator-applied router wiring fix closes the worker's disclosed deferral inline
**Size:** 3060 additions / 0 deletions / 12 files (3008 from worker + 52 from orchestrator inline fix)

## Verdict

**approve-for-merge** — auto-merged at master `63b67753` per operator's 2026-05-13 "B8 path (a) approve + accept deferral" pick, with orchestrator inline fix promoting the deferral to full shipment.

## Pattern B compliance

**✓ EXEMPLARY** — worker shipped 14-lens self-audit; orchestrator inline fix commit body adds its own justification + file:line citations to the B6 `_benchmarksGateway` pattern that was mirrored.

## What landed (worker's deliverable)

| File | LoC | Kind |
|---|---|---|
| `lib/operator_web/screens/audit_log_screen.dart` | +35 / 0 | EXTEND — adds 2 optional constructor params + 11-line guarded mount block for `AuditLogHierarchyFilterPane` |
| `lib/operator_web/screens/audit_log_hierarchy_filter_pane.dart` | +647 / 0 | **NEW** — sibling pane (file-decomposition for operator-web ceiling discipline); houses the hierarchy picker + filtered ledger view |
| `lib/operator_web/services/web_audit_log_hierarchy_gateway.dart` | +318 / 0 | **NEW** — operator-web gateway: HTTP impl + InMemory impl + `WebAuditLogHierarchyGatewayError` + `WebAuditLogHierarchyListCommand`/`Result`/`Row` value classes + `WebAuditLogHierarchyScopeType` enum |
| `tool/advisor_proxy/operator_web_audit_log_hierarchy_routes.dart` | +518 / 0 | **NEW** — sibling-file proxy route handler (`/v1/auth/audit-log/hierarchy`); mounts via pre-check in `main.dart` |
| `tool/advisor_proxy/main.dart` | +30 / 0 | EXTEND — pre-check mount via `operatorWebAuditLogHierarchyRouter.tryHandle(request)` before `routeRequest`; region/endregion marker `lane_b_b8_b_operator_web_audit_log_hierarchy_filter` |
| `test/proxy/operator_web_audit_log_hierarchy_routes_test.dart` | +594 / 0 | NEW — 29 route tests (auth gate, role gate, tenant clamp, query params, response shape, RLS posture) |
| `test/operator_web/services/web_audit_log_hierarchy_gateway_test.dart` | +160 / 0 | NEW — 10 gateway tests |
| `test/operator_web/screens/audit_log_hierarchy_filter_pane_test.dart` | +233 / 0 | NEW — 5 pane widget tests |
| `test/operator_web/screens/audit_log_screen_test.dart` | +12 / 0 | EXTEND — pane-mount integration tests |
| `tool/advisor_proxy/proxy_bootstrap.dart` | +9 / 0 | EXTEND — `operatorWebAuditLogHierarchyGateway` field on `ProxyProductionBindings` |
| (orchestrator fix below) | | |

## What landed (orchestrator inline fix, commit `aa7dc52f`)

| File | LoC | Kind |
|---|---|---|
| `lib/operator_web/services/web_audit_log_hierarchy_gateway.dart` | +9 / 0 | ADD — `OperatorWebAuditLogHierarchyGatewayProvider` abstract mixin (mirrors B6's `OperatorWebBenchmarksGatewayProvider` shape) |
| `lib/operator_web/services/operator_web_team_gateway_providers.dart` | +18 / 0 | ADD — re-export the new provider mixin + all gateway value classes from one canonical registration index |
| `lib/operator_web/router/operator_web_router.dart` | +25 / 0 | ADD — `_auditLogHierarchyGateway` getter (live via provider mixin; demo via `InMemoryWebAuditLogHierarchyGateway` fallback); `_routerOwnedDemoAuditLogHierarchyGateway` lazy field; `AuditLogScreen` constructor wires `hierarchyGateway:` + `teamHierarchyGateway:` |

**Net effect:** the B8.b hierarchy filter pane now renders in production. Live operator-web users see a hierarchy-scoped audit log filter (when the auth source mixes in `OperatorWebAuditLogHierarchyGatewayProvider`; otherwise falls back to in-memory demo data). Reuses B8's `AuditLogsReader.listByHierarchy` so no new DB query path.

## Critical safety guarantees

| Guarantee | Verification |
|---|---|
| `tool/advisor_proxy/advisor_proxy.dart` UNTOUCHED | ✓ 0-line diff; **bleed-stop ceiling preserved at headroom 23** (same as post-C-7) |
| `lib/auth/**` UNTOUCHED | ✓ 0-line diff; uses existing `team.audit_log.view` permission key |
| `db/migrations/**` UNTOUCHED | ✓ — reuses B8's reader; no new schema |
| `pubspec.yaml` UNTOUCHED | ✓ |
| `WAVE_EXECUTION_LEDGER.md` UNTOUCHED | ✓ (orchestrator's job at merge) |
| `audit_logs` writes UNTOUCHED | ✓ — pane is read-only |
| Route is sibling-mounted before `routeRequest` | ✓ — `main.dart` pre-check returns early |
| Auth gate is correct | ✓ — Bearer JWT verification via `authGuard.requireOperatorContext`; tenant scope clamped from JWT (operator_id/location_id query params rejected to prevent cross-tenant leak); `team.audit_log.view` permission check via `ProxyPermissionSnapshotResolver` |
| HTTP status codes correct | ✓ — 401 on missing JWT, 403 on missing permission, 503 on snapshot read failure, 400 on tenant-scope-bleed attempt |
| RLS clamp via `withTenant` | ✓ — reuses B8's `AuditLogsReader.listByHierarchy:457` (verified during B8 audit) |
| Operator-web ceiling discipline | ✓ — `audit_log_screen.dart` 1,329 → 1,364 (+35 LoC, well under the ~1,665 budget); hierarchy filter pane went into a sibling file (decompose choice) |
| 27 widget + 10 gateway + 29 route + 5 pane tests pass | ✓ disclosed (101 tests total; re-verified post-orchestrator-fix at 27/27 audit_log_screen + 14/14 hierarchy pane = 41 targeted) |
| `dart analyze` clean | ✓ disclosed (1 pre-existing info on untouched `integration_oauth_routes.dart` not a regression) |
| All 7 lints clean (advisor_proxy_size, postgres_import, audit_logs_update, migration_drift_scanner, migration_cutoff_lint, rls_policy_lint, index_leading_column_lint) | ✓ disclosed |
| Orchestrator inline fix wiring matches B6 pattern verbatim | ✓ — `_auditLogHierarchyGateway` getter at `operator_web_router.dart:1287-1301` mirrors `_benchmarksGateway` at `:1268-1275` |
| No `--no-verify` traces | ✓ |

## Worker disclosure → orchestrator inline fix

Worker disclosed: *"Router wiring deferred. `operator_web_router.dart` is not edited — the gateways are not yet constructed in either the live or demo router branches. The pane mounts only when both gateways are supplied; without them the existing screen renders identically. Thin (~40 LoC) follow-up needed to expose the pane to operators."*

Per operator's "(a) orchestrator-fix inline" pick, orchestrator applied the wiring in commit `aa7dc52f`:
- Added `OperatorWebAuditLogHierarchyGatewayProvider` mixin (mirrors B6 pattern verbatim)
- Re-exported from canonical `operator_web_team_gateway_providers.dart` index
- Added `_auditLogHierarchyGateway` getter on router (live via provider mixin; demo via `InMemoryWebAuditLogHierarchyGateway` fallback)
- Wired both `hierarchyGateway:` + `teamHierarchyGateway:` into `AuditLogScreen` constructor

Net: feature ships visible. Live HTTP wiring on the Firebase auth source remains a small follow-up (1 mixin import + 1 constructor call) and is non-blocking — the existing pane renders against in-memory data on unmixed sources.

## Genuine safety holds — checked

| Hold | Status |
|---|---|
| Migration applied | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — B8.b is a NEW row (added during bundle 49 prep when operator accepted B8 deferral) |
| Worker disclosed something operator should know | ✅ TRIGGERED + RESOLVED — orchestrator inline fix promotes the deferred wiring to shipment |
| Stacked PR | ❌ — rebased onto current master |
| Auth-critical / proxy-touching | ✅ TRIGGERED — operator pre-approved per 2026-05-13 pick |

**Decision**: auto-merged per expanded delegation + operator pick.

## Triple-safeguard

- ✅ Merge commit at master `63b67753`
- ✅ Ancestor verified
- ✅ `OperatorWebAuditLogHierarchyRouter` symbol confirmed on master in `tool/advisor_proxy/operator_web_audit_log_hierarchy_routes.dart`
- ✅ `_auditLogHierarchyGateway` getter confirmed on master in `lib/operator_web/router/operator_web_router.dart`

## Cross-lane notes

- **Closes B8.b** — last Lane-B hierarchy-finalization slice on the wave roadmap. Operator-web parity for hierarchy filter is now LIVE.
- **C-12 closeout now spawnable** — was waiting on C-7 + B8.b + C-2-D-binding to land. All present.
- **Reuse pattern wins**: B8's `AuditLogsReader.listByHierarchy` (Lane B B8 PR #624) is now consumed by both admin (B8) and operator-web (B8.b) without DB-side duplication.
- **Live HTTP wiring**: small follow-up (1 mixin import + gateway construction on Firebase auth source) — non-blocking; pane renders in demo today.

## Findings

None blocking.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` — new B8.b row (added in this bundle)
- `docs/_audits/post_codex_wave/pr_624_b8_audit_log_hierarchy_filter_audit.md` — B8 admin-side precedent + deferral disclosure
- `docs/_audits/post_codex_wave/pr_634_b6_benchmark_overrides_decompose_audit.md` — B6 router-getter pattern mirrored
- `lib/operator_web/router/operator_web_router.dart:1268-1275` (`_benchmarksGateway`) — exact pattern reference
- CLAUDE.md "Architecture Guardrails" (operator-web ceiling) + "Agent-Led Slices"
- Operator's 2026-05-13 "1 a" pick (B8.b path: orchestrator-fix inline + merge)

## Status

**Merged.** Master `63b67753`. B8.b shipped with feature visible (not gated behind unmixed providers).
