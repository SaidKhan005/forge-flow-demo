# V1 Operator Launch Punchlist Runbook

Updated: 2026-05-27
Owner: operator/founder action, with Codex repo support

This runbook executes the repo-side preparation for the open Operator (You)
items in `docs/_execution/2026-05-05_v1_launch_punchlist.md`. On 2026-05-06,
the operator explicitly reopened Production1 runtime setup up to the migration
boundary; the completed live evidence is in
`docs/_execution/2026-05-06_v1_operator_punchlist_execution.md`.

It does not authorize any additional live mutation by itself.

## Live Boundary

`docs/phases/phase_production_cutover/production1_staging_parity_baseline_2026-05-03.md`
was reopened by operator instruction on 2026-05-06 for runtime setup only.
That pass completed Production1 APIs, Firebase apps/configs, Secret Manager,
static egress, Azure firewall, and Cloud Run services.

The following still require fresh explicit approval or external account access:

- apply Production1 Postgres migrations,
- set production DNS or Cloud Run/Firebase custom domains,
- change the `auth.feflow.org` action-domain switch from staging to
  Production1,
- create or rotate SendGrid production credentials,
- send legal documents externally on the operator's behalf,
- call vendor/provider APIs for account setup.

## Read-only Preflight

Run from repo root:

```powershell
.\scripts\v1_operator_punchlist_preflight.ps1
```

Optional read-only checks:

```powershell
.\scripts\v1_operator_punchlist_preflight.ps1 -IncludeDns
.\scripts\v1_operator_punchlist_preflight.ps1 -IncludeCloudReadOnly
.\scripts\v1_operator_punchlist_preflight.ps1 -IncludeDns -IncludeCloudReadOnly
```

The script prints presence-only status for local tools, required files, selected
environment names, DNS, and GCP/Firebase resource visibility. It never prints
secret values and does not mutate state.

## 1. Production1 GCP/Firebase Runtime Setup

Authority:

- `docs/phases/phase_production_cutover/production1_staging_parity_baseline_2026-05-03.md`
- `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`
- `scripts/deploy_staging_proxy.ps1`
- `scripts/deploy_operator_web.ps1`

Current known state:

- GCP/Firebase shell exists as `forge-flow-production1`.
- Firebase apps now exist for Forge Flow Android/iOS, Barrio Android/iOS, and
  Forge Flow Admin Web.
- Production public Firebase config files exist for Android, iOS, and web.
- Cloud Run, Secret Manager, VPC Access, Compute, and runtime services are
  enabled for Production1.
- `.firebaserc` has `production` and `production1` aliases for
  `forge-flow-production1`.
- Production static egress uses `ff-prod1-proxy-egress`,
  `ff-production1-proxy-nat`, and reserved IP `34.130.24.134`.
- Azure Postgres firewall rule `AllowGcpProduction1CloudRunStaticEgress`
  allowlists `34.130.24.134`.
- Production Cloud Run services are live:
  `forge-flow-production1-proxy`, `forge-flow-operator-web`, and
  `forge-flow-admin-console`.
- DNS and Firebase auth custom-domain changes remain intentionally unperformed.

Read-only readiness commands:

```powershell
.\scripts\v1_operator_punchlist_preflight.ps1 -IncludeCloudReadOnly
gcloud config list account project
gcloud projects describe forge-flow-production1
firebase apps:list --project forge-flow-production1
gcloud run services list --project forge-flow-production1 --region northamerica-northeast2
```

Production1 runtime closeout evidence now expected before migration:

- `.\scripts\v1_operator_punchlist_preflight.ps1 -IncludeDns -IncludeCloudReadOnly`
  shows only DNS/SendGrid blockers,
- `GET /readyz` on `forge-flow-production1-proxy` returns HTTP 200,
- operator and admin Cloud Run roots return HTTP 200,
- compiled operator/admin web bundles contain `forge-flow-production1` and not
  `forge-flow-staging`,
- Android `forgeflowProd1` and `barrioProd1` debug builds pass,
- no DNS/auth-domain switch has been performed.

## 2. Production1 Follow-up Migrations

Authority:

- `runbooks/phase_9_production1_migration_apply_runbook.md`
- `docs/POST_HARDENING_FOLLOWUPS.md` P0

Pending inventory:

- The authoritative pending Production1 migration queue is the P0 table in
  `docs/POST_HARDENING_FOLLOWUPS.md`.
- As of 2026-05-27, that queue contains 76 files through
  `db/migrations/202605261200_phase_12_c3_typed_graph_vocabulary.sql`.
- Two rows in that queue are specifically operator-decision-sensitive:
  `db/migrations/202605061800_phase_8_first_connection_backfill_jobs.sql` and
  `db/migrations/202605070000_phase_11W_7_operator_account_fields.sql`.
- Do not treat the old two-file list as the full apply queue; it is only the
  operator-decision subset.

