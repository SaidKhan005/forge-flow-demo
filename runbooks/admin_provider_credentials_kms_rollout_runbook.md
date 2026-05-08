# Admin Provider Credentials + KMS Rollout Runbook

Purpose: make 11A.4 credential rotation and 11A.7 KMS feature flags
operational without exposing secrets in the Flutter admin client.

This runbook is operator-driven. Do not paste plaintext keys, database
URLs, service-account secrets, or flag confirmation text into issues,
PRs, chat logs, or screenshots.

## When To Run

- Staging/production provider rows show `No active credential`.
- A provider key must be rotated after vendor-side replacement.
- A KMS lane is ready to move from stub provider to real Secret Manager.
- A live smoke needs Anthropic, Voyage, Gemini, or Azure DB credentials
  present before advisor/integration testing.

## Preconditions

- Signed in to the admin console as `super_admin`.
- Fresh vendor credential is available from the vendor console or
  approved secrets store.
- Target environment's proxy has Secret Manager/KMS access.
- Latest migrations through the 11A.4/4b/4c/7 grant files are applied.
- For any `kms_real_provider_<kind>_enabled` flag change, get explicit
  action-time approval naming the exact flag and environment.

## Rotate A Provider Credential

1. Open Admin Console -> Integrations.
2. Choose the provider row and open Rotate.
3. Paste the new value into the dialog locally.
4. Submit once. The admin gateway sends an idempotency key; retry only
   through the same dialog state if the browser reports a network timeout.
5. Confirm the row shows an active masked value and recent rotation time.
6. Run the matching non-destructive smoke:
   - Anthropic/Voyage: advisor smoke or provider-health check.
   - Gemini: secondary-provider startup/status check.
   - Azure DB: `/readyz` and `/health`.

## Enable A KMS Real-Provider Flag

1. Verify the matching credential row is active.
2. Verify the target proxy revision reads Secret Manager successfully.
3. Open Admin Console -> Feature Flags.
4. Open the destructive confirmation for the exact
   `kms_real_provider_<kind>_enabled` flag.
5. Type the exact flag name only after action-time approval.
6. Submit once.
7. Refresh Health and Integrations. The affected provider path must be
   green or explicitly degraded with a known vendor-side reason.

## Provision A Vendor Webhook Signing Secret

The OAuth bearer (`access_token_ciphertext`) authorizes our outbound
polling. The webhook signing secret
(`webhook_signing_secret_ciphertext`, added by
`db/migrations/202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql`)
is a **separate** provisioning artifact the vendor mints on their
side. Until it is staged, the inbound webhook handler fails closed
with `403 no signing secret on file`.

Run this flow for each `(operator, location, vendor)` triple where
the vendor's `webhookSupport != pollOnly`:

1. Connect (OAuth or key-paste) so an active `vendor_credentials` row
   exists. The webhook signing secret rotation route updates the
   existing row rather than creating one.
2. Open the vendor's portal and copy the freshly-minted webhook
   signing secret. Each vendor's spec doc lives under
   `docs/integrations/<vendor>/webhook_signature.md`. Affected vendors:
   - POS: `toast`, `square`, `clover`, `revel`, `lightspeed_lsk`,
     `aloha_ncr_voyix` (each is HMAC-SHA256; secret minted in the
     vendor's developer / partner portal — keys differ from the
     OAuth client secret).
   - Labor: `adp`, `seven_shifts` (each is HMAC-SHA256 with a
     per-app or per-account secret).
   - Reservation: `libro`, `opentable`, `sevenrooms`, `tock`
     (HMAC-SHA256; for SevenRooms and Tock the operator pastes the F&F
     webhook URL into the vendor admin and the vendor mints the
     matching signing key — `webhookSupport = manualPaste`).
3. Open Admin Console -> Integrations -> the matching vendor row, then
   Rotate Webhook Signing Secret. Paste once and submit.
