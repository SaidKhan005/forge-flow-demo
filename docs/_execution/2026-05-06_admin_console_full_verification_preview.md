# Admin Console Full Verification Preview

Date: 2026-05-06  
Worktree: `.codex_worktrees/admin-console-full-verification`  
Branch: `codex/admin-console-full-verification`

## Source

- Initial expected `origin/master`: `855d1f0b68d7d5d5011244ce4d4cc52ea8579543`
- Latest verified `origin/master`: `c26767609632af0985e98a8587ce773a40848847`
- Final code-fix commit used for evidence: `5571a0a4` (`Tolerate live auth admin preview payloads`)
- Final branch commits over master:
  - `21abf805` - `Fix admin preview auth CORS and share URL`
  - `f0a21ab7` - `Fix admin members proxy payload parsing`
  - `5571a0a4` - `Tolerate live auth admin preview payloads`

## Preview Deployment

- Full preview stack redeploy command:
  `powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 -PreviewName backend-surface-additions -SkipApiEnable -SkipSecretManagerSync`
- Final admin-only redeploy command:
  `powershell -ExecutionPolicy Bypass -File scripts\deploy_admin_console.ps1 -Service forge-flow-preview-backend-surface-additions-admin -Project forge-flow-staging -Region northamerica-northeast2 -AdminProxyBaseUri https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app -SkipApiEnable`
- Admin URL: `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app`
- Proxy URL: `https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app`
- Final admin revision: `forge-flow-preview-backend-surface-additions-admin-00008-dfj`, traffic 100 percent
- Final admin image: `northamerica-northeast2-docker.pkg.dev/forge-flow-staging/forge-flow-cloud-run/forge-flow-preview-backend-surface-additions-admin:20260506153932`
- Final admin image digest from deploy: `sha256:ea71e1ba499be4951f979c2e26a44e7bf0e272eb63b18f3b8e3aea3e14678084`
- Final proxy revision: `forge-flow-preview-backend-surface-additions-proxy-00012-q86`, traffic 100 percent
- Final proxy image digest: `sha256:2d2e0e2b91ec3986c37c81fe12abf117d02eb2d617ae435cfb10e6775e1def7c`
- Proxy `/readyz`: 200, `{"status":"ok"}`
- Admin-auth CORS preflight: 204 for preview admin origin
- Database mode: staging secrets and shared staging data. All browser smoke was read-only because the preview uses `forge-flow-staging-*` secrets.
- Metadata caveat: the proxy Cloud Run template still carries stale label `source_commit=855d1f0b`; source commit is therefore recorded from git/deploy context above.

## Framework Results

UX Adjustment Framework:
- Navigation labels and route grouping render consistently across Operations, AI, System monitoring, and Service setup.
- Work-in-progress labels remain human-readable on Data accuracy and Polling & pricing.
- Operator picker disabled/enabled state, selection copy, and selected operator/location affordances were verified visually.
- Data accuracy, polling/pricing, health, debug, observability, integrations, and feature flags render readable status/cadence/setup/audit states without app console warnings.
- Mutation controls were not exercised on staging secrets; gated controls remain visible only where the current admin role allows them.

Performance Framework:
- Route startup requires waiting for Flutter shell render after load event; this is captured by the final `fresh-shell.png`.
- No app console warning/error logs were captured in Browser Use route summaries.
- Performance probe passed enforced budgets for admin index, gzipped main JS, and proxy readyz.
- Heavy observability is manual, not automatic on route open; the route renders a read-only prompt before fetching.

Mobile Web Console E2E Framework:
- Browser Use used a fresh cache-bust URL: `?cache_bust=admin-full-verification-20260506T1546`.
- Final evidence directory: `.codex_appdata/admin-console-full-verification/browser-final-rev00008`.
- Final app console log count: 0 on every saved route result.
- Browser Use emitted tool-side Statsig networking warnings from the automation environment; these were not app console logs.
- Flutter web DOM exposure is limited, so evidence is screenshot-first with route JSON summaries.

## Route Evidence

Final Browser Use evidence lives under `.codex_appdata/admin-console-full-verification/browser-final-rev00008`.

- Home / initial shell: `fresh-shell.png`
- Operators and locations: `operators-locations.png`
- Data Accuracy: `data-accuracy.png`
- Polling and Pricing: `polling-pricing.png`
- Plans and limits: `pricing-plans-limits.png`
- Knowledge base: `corpus-knowledge-base.png`
- Health: `health.png`
- Debug / support logs: `debug-support-logs.png`
- Observability / system metrics: `observability-system-metrics.png`
- Connected services: `integrations-connected-services.png`
- Feature flags / launch controls: `feature-flags-launch-controls.png`
- Members picker: `members-picker.png`, `members-operator-menu.png`, `members-selected.png`
- Members scoped route: `members-invites-scoped.png`
- Roles picker and scoped route: `roles-picker-selected.png`, `roles-hierarchy-sessions-scoped.png`
- Audited support actions picker and scoped route: `audit-picker-selected.png`, `audited-support-actions-scoped.png`
- Route summaries: `non-scoped-route-summary.json`, `scoped-route-summary.json`

