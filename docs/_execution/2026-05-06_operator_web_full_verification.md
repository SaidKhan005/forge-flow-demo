# Operator Web Console Full Preview Verification

Date: 2026-05-06
Worktree: `C:\Git Local Repos\forge_flow_demo\.codex_worktrees\operator-web-full-verification`
Branch: `codex/operator-web-full-verification`
Source commit: `855d1f0b68d7d5d5011244ce4d4cc52ea8579543`

## Deployment Record

`origin/master` was fetched before the worktree was created and was confirmed at `855d1f0b68d7d5d5011244ce4d4cc52ea8579543`.

| Surface | Service | URL | Revision | Traffic | Source / image |
| --- | --- | --- | --- | --- | --- |
| Operator web | `forge-flow-preview-backend-surface-additions-operator-web` | `https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-operator-00007-6v7` | 100% | `northamerica-northeast2-docker.pkg.dev/forge-flow-staging/forge-flow-cloud-run/forge-flow-preview-backend-surface-additions-operator-web:20260506144031` |
| Preview proxy | `forge-flow-preview-backend-surface-additions-proxy` | `https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-proxy-00012-q86` | 100% | `northamerica-northeast2-docker.pkg.dev/forge-flow-staging/cloud-run-source-deploy/forge-flow-preview-backend-surface-additions-proxy@sha256:2d2e0e2b91ec3986c37c81fe12abf117d02eb2d617ae435cfb10e6775e1def7c` |
| Preview admin | `forge-flow-preview-backend-surface-additions-admin` | `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-admin-00004-wgx` | 100% | `northamerica-northeast2-docker.pkg.dev/forge-flow-staging/forge-flow-cloud-run/forge-flow-preview-backend-surface-additions-admin:20260506143119` |

Database mode: preview Cloud Run services reference `forge-flow-staging-` Secret Manager values for Postgres and Firebase runtime configuration, so live preview smoke was kept read-only. Demo-mode Browser evidence exercised safe setup and mutation-like flows against in-memory fixtures only.

Proxy/operator alignment:

- Operator self-service account, team, roles, hierarchy, session, audit, MFA, password, and security gateways use `/v1/auth/*`.
- Vendor connections currently use the routed Phase 8 admin-prefixed integration endpoints (`/v1/admin/integrations/*` and `/v1/admin/operators/:operator_id/locations/:location_id/integrations`). These remain permission-gated by `integrations.configure`; `location_manager` behavior stays read-only/denied where required.
- Final proxy CORS preflight from the operator origin to `/v1/auth/account` returned 204 and echoed the operator origin.

## Framework Checklist

UX Adjustment Framework:

- Setup clarity: verified signed-out shell, account setup, password setup, MFA artifact, terms acceptance, account landing, business setup, and business timing in Browser demo mode.
- Lifecycle/state copy: verified loading/empty/forbidden/error state coverage through operator widget tests and route sweep; no live write states were triggered against staging-backed preview.
- Roles copy and permission explanations: verified roles route, permission explainer entry point, seeded read-only roles, custom role actions, idempotency, and `location_manager` read-only behavior in tests. Fixed mobile Roles header collapse.
- Human-readable labels and metadata: fixed browser metadata title drift by making the app shell use the plain hyphen title, `Forge & Flow - Operator Web Console`.
- Mobile responsiveness: Browser route sweep covered narrow operator routes; Roles header was captured before and after the fix.

Performance Framework:

- Startup cost: final enforced probe passed for operator web index/main JS and proxy readyz.
- Duplicate requests / route switching / refresh behavior: Browser local route sweep changed routes repeatedly with warning/error logs captured per route; widget tests cover manual refresh and route state rendering.
- Bounded lists and polling: route screens use demo/fixture bounded lists in demo mode; no repeated polling loop was observed in Browser logs.
- Evidence JSON: `build\perf_gate\operator_web_full_verification_final_00007.json`.
- Note: an earlier final probe had one transient `admin_index_c1` p95 spike (`842.1ms > 750ms`); the rerun and final revision probe both passed enforced budgets.