4. Confirm the row shows a recent rotation timestamp on the webhook
   secret column. The audit log records
   `integration.webhook_secret_rotated`.
5. Trigger a vendor-side test webhook (vendor portal "Send test"
   button if available) and watch `connector_sync_log` for a
   `webhook_received` row with `outcome = success`. A `403 no signing
   secret on file` outcome means the rotation did not land — retry.

Until the operator-facing "Rotate Webhook Signing Secret" UI ships
(slice `8.ops-debt.webhook-signing-secret-ui`), service the request
from the gateway's `rotateWebhookSigningSecret` method via an admin
shell script run by the on-call operator-self-service engineer.
The plaintext must never appear in chat logs, PRs, or screenshots.

## Rollback

- Disable the same `kms_real_provider_<kind>_enabled` flag to fall back
  to the stub lane.
- If the credential itself is bad, rotate to the previous approved key
  version through Integrations.
- If the proxy revision pinned stale Secret Manager versions, redeploy
  with the proxy redeploy/reset runbook.

## Evidence To Record

- Environment, provider kind, actor, timestamp.
- Masked credential suffix only, never plaintext.
- Feature flag name and final enabled/disabled state.
- Smoke result and any health envelope red/yellow signals.

## Audit-Anchor Azure Blob Wiring (`AUDIT_ANCHOR_REQUIRE_AZURE`)

The audit-anchor sweep writes a daily SHA-256 anchor of every operator
chain to the F&F-immutable Azure Blob container. Without live Azure
wiring, the proxy falls back to the `ScaffoldRejectingAuditAnchorBlobClient`
and the daily cron tick is a no-op.

To prevent a production deploy from silently shipping the scaffold
fallback, set `AUDIT_ANCHOR_REQUIRE_AZURE=true` on the proxy Cloud Run
revision alongside `AZURE_AD_TENANT_ID` and `AZURE_AD_CLIENT_ID`.

- Flag off (dev/staging without Azure wiring): the proxy boots and the
  audit-anchor LISTEN consumer logs every cron tick; the sweep returns
  the scaffold-rejecter error which is captured in the per-tick error
  envelope.
- Flag on, both creds present: the proxy boots normally and the
  audit-anchor sweep writes real Azure Blob evidence on every tick.
- Flag on, either cred missing: the proxy exits with code 78
  (`EX_CONFIG`) at startup; the structured `startup.failed` log line
  names the missing env var.

Env names this gate consults (names only — never echo values):

- `AUDIT_ANCHOR_REQUIRE_AZURE` — boolean; accepts `true`, `1`, `yes`.
- `AZURE_AD_TENANT_ID` — Azure AD tenant id for federated identity.
- `AZURE_AD_CLIENT_ID` — Azure AD app-registration client id.

## MFA Freshness Window (CODE_OPS_DEBT Theme A item 1)

The four MFA-pinned admin actions —
`admin.roles.edit_seeded`,
`admin.users.reset_mfa_factors`,
`admin.users.issue_paired_erasure`,
`admin.audit.export` — gate on a fresh MFA stamp resolved by
`JwtFreshMfaResolver` (`lib/auth/fresh_mfa_resolver.dart`). The
resolver reads JWT `auth_time` (Identity Platform stamps it at
sign-in and at MFA completion) and compares to a configurable
window.

- Default: **3600 seconds (1 hour)**. Operator-locked 2026-05-07.
- Override env var: `MFA_FRESHNESS_WINDOW_SECONDS` (positive integer
  seconds). Set on the Cloud Run proxy revision when a longer or
  shorter window is needed for a specific environment.
- A non-numeric or non-positive value falls back to the default and
  is logged at startup.
- Stale → operator decision is **full re-authentication** (sign-out
  → login → MFA → return), not a step-up modal. The proxy includes
  a `redirect_uri` hint in the 403 / `mfa_freshness_required`
  payload that the admin shell consumes to drive the navigation.

