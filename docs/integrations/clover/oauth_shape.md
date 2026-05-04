# Clover — OAuth Shape

**Vendor ID**: `clover`
**Source documentation**: <https://docs.clover.com/docs/using-oauth-20>
**Retrieval date**: 2026-05-03

---

## Flow type

`authorization_code`.

Cite vendor doc: <https://docs.clover.com/docs/using-oauth-20#step-1-authorization-request>

The proxy starts the flow at
`https://www.clover.com/oauth/v2/authorize?client_id=<APP_ID>&response_type=code&redirect_uri=<f&f_callback>`
and exchanges the returned `code` at
`POST /oauth/v2/token` for an access + refresh token. The signed
`merchant_id` arrives on the token response as `merchant_id` and is
persisted on `connector_connection.metadata.merchant_id` (key
`kCloverMetadataMerchantIdKey` in
`lib/integrations/pos/clover_pos_adapter.dart`).

---

## Scopes requested

Exact scope strings:

| Scope | Unlocks | Required for |
|---|---|---|
| `READ_ORDERS` | List + read orders incl. `total`, timestamps, state | Backfill + polling |
| `READ_MERCHANT` | Read merchant profile + grant scope | Connect-time merchant binding |
| `MANAGE_WEBHOOKS` | Auto-register webhook subscription on connect; delete at disconnect | First-connect webhook setup + disconnect |

Minimum-privilege subset chosen. Extra scopes Clover offers but the
adapter does NOT request:

- `READ_CUSTOMERS` — not requested per privacy policy.
- `READ_EMPLOYEES` — adapter only writes aggregate sales facts;
  per-employee attribution is the payroll vendor's job.
- `WRITE_*` — F&F never writes back to Clover at V1 (advisor-only).

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | Short-lived per Clover docs (typical 1h; verify on `8.CL.live.sandbox`) | Refresh proactively at `expires_at - 1h` |
| Refresh token | Long-lived; rotates on each use per documented intent | Each refresh issues a new refresh token; old token revoked |

Documented intent — Clover's exact TTL is published on the OAuth doc
page; `8.CL.live.sandbox` will confirm against the observed `expires_in`.

---

## Refresh semantics

- **Proactive refresh**: cron at 5min past every hour scans
  `vendor_credentials` for tokens with
  `token_expires_at < now() + 24h` and refreshes via
  `POST /oauth/v2/token` with `grant_type=refresh_token`. See
  `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: connection status flips to `error`;
  audit row written. Email notification is deferred to `9.8.email`
  follow-up per V1 lean cut 2 (operator sees the `error` chip in the
  Vendor Connections widget; email enable comes later).
- **Rotating vs sliding**: rotating per documented intent — each
  refresh issues a new refresh token; the old one is revoked.
- **Revocation**: vendor exposes a token-revocation endpoint per
  OAuth 2.0 RFC 7009 conventions; adapter calls it on `disconnect`
  best-effort, then wipes `vendor_credentials` regardless of vendor
  response.

---

## Per-location vs operator-wide grant

`perLocation`. Match `VendorCapabilityProfile.grantScope`.

Each Clover `merchant_id` represents one physical location's POS
deployment; operators with multiple Clover locations must run the
OAuth flow once per location. The proxy's connect route enforces this
by binding the F&F `(operator_id, location_id)` tuple to the
returned Clover `merchant_id` 1:1.

---

## Module disambiguation

N/A — single module.

---

## Edge cases

- **Refresh token expiry** (rotating; max idle period per Clover
  docs): connection flips to `error` with operator-facing copy
  "Please reconnect Clover and sign in again."
- **Account deletion** (vendor returns 404 on token introspection):
  connection flips to `error` with copy "Your Clover merchant
  account no longer exists. Please connect a different Clover
  merchant or check with Clover support."
- **Scope downgrade by vendor**: if the access token returns fewer
  scopes than requested → adapter rejects, surfaces error
  "Clover denied required permissions; please reconnect and approve
  all requested permissions." Specifically `MANAGE_WEBHOOKS` denial
  blocks the adapter from auto-registering webhooks, falling back to
  poll-only is **not** in scope at V1; the adapter refuses connection.
- **Unknown errors**: log + retry once; on second failure, flip to
  `error`.