Observed backend-gated scoped auth states:
- Members no longer crashes on live payload shape. The routed backend still returns `auth operation is unavailable; please retry`.
- Roles, hierarchy, and sessions no longer crashes on label-oriented parser assumptions in tests. The live routed backend still returns `admin roles/hierarchy/sessions proxy returned an error`.
- Audited support actions still returns `admin audited-support-actions proxy returned an error`.
- These were documented as backend/routing residuals rather than covered with fake UX.

## Bugs Fixed

- Preview proxy CORS did not allow `/v1/admin/auth/*` browser preflight. Fixed in `tool/advisor_proxy/advisor_proxy.dart` with admin-auth CORS tests.
- Preview stack script printed a broken share/test URL because `$adminUrl?cache_bust=...` was parsed incorrectly. Fixed with `${adminUrl}?cache_bust=...` and a contract test.
- Members admin gateway assumed fact-table fields that the live auth proxy does not emit (`role_key`, `primary_location_*`, timestamps). Added live payload fallbacks.
- Members admin gateway now filters invite-only `status=invited` rows from the members table, preserving the contract-locked member status enum.
- Members invites/users now tolerate missing primary location and render `Unassigned` instead of crashing.
- Roles/hierarchy/sessions gateway now tolerates label-oriented live payload fields for roles, org units, hierarchy locations, and sessions.

## Intentionally Gated Or Unsurfaced

- No separate Home route is mounted; the initial shell opens Operators.
- Mobile push status/test surfaces are not exposed in the admin route table in this preview. Proxy mobile-push route tests were run, but no UI was invented.
- No write action was submitted in Browser Use because the preview uses staging secrets. Stopped at read-only route smoke for invites, member actions, roles, hierarchy moves, session revokes, feature flag toggles, data-accuracy overrides, tier edits, corpus writes, and support actions.
- `ff_support` and read-only behavior remains covered by existing admin tests.

## Tests And Builds

Passed:
- `flutter analyze`
- `flutter test test\admin` - 355 tests
- `flutter test test\admin\services\members_admin_gateway_test.dart test\admin\services\roles_hierarchy_sessions_admin_gateway_test.dart` - 61 tests
- `flutter build web --release --target=lib\main_admin.dart --dart-define=ADMIN_PROXY_BASE_URI=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app`
- Proxy/admin route pack - 503 tests:
  `flutter test test/advisor_proxy_test.dart test/proxy_integration_admin_routes_test.dart test/proxy/data_accuracy_admin_routes_test.dart test/services/proxy_feature_flags_routes_test.dart test/proxy/feature_flags_idempotency_test.dart test/services/proxy_corpus_admin_routes_test.dart test/services/proxy_graph_candidates_routes_test.dart test/proxy/admin_audit_extensions_test.dart test/proxy/admin_schema_contract_test.dart test/proxy/admin_cors_routes_test.dart test/proxy/admin_cors_helper_test.dart test/proxy/admin_cors_bootstrap_test.dart test/proxy/advisor_proxy_health_envelope_test.dart test/proxy/registry_proxy_health_check_store_test.dart test/proxy/health_producers/audit_producers_test.dart test/proxy/health_producers/cost_producers_test.dart test/proxy/health_producers/graph_producers_test.dart test/proxy/health_producers/infra_producers_test.dart test/proxy/health_producers/outbox_producers_test.dart test/proxy/health_producers/retrieval_producers_test.dart test/proxy/health_producers/rollup_producers_test.dart test/proxy/health_producers/vector_producers_test.dart test/proxy/integration_admin_proxy_gateway_kms_revision_test.dart test/proxy/mobile_push_routes_test.dart test/proxy_auth_operations_route_test.dart test/proxy_auth_operations_route_grants_test.dart test/proxy_auth_operations_gateway_test.dart test/proxy_auth_operations_gateway_grants_test.dart`

Performance:
- Command:
  `dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-additions-admin-00008-dfj --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00012-q86 --label=admin-console-full-verification --write-json=build\perf_gate\admin_console_full_verification_preview.json`
- JSON evidence: `build\perf_gate\admin_console_full_verification_preview.json`
- Result: budgets passed
- Probe summary:
  - `admin_index_c1`: p50 64.7 ms, p95 230.5 ms, errors 0.0 percent
  - `admin_index_c4`: p50 63.4 ms, p95 178.8 ms, errors 0.0 percent
  - `admin_mainjs_gzip_c4`: p50 967.2 ms, p95 1397.7 ms, errors 0.0 percent, bytes 1172566
  - `proxy_readyz_c1`: p50 60.2 ms, p95 173.4 ms, errors 0.0 percent
  - `proxy_readyz_c4`: p50 63.2 ms, p95 174.5 ms, errors 0.0 percent

## Residual Risks

- The preview uses shared staging data and staging secrets; browser smoke intentionally avoided writes.
- Scoped auth admin surfaces still depend on routed backend operations that return errors in this preview. The UI now reports those backend states instead of failing on client-side parser exceptions.
- Cloud Run proxy `source_commit` label is stale, so release traceability should use the git/deploy evidence above until the deploy script stamps current commits.
- Browser evidence is visual because Flutter web exposes limited semantic DOM in the in-app browser.