Operational note: changing the window from the default writes no
data — restart the proxy and the new value applies on the next
request. The admin UI affordances re-resolve on every paint, so the
new window takes effect for both new and existing sessions
immediately.

## Cloud Pub/Sub Realtime Cross-Pod Replay (`PUBSUB_REALTIME_*`)

The N5 cross-pod replay lane fronts the `RealtimeReplayResolver` with
a per-pod Cloud Pub/Sub subscription so a reconnecting client can
replay the last 5 minutes of events even when its original pod has
restarted. Default off; enabling it provisions one short-lived
subscription per pod against a single shared topic.

Env names this gate consults (names only — never echo values):

- `PUBSUB_REALTIME_ENABLED` — boolean; accepts `true`, `1`, `yes`.
  Defaults to `false`. With the flag off, the proxy uses the
  in-process ring buffer alone (single-instance demo mode) and makes
  zero Pub/Sub API calls. **Zero new GCP cost when disabled.**
- `PUBSUB_REALTIME_TOPIC` — Pub/Sub topic short name (no project
  prefix). The bridge publishes every locked namespace into this one
  topic; subscriptions filter by the `topic` message attribute.
- `PUBSUB_REALTIME_PROJECT` — GCP project id that owns the topic.
- `PUBSUB_REALTIME_RETENTION_SECONDS` — message retention applied
  when the per-pod subscription is created. Default `300` (5 minutes,
  matches the in-process replay window). Operators raising this beyond
  300 should expect proportional storage cost from Pub/Sub.

Topic provisioning (one-time per project):

1. Create a single Pub/Sub topic — name it `forge-realtime` (or
   match your existing convention) in the same GCP project that hosts
   the proxy Cloud Run service.
2. The proxy creates a per-pod **subscription** named
   `forge-realtime-<revision>-<hostname>-<random4>` on startup. The
   subscription has `expiration_policy.ttl=1h` so an evicted pod's
   subscription auto-cleans even if SIGTERM did not run; the SIGTERM
   handler best-efforts deletes it sooner.
3. Grant the proxy Cloud Run service account these IAM roles on the
   topic / project:
   - `roles/pubsub.publisher` on the topic — for the bridge worker's
     publish path.
   - `roles/pubsub.subscriber` on the topic — for the per-pod pull
     loop.
   - `roles/pubsub.editor` on the project (or a custom role with
     `pubsub.subscriptions.create` + `pubsub.subscriptions.delete`)
     — so the pod can create / delete its own subscription on
     start / stop.

Bring-up:

1. Create the topic and grant the service-account roles above.
2. Set `PUBSUB_REALTIME_ENABLED`, `PUBSUB_REALTIME_TOPIC`, and
   `PUBSUB_REALTIME_PROJECT` on the proxy Cloud Run revision. Leave
   `PUBSUB_REALTIME_RETENTION_SECONDS` unset to keep the 300s default.
3. Redeploy. Confirm `pubsub_realtime_enabled: true` appears in the
   deploy log alongside the chosen topic + retention.
4. Confirm at least one log line of
   `realtime.pubsub_subscriber.subscription_created` per pod, and that
   `realtime.pubsub_subscriber.pull_failed` does not fire after warm
   up.
5. Disable by removing `PUBSUB_REALTIME_ENABLED` (or setting to `false`)
   and redeploying. The next pod cycle stops calling Pub/Sub
   immediately; existing subscriptions reach TTL within an hour.

Cost notes (operator constraint — simplicity + cost control):

- Pub/Sub charges $40 / TiB throughput; expected message volume
  (~1000 msg/day per pod, sub-1KB payloads) lands well below $1/month
  per pod.
- Storage cost only applies past the free tier (10 GB/month). The 5
  minute retention window keeps the storage footprint negligible.
- With the flag off, **no Pub/Sub API calls fire and the per-pod
  subscription is never created** — zero new GCP cost.
