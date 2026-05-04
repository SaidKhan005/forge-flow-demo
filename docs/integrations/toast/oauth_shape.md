# Toast — OAuth Shape

**Vendor ID**: `toast`
**Source documentation**:
<https://doc.toasttab.com/doc/devguide/apiAuthenticationOverview.html>
**Retrieval date**: 2026-05-03

---

## Flow type

`client_credentials`

Toast issues access tokens via `POST
/authentication/v1/authentication/login` with body shape:

```json
{
  "clientId": "<F&F partner id>",
  "clientSecret": "<F&F partner secret>",
  "userAccessType": "TOAST_MACHINE_CLIENT"
}
```

The `userAccessType: TOAST_MACHINE_CLIENT` claim binds the request to
the Standard / Partner machine-to-machine flow. F&F does not run an
authorization-code flow because Toast couples machine credentials to
a partner program rather than a per-operator browser redirect.

Cite vendor doc:
<https://doc.toasttab.com/doc/devguide/apiAuthenticationOverview.html>

---

## Scopes requested

Exact scope strings:

| Scope | Unlocks | Required for |
|---|---|---|
| `orders:read` | Read orders + line items via `ordersBulk` | Backfill + polling |
| `partners:read` | Resolve restaurant config + grant scope | Connect-time identity binding |

Scopes are issued at the partner-registration level. Toast does not
expose granular per-call scope downgrade; the partner registration
defines the maximum surface, and the adapter consumes only the two
scopes above.

Extra scopes Toast offers but the adapter does not request:

- `customers:read` — not requested per privacy policy (forbidden
  fields documented in [field_mapping.md](field_mapping.md)).
- `payments:read` — not requested; PCI scope.
- `menus:write` / `orders:write` — not requested; F&F never writes
  into the operator's POS.

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | ~1h (vendor-defined) | Refresh proactively at `expires_at - 1h` via `oauth_refresh_cron.dart` |
| Refresh token | n/a | client_credentials returns a fresh token on each login; no refresh-token rotation |

---

## Refresh semantics

- **Proactive refresh**: cron at 5 minutes past every hour scans
  `vendor_credentials` for tokens with
  `token_expires_at < now() + interval '24 hours'` and re-runs the
  client_credentials login. Mirrors the framework's
  `oauth_refresh_cron.dart` cadence.
- **Reactive refresh on 401**: adapter retries once after a fresh
  client_credentials exchange.
- **3 consecutive failures**: connection status flips to `error`;
  audit row written. Email notification deferred to `9.8.email`
  follow-up per V1 lean cut 2.
- **Rotating vs sliding**: n/a — every login mints a fresh token; no
  rotating refresh token.
- **Revocation**: Toast does not expose a `/oauth/revoke` for
  client_credentials. The adapter's `disconnect` wipes the local
  credential row + unregisters the webhook subscription via
  `DELETE /webhooks-config/v1/webhook/{subscriptionId}`. The token
  itself ages out within ~1h.

---

## Per-location vs operator-wide grant

`perLocation`

Match `VendorCapabilityProfile.grantScope`. Toast's `restaurantGuid`
identifies a single restaurant location. Multi-location operators
run one client_credentials flow per location — same partner
credentials, different `restaurantGuid` claim per session.

The connect flow captures the `restaurantGuid` either via:
- the OAuth state token (production path — the framework's start
  route encodes it), or
- the `keyPaste.username` field (engineering-slice fixture path —
  used in tests so the adapter is fully exercisable offline).

---

## Module disambiguation

N/A — Toast has a single product surface. The adapter's
`capabilityProfile.modules` is empty.

---

## Edge cases

- **Refresh failure (network)** — the cron retries on the next tick;
  three consecutive failures flip the connection to `error`.
- **`clientSecret` revoked by Toast** (vendor returns 401 on every
  exchange): connection flips to `error` with operator-facing copy
  "Toast revoked our access. Please reconnect and approve the
  Forge & Flow integration again."
- **Restaurant deleted by operator** (vendor returns 404 on
  `/restaurants/v1/restaurants/{guid}`): connection flips to `error`
  with copy "We can't find this Toast restaurant any more. Please
  reconnect or pick a different restaurant."
- **Scope downgrade by Toast** — Toast does not support per-call
  scope downgrade; the partner registration is the source of truth.
  If the partner registration is downgraded mid-flight (vendor-side
  ops change), every subsequent `ordersBulk` call returns 403 — the
  adapter logs and fails the connection state to `error` with copy
  "Toast denied required permissions. Please contact Forge & Flow
  support so we can re-validate the partner registration."
- **Unknown 5xx** — log + retry once with exponential backoff
  (framework default); on second failure, surface the operator-
  facing error and let the cron's 3-strike rule eventually flip the
  connection.
