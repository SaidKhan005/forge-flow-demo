# Square — OAuth Shape

**Vendor ID**: `square`
**Source documentation**: https://developer.squareup.com/docs/oauth-api/overview
**Retrieval date**: 2026-05-03

---

## Flow type

`authorization_code`

Cite vendor doc: https://developer.squareup.com/docs/oauth-api/walkthrough

The proxy issues the authorize redirect (`/oauth2/authorize` on
`connect.squareup.com` / `connect.squareupsandbox.com`) carrying the
F&F-issued state token; Square redirects back to F&F's callback with
`?code=...&state=...`; the proxy exchanges the code for tokens via
`POST /oauth2/token`.

---

## Scopes requested

Exact scope strings (mirrors `kSquareOauthScopes` constant in the
adapter source):

| Scope | Unlocks | Required for |
|---|---|---|
| `ORDERS_READ` | Read orders + line items + tenders + total_money | Backfill, polling, webhook hydration |
| `MERCHANT_PROFILE_READ` | Enumerate merchant locations + currency | Connect-flow location mapping; test-connection sample |

Minimum-privilege subset chosen. Extra scopes Square offers but the
adapter does NOT request:

- `ORDERS_WRITE` — F&F is read-only against POS data.
- `CUSTOMERS_READ` / `CUSTOMERS_WRITE` — privacy; F&F does not
  process customer PII from Square.
- `PAYMENTS_READ` / `PAYMENTS_WRITE` — PCI scope; F&F is not a
  payment processor.
- `EMPLOYEES_READ` — labor data is owned by the labor adapter (e.g.
  `7shifts`, `quickbooks_time`); duplicating Square's employee data
  would create reconciliation conflicts.
- `INVENTORY_READ` — outside V1 scope.

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | 30 days (production) / 24h (sandbox) | Refresh proactively at `expires_at - 24h` |
| Refresh token | rotating | Each refresh issues a new refresh token; old token revoked on first use of new |

Doc: https://developer.squareup.com/docs/oauth-api/refresh-revoke-limit-scope

---

## Refresh semantics

- **Proactive refresh**: cron at 5min past every hour scans
  `vendor_credentials` for tokens with
  `token_expires_at < now() + 24h` and refreshes. Wired to
  `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: connection status flips to `error`;
  audit row written. Email notification deferred to `9.8.email`
  follow-up per V1 lean cut 2.
- **Rotating vs sliding**: rotating — Square invalidates the prior
  refresh token the moment a new one is issued. Adapter persists the
  new refresh token before discarding the old.
- **Revocation**: vendor exposes `POST /oauth2/revoke`; adapter calls
  it on disconnect. Revocation is best-effort — Square may 404 a
  grant the operator already revoked from their dashboard, in which
  case the adapter records `webhookUnregistered = true` anyway and
  continues with credential wipe.

---

## Per-location vs operator-wide grant

`operatorWide`

Match `VendorCapabilityProfile.grantScope`. Square scopes a single
OAuth grant to the merchant; the access token can list and read every
location the merchant owns via `/v2/locations`. F&F maps each chosen
Square location id to one F&F `location_id` in the connect flow.
Multi-location operators do not need to repeat the OAuth round trip
per location — the connect flow shows a list of Square locations and
operators check the boxes.

Doc: https://developer.squareup.com/docs/oauth-api/walkthrough#step-2-request-and-obtain-an-access-token

---

## Module disambiguation

N/A — single module. Square does not expose multiple products that
share an OAuth grant the way ADP (Workforce Now / Workforce Manager /
RUN) and QuickBooks (Time / Accounting / Payroll) do.

---

## Edge cases

- **Refresh token expiry** (no refresh for 30 days): connection flips
  to `error` with operator-facing copy "Please reconnect Square and
  sign in again."
- **Account deletion** (Square returns 404 on `/v2/locations`):
  connection flips to `error` with copy "Your Square account no
  longer exists. Please connect a different Square account or check
  with Square support."
- **Scope downgrade by operator** (operator unchecks a scope at the
  Square authorize page): adapter detects via `/v2/orders/search`
  returning 403, flips connection to `error` with copy "Square denied
  required permissions; please reconnect and approve all requested
  permissions (ORDERS_READ + MERCHANT_PROFILE_READ)."
- **Unknown errors**: log + retry once; on second failure, flip to
  `error`. No 3-strike auto-disable email wiring — that path lives
  in the framework, but email delivery is deferred to the
  `9.8.email` follow-up per V1 lean cut 2.
