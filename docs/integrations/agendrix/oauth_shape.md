# Agendrix — OAuth Shape

**Vendor ID**: `agendrix`
**Source documentation**: <https://developers.agendrix.com/en/documentation>
**Retrieval date**: 2026-05-04

---

## Flow type

`authorization_code` — Agendrix exposes a public OAuth 2.0
authorization-code flow with no partnership review. F&F registers an
app at the developer portal and publishes a `redirect_uri`. The
operator clicks "Connect Agendrix" in the F&F admin widget, the proxy
redirects to Agendrix's consent screen, and Agendrix posts the
authorization code back to the published callback. The proxy
exchanges the code for an access + refresh token pair via the
documented `POST /v2/oauth/token` endpoint.

Cite vendor doc:
<https://developers.agendrix.com/en/documentation>
(OAuth section of the public dev portal — accessible after sign-in to
the Playground)

---

## Scopes requested

The adapter requests the **minimum-privilege subset** required for V1
labor ingestion. Agendrix's documented scope vocabulary covers the 75+
endpoint surface area; the adapter only asks for what it consumes.

| Scope (Agendrix permission) | Unlocks | Required for |
|---|---|---|
| `time_entries.read` | Read paged time entries (punches) for the bound company | Backfill + polling |
| `time_entries.read.single` | Optional reconciliation lookup by entry id | Optional manual reconcile from admin debug surface |
| `positions.read` | Enumerate the org's positions for FOH/BOH classification | Connect-flow role mapping |
| `users.read` | Enumerate the org's employees for `user_id` binding | Within-vendor employee namespace |
| `companies.read` | Read company id + bound location list to bind one F&F operator + locations | Connect-flow location selection |

Extra Agendrix permissions the adapter does **not** request:

- `time_entries.write` — out of scope for V1 (we read, not write).
- `schedules.write` — out of scope for V1.
- `payroll_exports.read` — outbound payroll surfaces live in
  Phase 8.5 (not 8.S).
- `users.write` / `positions.write` — out of scope for V1.
- `notifications.*` — out of scope for V1.

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | ~1h (vendor-documented short-lived bearer) | Refresh proactively at `expires_at - 1h` |
| Refresh token | sliding (per Agendrix dev-portal documentation) | The adapter exchanges the refresh token via `POST /v2/oauth/token` with `grant_type = refresh_token`; sliding rotation means a fresh refresh token is returned on each refresh and the prior is invalidated |

---

## Refresh semantics

- **Proactive refresh**: `pg_cron` job at 5 minutes past every hour
  scans `vendor_credentials` for tokens with
  `token_expires_at < now() + interval '24 hours'` and re-runs
  `POST /v2/oauth/token` with `grant_type = refresh_token`. See
  `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: `connector_connection.status` flips to
  `error`; audit row written. Email notification deferred to
  `9.8.email` follow-up per V1 lean cut 2 — no `email_outbox` row at
  V1 ship.
- **Rotating vs sliding**: sliding. The adapter persists the new
  refresh token on each refresh hop; the prior is dropped server-side
  by Agendrix.
- **Revocation**: Agendrix exposes a documented
  `DELETE /v2/oauth/tokens/{id}` revoke endpoint. The adapter calls it
  on disconnect; failure is logged but does not block the disconnect
  (the adapter still wipes the local credential and preserves the
  watermark).

---

## Per-location vs operator-wide grant

`operatorWide`

Match `VendorCapabilityProfile.grantScope`. A single Agendrix OAuth
grant covers every location bound to the operator's Agendrix
organization. The connect-flow widget surfaces a single "Connect
Agendrix" button at the operator level; the post-connect mapping step
binds Agendrix `location_id` values to F&F `location_id` values via
`connector_location_binding` rows. Bound `agendrix_company_id` is
stored in `connector_connection.metadata.agendrix_company_id` (see
adapter `connect` method).

---

## Module disambiguation

N/A — single module.

---

## Edge cases

- **Refresh token expiry** (sliding rotation expired because the
  refresh hop was missed for too long): adapter logs the 401 from the
  token endpoint, flips `connector_connection.status` to `error` on
  the third consecutive failure, surfaces operator-facing copy
  "Please reconnect Agendrix and sign back in." No email at V1.
- **Account / company deletion** (vendor returns 404 on
  `time_entries` for the bound company): connection flips to `error`
  with copy "Your Agendrix company no longer responds. Please confirm
  the company is still active in your Agendrix portal."
- **Scope downgrade by vendor**: Agendrix returns access tokens with
  the permissions the operator approved at consent. If the operator
  later revokes a permission via the Agendrix portal, `time_entries`
  returns 403 → adapter flips to `error` on the third consecutive
  failure.
- **Unknown errors**: log + retry once; on second failure within the
  same poll tick, surface the error to `connector_sync_log` and
  count as one of the 3-strike consecutive failures.
