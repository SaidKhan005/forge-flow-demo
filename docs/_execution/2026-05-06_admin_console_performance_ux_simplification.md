# Admin Console Performance and UX Simplification Verification

Date: 2026-05-06 Newfoundland time  
Worktree: `.codex_worktrees/admin-console-performance-ux-polish`  
Branch: `codex/admin-console-performance-ux-polish`

## Source and Preview

- Base at final rebased deploy: `origin/master` `7bf55335`
- Deployed source commit: `8aa7af55`
- Latest observed `origin/master` after deploy moved again to `c131c3fe`; no additional deploy was taken from that moving target.
- Admin URL: https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app
- Proxy URL: https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app
- Admin revision: `forge-flow-preview-backend-surface-additions-admin-00025-n6m`, 100% traffic
- Proxy revision: `forge-flow-preview-backend-surface-additions-proxy-00069-bh7`, 100% traffic
- Database mode: staging secrets using the `forge-flow-staging-` prefix.
- Share URL: https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app?cache_bust=preview-backend-surface-additions-20260506235441
- Browser Use cache-bust URL: https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app/?cache_bust=admin-final-8aa7af55-20260506T2359

## Research Inputs

- Flutter performance best practices: https://docs.flutter.dev/perf/best-practices
- NN/g progressive disclosure: https://www.nngroup.com/articles/progressive-disclosure/
- NN/g visual hierarchy: https://www.nngroup.com/articles/visual-hierarchy-ux-definition/
- NN/g F-pattern/scannability: https://www.nngroup.com/articles/f-shaped-pattern-reading-web-content/
- Material data tables: https://m2.material.io/components/data-tables

The UX direction followed those sources by keeping the primary tab model, reducing eager loading, grouping dense content into summary strips and smaller sections, surfacing labels in human language, and leaving advanced/detail-heavy work behind explicit tabs or manual checks.

## Framework Results

### UX Adjustment Framework

- Navigation now groups operational content as Operators, Data accuracy, Polling & pricing, Team, Access, Audit & support, AI, System monitoring, and Service setup.
- Members is labeled Team, roles/hierarchy/sessions are grouped under Access, and support logs/actions use human-readable audit labels.
- Team, Access, Data Accuracy, and Polling/Pricing gained summary strips for fast scanning.
- Access no longer eagerly loads Hierarchy and Sessions on first paint.
- Vendor lifecycle no longer falls back to the demo widget when the live admin gateway is absent; the admin surface shows a truthful gated panel instead.
- System health copy now says the read-only check usually finishes in a few seconds instead of normalizing 15-30 second waits.

### Performance Framework

- `main.dart.js` is served through precompressed nginx `gzip_static` assets.
- Data Accuracy and Polling/Pricing fetch independent panels in parallel.
- Access uses lazy tab loading and coalesces hierarchy/location reads.
- Deep health producer fan-out is bounded by producer, statement, and route budgets. Slow producers now return unknown timeout warnings instead of blocking `/health`.
- Final enforced perf JSON: `build/perf_gate/admin_console_perf_ux_final_rebased_20260506T2358.json`
  - `admin_index_c1` p95 290.8 ms
  - `admin_index_c4` p95 182.7 ms
  - `admin_mainjs_gzip_c4` p95 657.7 ms, 1,151,736 bytes
  - `proxy_readyz_c1` p95 257.5 ms
  - `proxy_readyz_c4` p95 176.3 ms
- Manual `/health` timing after optimization: about 4.1 seconds. Route sweep recorded `/health` 200 in 3,837 ms. Earlier live behavior was 27-65 seconds.

### Mobile Web Console E2E Framework

- Browser Use fresh load reached the real Admin sign-in screen in 2,166 ms with title `Forge & Flow - Operations Console` and zero warning/error console logs.
- Browser Use sign-in from the login screen completed in 2,296 ms, landed on `Forge & Flow Admin Console`, and produced zero warning/error console logs.
- Visual navigation pass clicked Operators, Data accuracy, Polling & pricing, Team, Access, Audit & support, Plans and limits, Knowledge base, System health, Support logs, System metrics, Connected services, and Launch controls. No warning/error console logs were emitted.
- Screenshots were captured for login, signed-in Operators, and final Launch controls states.

## Route Evidence

Route sweep JSON: `build/admin_console_evidence/route_sweep_20260506T2359.json`

