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
