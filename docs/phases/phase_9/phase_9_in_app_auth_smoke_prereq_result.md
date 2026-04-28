# Phase 9 In-App Auth Smoke Prerequisite Result

Status: PREREQUISITES READY.
Generated: 2026-04-27.

## Scope

Prepared the live staging proxy prerequisites for the dedicated in-app smoke user:

- `auth-smoke@forgeflow.dev`

No app login smoke was run in this step.

## Name-Only Prerequisite Check

No secret values, tokens, passwords, connection strings, or proxy URLs were
printed in the result.

| Required item | State |
| --- | --- |
| Deployed staging proxy URL | PRESENT |
| `C:\Users\saidu\.forge_flow\forge_flow.secrets.ps1` | LOADED |
| `FIREBASE_AUTH_SMOKE_PASSWORD` | PRESENT |
| Cloud Run env `FIREBASE_PROJECT_ID` | PRESENT |
| Cloud Run env `POSTGRES_URL` | PRESENT |
| Cloud Run env `POSTGRES_ADMIN_URL` | PRESENT |
| App launch define `FORGE_FLOW_USE_FIREBASE_AUTH=true` | AVAILABLE |
| App launch define `FORGE_FLOW_PROXY_BASE_URI=<deployed-proxy-url>` | AVAILABLE |

## Verification

- Cloud Run service `forge-flow-staging-proxy` is deployed in
  `forge-flow-staging` / `northamerica-northeast2`.
- Runtime startup logs report Firebase verifier mode and Postgres
  auth-session ledger mode by name only.
- Public readiness check passed on `GET /readyz` with HTTP 200.
- `GET /healthz` remains supported by the proxy for local compatibility, but
  Cloud Run may intercept that path before it reaches the container; use
  `/readyz` for public staging readiness checks.
- `scripts/run_flutter_dev.ps1 -App forgeflow -UseFirebaseAuth -PrintCommandOnly`
  emits the expected Flutter command with sensitive values masked.

## Live Mutations

- Enabled / confirmed required GCP APIs for Cloud Run source deployment.
- Created/updated the Cloud Run staging proxy service.
- Added the deployed proxy base URI to the non-repo secrets loader as
  `FORGE_FLOW_PROXY_BASE_URI`.
- Updated the Cloud Run service to allow public app traffic while the proxy
  continues to enforce Firebase bearer-token checks on protected routes.
- A temporary `us-central1` Cloud Run deployment was created as a routing
  control during troubleshooting, then deleted after the
  `northamerica-northeast2` staging service passed readiness.

## Commands Run

```powershell
scripts/deploy_staging_proxy.ps1
scripts/deploy_staging_proxy.ps1 -Region us-central1 -SkipApiEnable
scripts/deploy_staging_proxy.ps1 -Region northamerica-northeast2 -SkipApiEnable
gcloud run services update forge-flow-staging-proxy --region northamerica-northeast2 --default-url --no-invoker-iam-check
scripts/run_flutter_dev.ps1 -App forgeflow -UseFirebaseAuth -PrintCommandOnly
dart analyze tool/advisor_proxy/advisor_proxy.dart tool/advisor_proxy/main.dart test/advisor_proxy_test.dart
flutter test test/advisor_proxy_test.dart --name readyz
flutter test test/advisor_proxy_test.dart --name healthz
```

## Next Gate

Run the live in-app auth smoke for `auth-smoke@forgeflow.dev`:

- app login succeeds
- login creates an `auth_sessions` row
- cold / persistent session behavior is sane
- logout revokes the same `auth_sessions` row
- UX stays low-friction: no forced reset, broad MFA prompt, or surprise friction
