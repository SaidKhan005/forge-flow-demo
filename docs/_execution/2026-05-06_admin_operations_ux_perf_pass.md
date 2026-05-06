# Admin Operations UX And Performance Pass

Date: 2026-05-06  
Worktree: `.codex_worktrees/admin-console-full-verification`  
Branch: `codex/admin-console-full-verification`

## Source

- Worktree source commit: `c03ac0d8fd549264f0fd113e27d07987105c9b8c`
- UX/perf simplification commits in this pass:
  - `37f1a67b` - simplify Operations route context, labels, and scoped-route loading.
  - `c03ac0d8` - carry primary location scope from operator action buttons.
- Worktree merge base used for this pass: `52ac1f4c501d2db4e23782394d6db19d0efff4e5`.
- `origin/master` after final fetch: `8aa8ebfa74f5b12ab11e2f9f102cc98e0e0afac6`. This advanced after the verified worktree was created and was not merged again, to keep the deployed preview evidence tied to `c03ac0d8`.

## Preview Deployment

- Command:
  `powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 -PreviewName backend-surface-additions -SkipApiEnable -SkipSecretManagerSync`
- Admin URL: `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app`
- Proxy URL: `https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app`
- Admin revision: `forge-flow-preview-backend-surface-additions-admin-00016-5hr`, traffic 100 percent.
- Proxy revision: `forge-flow-preview-backend-surface-additions-proxy-00037-8tp`, traffic 100 percent.
- Admin Cloud Build ID: `75cce8a8-86e0-49e8-982f-1e57f9704664`.
- Admin image tag: `northamerica-northeast2-docker.pkg.dev/forge-flow-staging/forge-flow-cloud-run/forge-flow-preview-backend-surface-additions-admin:20260506193951`.
- Database mode: staging secrets/shared staging data. Browser verification stayed read-only despite mutation approval because no write was needed to prove the UX/perf fixes.
- Deploy wrapper result: admin deployed successfully, but the wrapper exited non-zero at the final admin-auth CORS check because `OPTIONS /v1/admin/auth/users` returned 404 from the live proxy.

## Framework Results

UX Adjustment Framework:
- Operations labels are shorter and consistent: `Team`, `Access`, `Audit & support`.
- Operator action flow is now logical: selecting Data accuracy or Polling & pricing from an operator carries `Barrio Legado / 95 Water Street` into the scoped Operations route context.
- Team, Access, and Audit no longer force a fresh picker when a valid operator/location context already exists.
- Empty scoped routes now explain the next step inline with a single `Choose operator` action instead of opening a full-screen picker immediately.
- Data Accuracy override dialog was opened and canceled; confirmation copy and reason field were readable and no write was submitted.

Performance Framework:
- Members, Access, and Audit startup fetches were parallelized where the backend calls are independent.
- Members search now debounces rapid typing before refreshing.
- Stale async responses are guarded so older refreshes do not overwrite newer screen state.
- Heavy health/metrics routes still render read-only prompts before running live checks; no heavy automatic refresh was observed.
- Final perf JSON: `build\perf_gate\admin_console_ops_ux_final_20260506T1957.json`.

Mobile Web Console E2E Framework:
- Browser Use fresh URL: `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app/?cache_bust=ops-ux-final-c03ac0d8-20260506T1951`
- Page title verified: `Forge & Flow Admin Console`.
- App console warning/error logs: none captured by Browser Use route summaries.
- Browser Use emitted tool-side Statsig warnings from the automation runtime during the long sweep; those were not app console logs.
- Flutter web exposes limited semantic DOM in the in-app browser, so evidence is screenshot-first.

## Route Evidence

- Operators: loaded, search and operator cards visible, selected `Barrio Legado`, primary location `95 Water Street`, action buttons reachable.
- Data Accuracy: operator button opened scoped view for `Barrio Legado / 95 Water Street`; override dialog opened and canceled.
- Polling & Pricing: scoped view retained `Barrio Legado / 95 Water Street`; tier definitions and assignments were visible.
- Team: scoped to `Barrio Legado`, but live fetch failed against `/v1/admin/auth/invites` because of the admin-auth proxy fetch/CORS runtime issue.
- Access: scoped to `Barrio Legado`, but live fetch failed against `/v1/admin/auth/roles` for the same runtime issue.
- Audit & support: scoped to `Barrio Legado`, but live fetch failed against `/v1/admin/auth/audit-log` for the same runtime issue.
- Post-fix verification on proxy revision `forge-flow-preview-backend-surface-additions-proxy-00045-86b`: Team shows `5 rows`; Access > Sessions shows `4 sessions`; Audit & support shows audit rows. Browser app console warning/error logs were empty.
- Plans and limits: loaded operator plan list and selected operator details.
- Knowledge base: loaded content version, relationship-review tab remained reachable.
- Connected services: loaded service access and vendor integration documentation state.
- Launch controls: loaded feature flags with high-impact labels and enable/disable affordances; no toggle submitted.
- System health: loaded read-only health prompt and run button.
- Support logs: loaded filters, live refresh toggle, and empty state.
- System metrics: loaded read-only metrics prompt and run button.

## Bugs Found And Fixed

