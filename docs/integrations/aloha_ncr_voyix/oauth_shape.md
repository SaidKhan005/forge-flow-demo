# Aloha (NCR Voyix) — OAuth Shape

**Vendor ID**: `aloha_ncr_voyix`
**Source documentation**: <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer>
**Retrieval date**: 2026-05-04

---

## Flow type

`client_credentials`

Cite vendor doc: <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer>
(Authentication landing — full grant-flow detail verified live in
`8.AL.live.sandbox`).

NCR Voyix Developer Program issues a `client_id` + `client_secret`
per (operator, location) at intake. The adapter mints a tenant-scoped
access token via the documented `client_credentials` grant against
`POST /oauth2/token`. F&F brokers all OAuth requests through the
proxy so production secrets never reach Flutter.

---

## Scopes requested

Exact scope strings (verified in `8.AL.live.sandbox`; portal landing
documents the scope namespace as `aloha:*`):

| Scope | Unlocks | Required for |
|---|---|---|
| `aloha:checks.read` | Read Aloha checks (orders + line items + guest count + payments) | Backfill + polling + webhook id-only lookup |
| `aloha:sites.read` | Read site/location metadata for binding cross-check | Connect — bind `siteId` to `connector_connection.metadata.site_id` |
| `events:subscriptions.write` | Auto-register webhook subscriptions on the events bus | First-connect webhook setup |
| `events:subscriptions.delete` | Unregister webhook subscription on operator disconnect | Disconnect tear-down |

Minimum-privilege subset chosen. Extra scopes the vendor offers but
the adapter doesn't request:

- `aloha:guests.read` — not requested per privacy policy (forbidden
  field list in `field_mapping.md`).
- `aloha:payments.read` — not requested; PCI scope avoided.
- `aloha:loyalty.*` — not requested; out of V1 scope.

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | 1h (documented; verified live in `8.AL.live.sandbox`) | Refresh proactively at `expires_at - 1h` via the framework's `oauth_refresh_cron` |
| Refresh token | n/a — `client_credentials` flow does not issue a refresh token | New access token minted per refresh via the static `client_id` + `client_secret` |

The framework's `oauth_refresh_cron` recognizes the
`client_credentials` shape and re-mints access tokens by replaying
the credentials envelope (no refresh-token round trip).

---

## Refresh semantics

- **Proactive refresh**: cron at 5min past every hour scans
  `vendor_credentials` for tokens with `token_expires_at < now() + 24h`
  and re-mints. See `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after re-minting.
- **3 consecutive failures**: `connector_connection.status` flips to
  `error`; audit row written. Email notification deferred to
  `9.8.email` follow-up per V1 lean cut 2.
- **Rotating vs sliding**: n/a — `client_credentials` mints a fresh
  access token each time; no refresh-token rotation.
- **Revocation**: NCR Voyix revokes access centrally on
  `client_secret` rotation. Adapter does not call a revoke endpoint
  on disconnect — the framework wipes the F&F-side credential, which
  is sufficient because subsequent token-mint attempts will fail
  upstream.

---

## Per-location vs operator-wide grant

`perLocation`

Match `VendorCapabilityProfile.grantScope`. NCR Voyix issues one
Aloha `siteId` per location; multi-location operators run one OAuth
flow per location. The vendor's `siteId` claim in the access-token
audience identifies one Aloha site only — the adapter binds it to a
single F&F `location_id` via `connector_connection.metadata.site_id`.

---

## Module disambiguation

N/A — Aloha (NCR Voyix) is a single module. ADP / QuickBooks are the
only vendors with module disambiguation in V1.

---

## Edge cases

- **Access-token expiry mid-request**: adapter retries once after the
  framework re-mints via `oauth_refresh_cron`. On the second 401, the
  connection flips to `error` with operator-facing copy "Please
  reconnect Aloha (NCR Voyix) and sign in again."
- **`client_secret` revoked at vendor**: token-mint returns 401;
  adapter flips to `error` with copy "Your Aloha (NCR Voyix)
  credentials are no longer valid. Please reconnect or check with
  NCR Voyix support."
- **Account deletion at vendor** (vendor returns 404 on
  `/aloha/v1/sites/{siteId}` lookup): connection flips to `error`
  with copy "Your Aloha (NCR Voyix) site no longer exists. Please
  connect a different site or check with NCR Voyix support."
- **Scope downgrade by vendor**: vendor returns access token without
  `aloha:checks.read` → adapter rejects, surfaces error "NCR Voyix
  denied required Aloha permissions; please contact your NCR Voyix
  support rep to enable read access."
- **Unknown errors**: log + retry once; on second failure, flip to
  `error`.