Mobile Web Console E2E Framework:

- Browser Use was run with fresh cache-bust URLs.
- Live preview signed-out shell loaded with title `Forge & Flow - Operator Web Console` and zero captured page warnings/errors.
- Authenticated live preview route sweep was blocked by unavailable valid smoke credentials; no staging-backed writes were attempted.
- Safe read-only and setup-like flows were exercised in operator web demo mode with local fixture data.
- Mobile notification tap behavior was not executed live because there was no safe authenticated mobile notification session. Mobile push route and sender tests were included in the broad proxy/service suite.

## Browser Evidence

Evidence root: `build\reports\operator_web_full_verification`

| Route / surface | Evidence |
| --- | --- |
| Live preview signed-out shell | `browser_preview_final_00007_shell.png`, `browser_preview_final_00007_shell.dom.txt`, `browser_preview_final_00007_shell.logs.json` |
| Onboarding welcome | `browser_local_demo_welcome.png`, `browser_local_demo_welcome.logs.json` |
| Password setup | `browser_local_demo_password.png`, `browser_local_demo_password.logs.json` |
| MFA setup | `browser_local_demo_mfa.png`, `browser_local_demo_mfa_artifact.png`, `browser_local_demo_mfa.logs.json` |
| Terms and Conditions | `browser_local_demo_terms.png`, `browser_local_demo_terms.logs.json` |
| Account setup / account home | `browser_local_demo_account.png`, `browser_local_demo_account.logs.json` |
| Business setup and business timing | `browser_local_demo_business_setup.png`, `browser_local_demo_business_setup.logs.json` |
| Members | `browser_local_demo_members.png`, `browser_local_demo_members.logs.json` |
| Roles before fix | `browser_local_demo_roles.png`, `browser_local_demo_roles.logs.json` |
| Roles after fix | `browser_local_demo_roles_after_fix.png`, `browser_local_demo_roles_after_fix.logs.json` |
| Locations and hierarchy | `browser_local_demo_locations.png`, `browser_local_demo_locations.logs.json` |
| Sessions | `browser_local_demo_sessions.png`, `browser_local_demo_sessions.logs.json` |
| Audit log | `browser_local_demo_audit_log.png`, `browser_local_demo_audit_log.logs.json` |
| Security / MFA settings | `browser_local_demo_security.png`, `browser_local_demo_security.logs.json` |
| Vendor connections | `browser_local_demo_vendor_connections.png`, `browser_local_demo_vendor_connections.logs.json` |
| Data accuracy | `browser_local_demo_data_accuracy.png`, `browser_local_demo_data_accuracy.logs.json` |
| Route sweep summary | `browser_local_demo_route_sweep.json` |

All listed final route screenshots had zero captured page warning/error logs.

## Bugs Found And Fixed

1. Operator web app title used an em dash while the static shell and UX contract expect plain, readable metadata. Fixed `lib/operator_web/operator_web_app.dart` and added `test/operator_web/operator_web_app_test.dart`.
2. Preview operator deploys could leave the preview proxy without the newly deployed operator origin in `ADMIN_CORS_ALLOWED_ORIGINS`, causing `/v1/auth/account` preflight failure from the operator shell. Fixed `scripts/deploy_operator_web.ps1` to infer the matching preview proxy, merge CORS origins, prefer `gcloud.ps1` for PowerShell env-var escaping, update the proxy env with a comma-safe delimiter, and verify `/v1/auth/account` preflight. Added `test/deploy_operator_web_contract_test.dart`.
3. Roles header collapsed into one-letter vertical text on narrow screens when the title/subtitle competed with the action buttons. Fixed `lib/operator_web/screens/roles_screen.dart` with responsive stacking under 560 px and added a narrow-header regression test in `test/operator_web/screens/roles_screen_test.dart`.

