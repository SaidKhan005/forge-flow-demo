# `<vendor_display_name>` — OAuth Shape

**Vendor ID**: `<vendor_id>`
**Source documentation**: `<https://...>`
**Retrieval date**: YYYY-MM-DD

> If `authMode != oauth | oauthOrKeyPaste`, replace this file with a
> single line: "N/A — auth shape documented in `api_consumed.md`."

---

## Flow type

`authorization_code` | `client_credentials` | `hybrid`

Cite vendor doc: `<URL>`

---

## Scopes requested

Exact scope strings:

| Scope | Unlocks | Required for |
|---|---|---|
| `orders.read` | Read orders + line items | Backfill + polling |
| `webhooks.write` | Auto-register webhooks | First-connect webhook setup |
| `<more>` | ... | ... |

Minimum-privilege subset chosen. Extra scopes the vendor offers but
the adapter doesn't request:

- `customers.read` — not requested per privacy policy.
- `<more>`

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | 1h | Refresh proactively at `expires_at - 1h` |
| Refresh token | 90 days, rotating | Each refresh issues a new refresh token; old token revoked |

---

## Refresh semantics

- **Proactive refresh**: cron at 5min past every hour scans
  `vendor_credentials` for tokens with `token_expires_at < now() + 24h`
  and refreshes. See `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: connection status flips to `error`;
  audit row written. Email notification deferred to `9.8.email`
  follow-up per V1 lean cut 2.
- **Rotating vs sliding**: rotating (each refresh issues a new refresh
  token; old is revoked).
- **Revocation**: vendor exposes `/v1/oauth/revoke`; adapter calls it
  on disconnect.

---

## Per-location vs operator-wide grant

`perLocation` | `operatorWide`

Match `VendorCapabilityProfile.grantScope`. Explain how the vendor
scopes a single grant:

- e.g., "perLocation — each F&F location requires its own OAuth flow.
  The vendor's `business_id` claim in the access token identifies one
  vendor location only."
- e.g., "operatorWide — a single grant returns a list of vendor
  locations the operator can pick from. F&F maps each chosen vendor
  location to one F&F `location_id` in the connect flow."

---

## Module disambiguation

Only required for ADP / QuickBooks. Other vendors: "N/A — single module."

| Module | Detection | Outcome |
|---|---|---|
| Workforce Now | `oauth_token.product == 'WFN'` | INTEGRATE |
| Workforce Manager | `oauth_token.product == 'WFM'` | INTEGRATE |
| RUN | `oauth_token.product == 'RUN'` | Refused with friendly message |

---

## Edge cases

- **Refresh token expiry** (90 days unused): connection flips to
  `error` with operator-facing copy "Please reconnect <vendor> and
  sign in again."
- **Account deletion** (vendor returns 404 on token introspection):
  connection flips to `error` with copy "Your <vendor> account no
  longer exists. Please connect a different account or check with
  <vendor> support."
- **Scope downgrade by vendor**: vendor returns access token with
  fewer scopes than requested → adapter rejects, surfaces error
  "<Vendor> denied required permissions; please reconnect and approve
  all requested permissions."
- **Unknown errors**: log + retry once; on second failure, flip to
  `error`.
