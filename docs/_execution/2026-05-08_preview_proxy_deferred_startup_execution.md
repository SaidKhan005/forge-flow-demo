# Preview Proxy Deferred Startup Execution

Date: 2026-05-08
Branch: `codex/preview-proxy-deferred-db-startup-20260508`
Base source commit: `ca306ae6abb4a0c84687548ec8db3d421c262207`
Final fix commit: this document's containing commit

## Diagnosis

The preview proxy deploy was not blocked by CORS alone. The failed revision
opened database-backed startup checks and background consumers before it could
bind the HTTP listener, while staging Postgres was already out of normal
connection slots:

- `53300: remaining connection slots are reserved for roles with the SUPERUSER attribute`
- startup never reached a healthy TCP probe on the CORS-correct revision
- the live old revision intermittently returned dependency-timeout 503s

`GET /` returning `{"error":"not found","method":"GET","path":"/"}` is expected
for the API proxy root. The liveness endpoint is `/readyz`.

## Fix

- Added `PROXY_DEFER_STARTUP_DATABASE=true` as an explicit non-production
  startup mode.
- Production (`PROXY_ENVIRONMENT=prod`) refuses the mode with exit 78.
- Deferred mode skips startup-only Postgres connectivity, schema-contract,
  migration-registry, and CORS feature-flag DB reads.
- Deferred mode skips realtime outbox, audit anchor, rollup, email outbox,
  mobile push outbox, and tripwire background consumers.
- Route-level Postgres gateways remain wired for real HTTP requests.
- Added deploy-script support:
  - `scripts/deploy_staging_proxy.ps1 -DeferStartupDatabase -MaxInstances 1`
  - `scripts/deploy_preview_stack.ps1 -DeferProxyStartupDatabase -ProxyMaxInstances 1`
- Documented the preview DB-safe mode and cleanup flow in
  `runbooks/preview_environment_runbook.md`.

## Deployed Preview Evidence

Proxy URL:
`https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app`

Serving revision:
`forge-flow-preview-backend-surface-additions-proxy-00008-8vl`

Image digest:
`sha256:e15316648494082f860119e77ea9110e0c2ab3f736e057ed871afbe0e85c7141`

Traffic:
`00008-8vl = 100%`

Database mode:
runtime-isolated preview using `forge-flow-staging-` secrets, `maxScale=1`,
`PROXY_DEFER_STARTUP_DATABASE=true`.

Runtime checks:

- `GET /readyz` -> 200 `{"status":"ok"}`
- `OPTIONS /v1/admin/auth/users` from preview admin origin -> 204
- `OPTIONS /v1/auth/account` from preview operator origin -> 204
- `GET /v1/auth/account` without auth -> 401, not dependency 503
- `GET /` -> 404 API root, expected

Startup log evidence on `00008-8vl`:

- `startup.database_checks_deferred`
- `startup.realtime_bridge_deferred`
- `startup.background_workers_deferred`
- Cloud Run default TCP startup probe succeeded on port 8080

## Verification

Local gates:

- `flutter analyze tool\advisor_proxy\main.dart tool\advisor_proxy\proxy_bootstrap.dart test\proxy\main_bootstrap_test.dart test\deploy_staging_proxy_contract_test.dart`
- `flutter test test\proxy\main_bootstrap_test.dart test\advisor_proxy_test.dart test\deploy_staging_proxy_contract_test.dart`
- `flutter test test\proxy\auth_cors_routes_test.dart test\admin\health_admin_gateway_test.dart test\tool\cutover\preflight_smoke_test.dart`
- `git diff --check`

Cloud Run probes:

- `gcloud run services describe ...` confirmed latest created, ready, and
  traffic revision all point at `00008-8vl`.
- `gcloud logging read ... revision_name="...00008-8vl"` confirmed deferred
  startup events and TCP startup success.

## Cleanup / Operations

If Postgres remains saturated after traffic has moved to the deferred revision:

1. Confirm the proxy is capped:
   `gcloud run services update <service> --min-instances 0 --max-instances 1`.
2. Inspect `pg_stat_activity`.
3. Terminate only explicitly confirmed stale preview/staging proxy PIDs with
   `pg_terminate_backend(pid)`.

Do not use `/health` as a startup probe. `/health` remains the deep dependency
envelope and may be 503 while Postgres is unavailable; `/readyz` is the cheap
startup/liveness endpoint.

## Residual Risks

- In deferred mode, route requests still need Postgres and can return normal
  route-level dependency errors until DB slots recover.
- Background delivery paths are intentionally not running on the preview proxy
  while deferred mode is enabled.
- The mode is for preview/shared-staging recovery only and is blocked in prod.
