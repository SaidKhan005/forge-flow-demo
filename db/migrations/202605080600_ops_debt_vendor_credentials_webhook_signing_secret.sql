-- Ops debt fix — Add `vendor_credentials.webhook_signing_secret_ciphertext`.
--
-- Authority:
--   * Active prompt: `claude/ops-debt.webhook-signing-secret`.
--   * `CODE_OPS_DEBT.md` Theme G row 2: webhook signature verifiers were
--     receiving an OAuth bearer token instead of an HMAC signing secret,
--     so no real vendor's signed webhook ever validated.
--   * CLAUDE.md Hard Promise #7 — F&F holds all provider keys
--     server-side. The webhook signing secret is a separate provisioning
--     artifact distinct from the OAuth bearer; storing them in the same
--     column is a category error.
--   * `lib/services/integration/repository_inbound_webhook_gateway.dart`
--     `lookupSigningSecret` previously read `access_token_ciphertext`;
--     the matching read-path patch in this slice points at the new
--     column.
--
-- Why a new column instead of overloading `access_token_ciphertext`:
--   Every vendor with `webhookSupport != pollOnly` treats the webhook
--   signing secret as a separate provisioning artifact. The OAuth
--   bearer is required for outbound polling (we keep it as-is); the
--   webhook signing secret is required for inbound HMAC verification.
--   Conflating them broke verification for every real vendor — a
--   bearer token is not an HMAC key.
--
-- Affected vendors (each must have this column populated via the
-- credential rotation runbook before signed webhooks validate):
--
--   POS:
--     * `toast`             — HMAC-SHA256 over raw body; per-vendor
--                             webhook secret minted in Toast partner
--                             portal under `Webhooks` tab.
--     * `square`            — HMAC-SHA256; webhook signature key
--                             (separate from OAuth bearer) minted in
--                             Square Developer Dashboard per webhook
--                             subscription.
--     * `clover`            — HMAC-SHA256; per-app static secret from
--                             Clover Developer Dashboard webhook
--                             config.
--     * `revel`             — HMAC-SHA256; per-establishment webhook
--                             secret minted in Revel admin portal.
--     * `lightspeed_lsk`    — HMAC-SHA256; per-account webhook secret
--                             from Lightspeed K-Series partner portal.
--     * `aloha_ncr_voyix`   — HMAC-SHA256; hub-shared secret from
--                             NCR Voyix Aloha hub configuration.
--   Labor:
--     * `adp`               — HMAC-SHA256; per-app webhook secret from
--                             ADP Marketplace partner console.
--     * `seven_shifts`      — HMAC-SHA256; account-scoped webhook
--                             signing secret minted in 7shifts admin.
--   Reservation:
--     * `libro`             — HMAC-SHA256; per-app static webhook
--                             secret from Libro partner portal.
--     * `opentable`         — HMAC-SHA256; per-restaurant webhook
--                             secret from OpenTable for Restaurants
--                             admin (separate from API OAuth bearer).
--     * `sevenrooms`        — HMAC-SHA256; per-venue webhook secret
--                             pasted into SevenRooms admin (manualPaste
--                             flow — operator copies the F&F webhook URL
--                             into the SevenRooms console and the
--                             vendor mints the matching signing key).
--     * `tock`              — HMAC-SHA256; per-app static secret pasted
--                             into Tock admin alongside the F&F webhook
--                             URL (manualPaste flow).
--
-- The values themselves are operator-staged at rotation time via the
-- runbook documented in
-- `runbooks/admin_provider_credentials_kms_rollout_runbook.md`
-- ("Provision A Vendor Webhook Signing Secret"). The runbook references
-- each vendor's spec doc under `docs/integrations/<vendor>/webhook_signature.md`.
--
-- Posture:
--   * Column is **NULL-allowed** so the migration applies cleanly on
--     existing rows. No row backfill — the runbook supplies values per
--     vendor, per operator, on schedule.
--   * The repository read path returns NULL when the column is NULL,
--     and the inbound webhook handler **fails closed** (rejects the
--     webhook with 403 "no signing secret on file") rather than
--     skipping verification.
--   * `access_token_ciphertext` is **kept as-is** — it is still used
--     for OAuth bearer auth on outbound polling.
--
-- Time guardrails (CLAUDE.md / 7.55 Rule 11):
--   No new timestamp columns. Existing `updated_at` on
--   `vendor_credentials` records when the secret last rotated.
--
-- RLS posture:
--   The existing `vendor_credentials_per_tenant` policy on
--   `public.vendor_credentials` already covers the new column — RLS
--   evaluates row-level access, not column-level. No policy change.

set local statement_timeout = '60s';
set local lock_timeout = '5s';

alter table public.vendor_credentials
  add column if not exists webhook_signing_secret_ciphertext bytea;

comment on column public.vendor_credentials.webhook_signing_secret_ciphertext is
  'pgcrypto-envelope-encrypted webhook HMAC signing secret. Distinct '
  'from access_token_ciphertext (OAuth bearer for outbound polling). '
  'Required for inbound webhook signature verification on vendors with '
  'webhookSupport != pollOnly. Operator-staged via the credential '
  'rotation runbook; NULL means the verifier rejects the webhook (fail '
  'closed). Read path: '
  'lib/services/integration/repository_inbound_webhook_gateway.dart '
  'lookupSigningSecret.';
