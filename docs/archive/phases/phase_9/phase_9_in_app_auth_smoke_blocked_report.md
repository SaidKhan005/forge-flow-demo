# Phase 9 In-App Auth Smoke Blocked Report

Status: BLOCKED.
Generated: 2026-04-27.

2026-04-28 note: superseded by the prerequisite and passed smoke reports.
Do not use this historical blocked report as the current deploy contract. The
Phase 9 production route bootstrap now also requires `FIREBASE_WEB_API_KEY`.

## Requested Smoke

Run the live in-app auth smoke for the dedicated staging user:

- `auth-smoke@forgeflow.dev`

## Prerequisite Check

Name-only check completed before running the live in-app smoke. No secret
values, tokens, passwords, connection strings, or proxy URLs were printed.

| Required item | State |
| --- | --- |
| `C:\Users\saidu\.forge_flow\forge_flow.secrets.ps1` | PRESENT |
| `FIREBASE_PROJECT_ID` | PRESENT |
| `POSTGRES_URL` | PRESENT |
| `POSTGRES_ADMIN_URL` | PRESENT |
| `FIREBASE_WEB_API_KEY` | NOT CHECKED IN 2026-04-27; ADDED TO NEXT-DEPLOY CONTRACT ON 2026-04-28 |
| `FIREBASE_AUTH_SMOKE_PASSWORD` | PRESENT |
| `FORGE_FLOW_PROXY_BASE_URI` | MISSING |
| `FORGE_FLOW_STAGING_PROXY_URL` | MISSING |
| `FORGE_FLOW_PROXY_URL` | MISSING |
| Cloud Run service in project `forge-flow-staging` | MISSING |
| Deployed staging proxy URL | MISSING |
| Proxy deployed with `FIREBASE_PROJECT_ID`, `POSTGRES_URL`, `POSTGRES_ADMIN_URL`, `FIREBASE_WEB_API_KEY` | NOT VERIFIABLE - no deployed service |

## Commands Run

Read-only / local checks only:

```powershell
gcloud config list --format=json
gcloud run services list --project forge-flow-staging --platform managed --format=json
. C:\Users\saidu\.forge_flow\forge_flow.secrets.ps1
```

The Cloud Run service list returned no services for the staging Firebase/GCP
project.

## Live Mutations

None.

- No app login was attempted.
- No Firebase sign-in call was made.
- No `auth_sessions` row was inserted, refreshed, or revoked.
- No Postgres mutation was made.
- No Cloud Run deployment or configuration mutation was made.
- No provider calls to Anthropic or Voyage were made.

## Required Unblock

Deploy the staging proxy or otherwise provide a deployed staging proxy URL
through the non-repo secrets file. The next smoke expects:

- `FORGE_FLOW_PROXY_BASE_URI`
- deployed proxy runtime env:
  - `FIREBASE_PROJECT_ID`
  - `POSTGRES_URL`
  - `POSTGRES_ADMIN_URL`
  - `FIREBASE_WEB_API_KEY` (added to the next-deploy contract on 2026-04-28)

Then launch the app with:

```powershell
--dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true
--dart-define=FORGE_FLOW_PROXY_BASE_URI=<deployed-proxy-url>
```

Do not paste the proxy URL, password, or any secret values into chat.