- The Operations route set felt disjointed because Team/Access/Audit behaved like separate destinations instead of a flow. Fixed by keeping shared operator/location context across those scoped routes.
- Operator-level Data Accuracy and Polling & Pricing buttons carried only operator ID, so subsequent Team/Access/Audit navigation still had to ask for a location. Fixed by passing the operator's primary/fallback location scope from those buttons.
- Members search refreshed too aggressively while typing. Fixed with a short debounce.
- Members, Access, and Audit did independent requests sequentially on startup. Fixed with bounded parallel fetches and stale-response guards.

## Intentionally Gated Or Unsurfaced

- Mobile push status/test surfaces were not visible in this admin route table, so no UI was invented.
- Feature flags, provider key rotation, corpus upload/commit, role writes, member invites, and support actions were inspected as gated/high-impact controls but not submitted in this pass.
- The preview uses staging secrets; even with mutation approval, no mutating action was necessary for this UX/perf verification.

## Tests And Builds

Passed:
- `flutter analyze`
- `flutter test test\admin_shell_widget_test.dart` - 12 tests
- `flutter test test\admin` - 358 tests
- `flutter test test\proxy\admin_cors_routes_test.dart` - 20 tests
- `flutter test test\deploy_staging_proxy_contract_test.dart` - 18 tests before the post-fix; 19 tests after adding the traffic-promotion contract.
- `flutter build web --release --target=lib\main_admin.dart --dart-define=ADMIN_PROXY_BASE_URI=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --pwa-strategy=none`
- `dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-additions-admin-00016-5hr --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00037-8tp --label=ops-ux-perf-final-20260506 --write-json=build\perf_gate\admin_console_ops_ux_final_20260506T1957.json --include-health`
- Post-fix targeted gates:
  - `flutter test test\proxy_auth_operations_route_test.dart` - 47 tests
  - `flutter test test\deploy_staging_proxy_contract_test.dart` - 19 tests
  - `flutter test test\proxy\admin_cors_routes_test.dart` - 20 tests
  - `flutter analyze tool\advisor_proxy\advisor_proxy.dart test\proxy_auth_operations_route_test.dart scripts\deploy_staging_proxy.ps1 test\deploy_staging_proxy_contract_test.dart`

Perf summary:
- `admin_index_c1`: p50 64.7 ms, p95 392.9 ms, errors 0.0 percent.
- `admin_index_c4`: p50 64.2 ms, p95 187.2 ms, errors 0.0 percent.
- `admin_mainjs_gzip_c4`: p50 878.0 ms, p95 1206.8 ms, errors 0.0 percent, bytes 1173993.
- `proxy_readyz_c1`: p50 65.1 ms, p95 229.9 ms, errors 0.0 percent.
- `proxy_readyz_c4`: p50 65.4 ms, p95 186.6 ms, errors 0.0 percent.
- Optional `proxy_health_c1_safe`: 2/3 successful, one timeout/non-2xx sample; probe exited 0 with warning.

## Residual Risks

- Resolved after the post-fix: live proxy revision `forge-flow-preview-backend-surface-additions-proxy-00045-86b` now serves 100 percent of traffic and returns 204 for admin-auth preflights on `/v1/admin/auth/users`, `/v1/admin/auth/roles`, `/v1/admin/auth/sessions`, and `/v1/admin/auth/audit-log`.
- Resolved after the post-fix: Cloud Run logs on revision `00045-86b` show GET 200 for `/v1/admin/auth/users`, `/v1/admin/auth/sessions`, and `/v1/admin/auth/audit-log` from the preview admin flow.
- The optional deep health perf sample timed out once; readyz and admin startup budgets passed.
- Browser evidence is visual because Flutter web exposes limited semantic DOM in the in-app browser.

## Post-Fix Admin Auth Route Closeout

- Source code/deploy commit: `9ebcdddd` (`fix(proxy): route admin auth sessions and audit log`)
- Admin URL: `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app`
- Proxy URL: `https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app`
- Admin revision: `forge-flow-preview-backend-surface-additions-admin-00016-5hr`, traffic 100 percent.
- Proxy revision: `forge-flow-preview-backend-surface-additions-proxy-00045-86b`, traffic 100 percent.
- Database mode: staging secrets/shared staging data.
- Fresh Browser Use URL: `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app/?cache_bust=proxy-routes-fixed-00045-86b-20260506T2055`
- Direct preflight evidence from the preview admin origin: `/v1/admin/auth/users` 204, `/v1/admin/auth/roles` 204, `/v1/admin/auth/sessions` 204, `/v1/admin/auth/audit-log` 204.
- Browser Use evidence: Team loaded member cards (`5 rows`); Access loaded Roles and Sessions (`4 sessions`); Audit & support loaded action controls and audit rows. App console warning/error logs were empty for the checked screens.
- Bugs fixed: deploy script now promotes Cloud Run source deploy traffic to the latest ready revision; proxy now routes admin auth sessions, admin auth audit-log, and idempotent admin session revoke paths instead of falling through to 404.
- Intentionally gated: support actions and force logout buttons remained unsubmitted during verification; staging secrets are live, and no write was needed to prove the route fix.
