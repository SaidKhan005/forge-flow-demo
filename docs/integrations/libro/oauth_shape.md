# Libro Reserve — OAuth Shape

**Vendor ID**: `libro`
**Source documentation**: <https://libroreserve.github.io/api-documentation/#section/Authentication>
**Retrieval date**: 2026-05-04

---

## Flow type

`authorization_code`

Cite vendor doc: <https://libroreserve.github.io/api-documentation/#section/Authentication>

The operator clicks **Sign in with Libro** in the Vendor Connections
admin surface; the framework redirects to Libro's
`/oauth/authorize` endpoint with the F&F-issued state token; Libro
redirects back to the F&F callback URL with `code` + `state`; the
proxy exchanges `code` for an access + refresh token at
`POST /v1/oauth/token`.

---

## Scopes requested

Exact scope strings:

| Scope | Unlocks | Required for |
|---|---|---|
| `reservations.read` | Read reservation list, status transitions, party size. | Backfill + polling. |
| `webhooks.write` | Auto-register the F&F webhook URL on the operator's venue. | First-connect webhook setup. |

Minimum-privilege subset chosen. Extra scopes the vendor offers but
the adapter does NOT request:

- `guests.read` — would expose guest PII; not requested per
  `field_mapping.md` "Forbidden fields".
- `payments.read` — payment-card metadata; PCI scope.
- `reservations.write` — F&F never mutates vendor data at launch
  (Hard Promise #6).

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | 1h | Refresh proactively at `expires_at - 1h`. |
| Refresh token | 90 days, rotating | Each refresh issues a new refresh token; old token revoked. |

Confirm on `8R.LB.live.sandbox`.

---

## Refresh semantics

- **Proactive refresh**: shared cron at
  `lib/services/integration/oauth_refresh_cron.dart` scans
  `vendor_credentials` for tokens with
  `token_expires_at < now() + 24h` and refreshes. No advisory locks
  (banned per V1 lean cut 2).
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: `vendor_credentials.consecutive_refresh_failures`
  hits 3 → connector status flips to `error`, audit row written.
  Email notification deferred to the `9.8.email` follow-up per V1
  lean cut 2.
- **Rotating vs sliding**: rotating — each refresh issues a new
  refresh token; the old refresh token is revoked.
- **Revocation on disconnect**: adapter calls
  `POST /v1/oauth/revoke` via `LibroHttpClient.revokeCredential`.

---

## Per-location vs operator-wide grant

`perLocation`

Match `VendorCapabilityProfile.grantScope`. Each F&F location
requires its own OAuth flow with Libro: Libro's auth response
binds the access token to a single `venue_id`. The connect flow
records `connector_connection.metadata.venue_id` and the inbound
webhook handler's `WebhookBindingExtractor` cross-checks the
payload's `venue_id` against this metadata key (registered in
`inbound_webhook_handler.dart` `_defaultSpecs['libro']`).

---

## Module disambiguation

N/A — single module. Libro does not split product lines (in contrast
to ADP / QuickBooks).

---

## Edge cases

- **Refresh token expiry** (90 days unused): connection flips to
  `error` with operator-facing copy "Your Libro connection
  expired. Please sign in again to keep reservations flowing."
- **Account deletion** (Libro returns 404 on token introspection):
  connection flips to `error` with copy "Your Libro venue is no
  longer accessible. Please reconnect or contact Libro support."
- **Scope downgrade by vendor**: Libro returns access token with
  fewer scopes than requested → adapter rejects, surfaces "Libro
  denied required permissions; please reconnect and approve all
  requested permissions."
- **Unknown errors**: log + retry once; on second failure, flip to
  `error`.
