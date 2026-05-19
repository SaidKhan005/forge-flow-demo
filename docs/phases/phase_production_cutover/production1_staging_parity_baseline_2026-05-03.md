# Production1 Staging-Parity Baseline

Updated: 2026-05-03
Status: Production runtime setup paused. Staging is the mirror source of truth.
Owner: F&F launch lane

This is the dated baseline for "ready, set, go" Production1 setup. It captures
what current staging already has and what Production1 must mirror before any
traffic cutover. Future staging additions after this date are deltas: add them
to this baseline and then to the Production1 checklist before running setup.

No secret values are recorded here.

## Operator Stop Rule

Per operator direction on 2026-05-03, do not begin production runtime setup yet.
Production1 may be documented and preflighted read-only, but do not enable
runtime APIs, create production secrets, create static egress, deploy Cloud Run,
set production DNS, or change Azure firewall rules until the operator explicitly
reopens the setup lane.

## Production1 Shell Status

These resources now exist:

| Surface | Current state |
| --- | --- |
| GCP project | `forge-flow-production1`, project number `914509283000`, ACTIVE |
| Billing | linked to the open Firebase billing account |
| Firebase project | present; hosting site resource exists |
| Firebase apps | none yet (`firebase apps:list --project forge-flow-production1` returns empty) |
| Firebase Admin SDK default SA | `firebase-adminsdk-fbsvc@forge-flow-production1.iam.gserviceaccount.com` |
| Cloud Run / Secret Manager / VPC Access / Compute APIs | intentionally not enabled yet |
| Production deploy service account | not created yet (`forge-flow-production1-admin@...` is planned, not present) |
| Cloud Run services | none yet |
| Secret Manager namespace | none yet |
| Static egress connector / NAT / reserved IP | none yet |
| Azure Postgres firewall | operator IP only; no production Cloud Run static IP allowlist yet |
| DNS | no production proxy DNS configured in repo or verified live |

## Current Staging Runtime Baseline

Read-only audit on 2026-05-03 found:

| Surface | Staging value |
| --- | --- |
| GCP/Firebase project | `forge-flow-staging`, project number `78630909582` |
| Region | `northamerica-northeast2` for Cloud Run |
| Deploy service account | `forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com` |
| Proxy service | `forge-flow-staging-proxy` |
| Proxy latest revision | `forge-flow-staging-proxy-00051-7x5` at 100 percent traffic |
| Proxy run.app URL | `https://forge-flow-staging-proxy-rf7nosnoka-pd.a.run.app` |
| Repo proxy base URI | `web/firebase-config.js` points clients at `https://staging-api.feflow.org` |
| Staging DNS check | `staging-api.feflow.org` resolves to `34.54.204.29` |
| Admin console service | `forge-flow-admin-console` |
| Admin console latest revision | `forge-flow-admin-console-00004-6xw` at 100 percent traffic |
| Admin console run.app URL | `https://forge-flow-admin-console-rf7nosnoka-pd.a.run.app` |

Staging Firebase apps:

| App | Platform | Namespace |
| --- | --- | --- |
| Forge Flow Android | Android | `com.forgeflow.app` |
| Barrio Android | Android | `com.forgeflow.barrio` |
| Forge Flow iOS | iOS | `com.forgeflow.app` |
| Barrio iOS | iOS | `com.forgeflow.barrio` |
| Forge Flow Admin Web | Web | admin web app |

Staging proxy literal env names:

- `FIREBASE_PROJECT_ID=forge-flow-staging`
- `PROXY_ENVIRONMENT=staging`
- `GCP_PROJECT_ID=forge-flow-staging`
- `CLOUD_RUN_REGION=northamerica-northeast2`
- `CLOUD_RUN_SERVICE_NAME=forge-flow-staging-proxy`

Staging proxy Secret Manager references:

- `forge-flow-staging-anthropic-api-key`
- `forge-flow-staging-voyage-api-key`
- `forge-flow-staging-postgres-url`
- `forge-flow-staging-postgres-admin-url`
- `forge-flow-staging-firebase-web-api-key`
- `forge-flow-staging-service-principal-jwt-secret`

Additional staging audit-anchor secrets present:

- `forge-flow-staging-azure-ad-client-id`
- `forge-flow-staging-azure-ad-tenant-id`
- `forge-flow-staging-azure-blob-audit-container`
- `forge-flow-staging-azure-blob-audit-endpoint`

Staging static egress:

| Surface | Staging value |
| --- | --- |
| VPC connector | `ff-staging-proxy-egress` |
| Connector network / range | `default`, `10.8.0.0/28` |
| Connector state | `READY` |
| Cloud Run egress mode | `all-traffic` |
| NAT router | `ff-staging-nat-router` |
| NAT config | `ff-staging-proxy-nat`, `MANUAL_ONLY` |
| Reserved address | `ff-staging-proxy-egress-ip` |
| Static egress IP | `34.130.85.86` |
| Azure staging firewall rule | `AllowGcpCloudRunStaticEgress` on `forge-flow-staging-pg` |

## Known Staging Delta After Baseline

The first post-cutoff delta is a database migration, not a new runtime
resource:

- `db/migrations/202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql`
  grants `forge_admin` read-only access to `public.proxy_requests` so the
  11A.5 Debug Console request-log viewer can inspect request metadata through
  the admin path. It is applied and Browser Use verified on staging, but it is
  not yet applied to Production1. Treat it as the current next Production1
  migration batch unless later staging migrations join the batch before apply.

## Production1 Mirror Checklist

Before any production deployment, mirror staging with production-specific names:

- Create production Firebase apps matching staging: Android/iOS
  `com.forgeflow.app`, Android/iOS `com.forgeflow.barrio`, and admin web.
- Generate production public client config files/flavors and update repo wiring
  without overwriting staging config.
- Add `.firebaserc` production alias only after the production app/client config
  files exist and have been reviewed.
- Create production deploy service account
  `forge-flow-production1-admin@forge-flow-production1.iam.gserviceaccount.com`
  with the narrow roles needed by the deploy runbooks.
- Enable runtime APIs only when setup is explicitly reopened: Cloud Run, Cloud
  Build, Artifact Registry, Secret Manager, VPC Access, Compute, Scheduler, and
  Identity Platform/Auth as required by the target runbook.
- Create production Secret Manager namespace with the
  `forge-flow-production-` prefix. Do not copy staging secret values.
- Create production static egress in `northamerica-northeast2`: VPC connector,
  Cloud NAT with a manually reserved IP, and Azure firewall rule on
  `forge-flow-production1-pg-cmk`.
- Deploy production proxy with `PROXY_ENVIRONMENT=prod`,
  `FIREBASE_PROJECT_ID=forge-flow-production1`, and
  `--vpc-egress all-traffic`.
- Configure production proxy DNS and record rollback to staging DNS/env vars.
- Deploy the admin console only after the production proxy base URI is live.
- Run cutover preflight and Tier-M gates before corpus/operator/live traffic.

## Delta Discipline

Any staging addition after this baseline is not implicitly in production. For
each new staging runtime feature, update:

- this baseline,
- `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`,
- the relevant runbook under `runbooks/`,
- `PROJECT_TRACKER.md` if it changes cutover ordering or gates.