## Gated Or Intentionally Unsurfaced Items

- Live preview write flows were not executed because the preview uses `forge-flow-staging-` secrets.
- Backend-only or incomplete capabilities were documented/left gated rather than surfaced with invented UI.
- Vendor connection writes remain permission-gated; read-only/denied behavior for `location_manager` and forbidden users is preserved by role/auth tests.
- Shift service-period selector unavailable/fallback behavior is not a standalone operator-web route. Related business timing UI was visually checked in demo mode, and service-period primary driver tests passed.
- Mobile notification tap behavior was not live-tested without a safe authenticated notification session; proxy mobile push and sender tests passed.

## Verification

Final focused gates:

```powershell
flutter analyze
flutter test test\operator_web test\deploy_operator_web_contract_test.dart
flutter test test\deploy_operator_web_contract_test.dart test\proxy\auth_cors_routes_test.dart test\proxy\admin_cors_routes_test.dart
flutter build web --release --target=lib\main_operator_web.dart --dart-define=OPERATOR_WEB_PROXY_BASE_URI=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --dart-define=OPERATOR_WEB_DEMO_AUTH=false --pwa-strategy=none
flutter build web --release --target=lib\main_operator_web.dart --output=build\operator_web_demo --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none
dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-additions-operator-00007-6v7 --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00012-q86 --label=operator-web-full-verification-final-00007 --write-json=build\perf_gate\operator_web_full_verification_final_00007.json
```

Results: all final focused gates passed. The final operator suite reported 267 passing tests; the final CORS/proxy contract suite reported 26 passing tests.

Broader proxy, role/auth, health, observability, data accuracy, integration, mobile push, and service-period sweep:

```powershell
flutter test test\deploy_staging_proxy_contract_test.dart test\deploy_operator_web_contract_test.dart test\permission_runtime_test.dart test\permission_gate_test.dart test\team_ux_kernel_test.dart test\admin\forge_admin_role_check_test.dart test\admin_auth_gate_test.dart test\operator_web\operator_web_router_test.dart test\operator_web\screens\members_screen_test.dart test\operator_web\screens\roles_screen_test.dart test\operator_web\screens\hierarchy_screen_test.dart test\operator_web\screens\sessions_screen_test.dart test\operator_web\screens\audit_log_screen_test.dart test\operator_web\screens\security_screen_test.dart test\operator_web\screens\vendor_connections_screen_test.dart test\proxy\auth_cors_routes_test.dart test\proxy\admin_cors_routes_test.dart test\proxy_auth_operations_route_test.dart test\proxy_auth_operations_route_grants_test.dart test\proxy_auth_operations_gateway_test.dart test\proxy_auth_operations_gateway_grants_test.dart test\proxy_account_info_gateway_test.dart test\proxy_permission_snapshot_loader_test.dart test\proxy_password_change_gateway_test.dart test\proxy_mfa_operations_gateway_test.dart test\proxy_auth_session_ledger_writer_test.dart test\proxy_integration_admin_routes_test.dart test\proxy\data_accuracy_admin_routes_test.dart test\proxy\mobile_push_routes_test.dart test\services\mobile_push_sender_test.dart test\proxy\advisor_proxy_health_envelope_test.dart test\proxy\registry_proxy_health_check_store_test.dart test\admin\health_admin_gateway_test.dart test\admin\health_admin_screen_test.dart test\admin\observability_admin_screen_test.dart test\services\shift_service_period_primary_driver_test.dart
```

Result: pass, 510 tests. No mobile push source was touched, so the APK debug build gate was not required.

## Residual Risks

- Live authenticated route sweep remains blocked until a valid preview smoke account is available or an operator approves exact action-time setup.
- Live preview remains backed by staging secrets, so mutation behavior was verified through unit/widget/proxy tests and demo-mode Browser evidence rather than live writes.
- Browser evidence confirms rendered route states, but does not replace backend contract coverage for permission-gated write paths.