Pre-apply gates:

```powershell
flutter analyze --fatal-infos
dart run tool/rls_policy_lint.dart
dart run tool/migration_cutoff_lint.dart
```

Live apply remains blocked until the runbook's Live-Mutation Gate is satisfied:

- runbook reviewed in-session,
- exact target confirmed by name only: `forge-flow-production1-pg-cmk`,
  database `forgeflow`,
- fresh backup or restore point confirmed,
- staging parity confirmed for the exact queue being applied,
- operator explicitly approves the apply,
- no secrets or DSNs pasted into chat or docs.

After apply, update `runbooks/phase_9_production1_migration_apply_runbook.md`
Apply History and the punchlist with direct grant-verification evidence.

## 3. Inbound T&Cs Legal Escalation

Authority:

- `docs/phases/phase_9_8/phase_9_8_inbound_vendor_tcs_draft.md`
- `docs/phases/phase_11W/operator_onboarding_flow.md`
- `docs/phases/phase_8/vendor_connections_admin_surface.md`

Counsel handoff template:

```text
Subject: Forge & Flow V1 inbound vendor data T&Cs review - first pass due 2026-05-10, final due 2026-05-13

Hi [Counsel],

Please review the attached Forge & Flow V1 inbound vendor data authorization
draft for launch. We need binding clickwrap language that covers:

- universal authorization during operator onboarding,
- per-vendor authorization before first POS / reservation / scheduling connect,
- read-only data access only at V1,
- no sale, marketing, or cross-customer AI training use of operator data,
- subprocessors: Microsoft Azure Canada Central, Google Cloud Run, Firebase
  Authentication, and the connected vendor,
- retention/deletion rights and revocation wording,
- versioning and re-acceptance requirements.

Launch deadlines:
- first pass by 2026-05-10,
- final binding language by 2026-05-13.

Source draft:
docs/phases/phase_9_8/phase_9_8_inbound_vendor_tcs_draft.md

Please return redlines plus any required Privacy Policy / Terms of Service
cross-reference language.
```

Repo closeout evidence:

- counsel redlines received,
- final binding copy committed,
- `tos_versions` seed/version plan updated,
- launch punchlist `cutover.2` dependency unblocked.

## 4. DNS/TLS And SendGrid

Authority:

- `docs/phases/phase_9_8/phase_9_8_email_provider_slice.md`
- `docs/archive/_walkthroughs/9.8.email.md`
- `scripts/deploy_operator_web.ps1`

`app.forgeflow.app`:

- Target is the production operator web Cloud Run service.
- Do not set DNS until the production operator web service URL or load-balancer
  target exists.
- `scripts/deploy_operator_web.ps1 -PrintCommandOnly` can assemble the Cloud
  Build/Cloud Run command set without publishing.
- TLS should be validated after DNS is visible and before `cutover.2`.

`mail.forgeflow.app`:

- Sender identity: `noreply@mail.forgeflow.app`.
- SPF: `v=spf1 include:sendgrid.net ~all`.
- DMARC: `v=DMARC1; p=quarantine; rua=mailto:dmarc@forgeflow.app`.
- DKIM records come from the SendGrid sender-authentication wizard; record
  selector names exactly as issued by SendGrid.
- Production API key scope: Mail Send only. Store in production Secret Manager /
  Cloud Run env as `SENDGRID_API_KEY`; leave `SENDGRID_SANDBOX_MODE` off for
  production.

Closeout evidence:

- DNS records visible via `Resolve-DnsName`,
- HTTPS certificate active for `app.forgeflow.app`,
- SendGrid domain authentication verified,
- test email accepted from the deployed production path.

## 5. Live Trio Sandbox Credentials

Authority:

- `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`
- `docs/integrations/lightspeed_lsk/partnership_status.md`
- `docs/integrations/libro/partnership_status.md`
- `docs/integrations/quickbooks_time/partnership_status.md`
- each vendor's `live_verification_checklist.md`

First trio:

| Vendor | Slice | Credential route | Initial action |
| --- | --- | --- | --- |
| Lightspeed K-Series | `8.LSK.live.sandbox` | public OAuth | Register client in Lightspeed K-Series developer portal. |
| Libro | `8R.LB.live.sandbox` | public OAuth | Provision client id/secret in Libro developer console. |
| QuickBooks Time | `8.S.QBT.live.sandbox` | Intuit OAuth | Register Intuit developer app and free-trial QBT account. |

Never commit plaintext credentials. Land only secret locations or env names in
repo docs. Once credentials are in the approved secret path, spawn each
`*.live.sandbox` slice from `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`.

Closeout evidence:

- partnership status updated with credential-location names,
- sandbox live verification checklist rows filled with test/walkthrough refs,
- lifecycle promoted from `documented` to `sandbox_verified` only after the
  live slice passes.