| Surface | Result |
| --- | --- |
| Operators | 200, 1,929 ms |
| Pricing operators | 200, 1,186 ms |
| Pricing usage caps | 404, intentionally not routed as a live UI |
| Connected services | 200, 803 ms |
| Integration status | 200, 751 ms |
| Feature flags | 200, 356 ms |
| Data accuracy rows | 200, 387 ms |
| Data accuracy audit | 200, 489 ms |
| Tier definitions | 200, 295 ms |
| Tier assignments | 200, 373 ms |
| Tier margin | 200, 382 ms |
| Tier requests | 200, 353 ms |
| Corpus versions | 200, 525 ms |
| Graph candidates | 200, 559 ms |
| Debug opt-ins | 200, 294 ms |
| System health | 200, 3,837 ms |
| Observability | 200, 1,019 ms |
| Team users | 200, 1,415 ms |
| Team invites | 200, 1,521 ms |
| Access roles | 200, 3,663 ms |
| Access hierarchy | 200, 2,553 ms |
| Access sessions | 200, 1,148 ms |
| Audit log | 200, 1,622 ms |
| Location vendor lifecycle | 404, intentionally gated in admin |

Safe mutation/gate probes were intentionally non-destructive:

- Feature flag unknown toggle: 503 safe rejection, no successful write.
- Data accuracy unknown override: 404 safe rejection.
- Polling assignment unknown gate: 400 safe rejection.
- Auth role create validation: 400 safe rejection.
- Vendor lifecycle notify idempotency gate: 404 safe rejection.

CORS preflights for admin auth users, feature-flag toggle, data accuracy settings, polling assignment, and health all returned 204.

## Bugs Found and Fixed

- Admin static assets were gzip-compressed on demand; fixed by precompressing release web assets and enabling `gzip_static`.
- Access loaded Roles, Hierarchy, and Sessions together; fixed by lazy loading the inactive tabs.
- Hierarchy and location reads duplicated `/v1/admin/auth/org-units`; fixed with an in-flight coalesced gateway read.
- Data Accuracy and Polling/Pricing serialized independent fetches; fixed with parallel loading and generation guards.
- Vendor lifecycle admin showed demo UX without a routed gateway; fixed with a gated live-only panel.
- `/health` producer fan-out could block for tens of seconds; fixed with tighter statement/producer budgets and a route-level producer budget that returns timeout warnings.

## Intentionally Gated or Unsurfaced

- `/v1/admin/pricing/usage-caps` remains backend-only/incomplete for this preview and returns 404.
- Per-location vendor lifecycle route remains 404 in this preview; the admin UI now avoids faking that flow.
- Mobile push status/test routes remain covered by proxy route tests only unless a safely routed admin UI is present.
- Shared staging secrets are in use, so live smoke avoided successful data-changing writes. The only browser credential transmission was the dedicated staging smoke sign-in.

## Tests and Builds

- `flutter analyze`
- `flutter test test/admin`
- `flutter test test/deploy_staging_proxy_contract_test.dart test/proxy/admin_cors_routes_test.dart test/proxy/admin_cors_helper_test.dart test/proxy/admin_cors_bootstrap_test.dart test/proxy/admin_schema_contract_test.dart test/proxy/data_accuracy_admin_routes_test.dart test/services/proxy_feature_flags_routes_test.dart test/proxy/feature_flags_idempotency_test.dart test/proxy/feature_flags_concurrency_test.dart test/proxy/mobile_push_routes_test.dart test/proxy_integration_admin_routes_test.dart test/proxy/integration_admin_proxy_gateway_kms_revision_test.dart test/proxy_auth_operations_route_test.dart test/proxy_auth_operations_route_grants_test.dart test/proxy_auth_operations_gateway_test.dart test/proxy_auth_operations_gateway_grants_test.dart test/proxy/registry_proxy_health_check_store_test.dart test/proxy/advisor_proxy_health_envelope_test.dart`
- `flutter build web --release --target=lib/main_admin.dart --dart-define=ADMIN_PROXY_BASE_URI=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --pwa-strategy=none`
- `dart run tool/perf_gate/staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-additions-admin-00025-n6m --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00069-bh7 --label=admin-console-performance-ux-final-rebased --write-json=build/perf_gate/admin_console_perf_ux_final_rebased_20260506T2358.json`

## Residual Risks

- `origin/master` continued moving during long Cloud Run deploys. The deployed source commit is recorded above; branch should be rebased again only if merge policy requires it.
- Deep health returns timeout warnings for slow producer families rather than waiting for every expensive diagnostic query. This keeps the console usable but means some low-priority health details may show unknown under load.
- The safe mutation probes validated rejection/gating paths on shared staging, not successful write paths. Successful write behavior is covered by the local widget/proxy route tests.
