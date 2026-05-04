# Lightspeed Restaurant K-Series — OAuth Shape

**Vendor ID**: `lightspeed_lsk`
**Source documentation**: <https://api-portal.lsk.lightspeed.app/quick-start/authentication/authorization-overview>
**Retrieval date**: 2026-05-03

---

## Flow type

`authorization_code`.

Cite vendor doc:
<https://api-portal.lsk.lightspeed.app/quick-start/authentication/authorization-overview>

The adapter never uses `client_credentials`; every operator grant is
a per-business-location user-driven authorization.

---

## Scopes requested

Exact scope strings:

| Scope | Unlocks | Required for |
|---|---|---|
| `orders-api` | "Read business information, floors, menus, discounts, and production instructions. Configure webhooks. Read and write orders and payments." | Orders read + auto-register webhook |
| `financial-api` | Sales / business-day-sales / aggregated-sales reads | Backfill + polling on `/f/v2/business-location/{id}/sales` |
| `offline_access` | Long-lived refresh tokens (40 days vs 30 minutes) | Cron-driven refresh; production stability |

Minimum-privilege subset chosen. Extra scopes the vendor offers but
the adapter does NOT request:

- `staff-api` — labor attribution lives on the labor-vendor side
  (Phase 8.S); not needed for POS.
- `items` — menu management; the operator dashboard does not
  consume item-level data at V1.
- `propertymanagement` — PMS integrations; out of scope.
- `reservations-api` / `reservation-*` — reservations live on Phase
  8R adapters.
- `id-cards` — out of scope.

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | 25 minutes | Refresh proactively at `expires_at - 1h` (cron horizon = 24h) |
| Refresh token (with `offline_access`) | 40 days | Rotating: each refresh issues a new refresh token; old token revoked |
| Refresh token (without `offline_access`) | 30 minutes | Not used by the adapter; F&F always requests `offline_access` |

Cite vendor doc:
<https://api-portal.lsk.lightspeed.app/quick-start/authentication/authorization-overview>

---

## Refresh semantics

- **Proactive refresh**: cron at 5 minutes past every hour scans
  `vendor_credentials` for tokens with
  `token_expires_at < now() + 24h` and refreshes via
  `POST /oauth/token` with `grant_type=refresh_token`. See
  `lib/services/integration/oauth_refresh_cron.dart` (V1 lean cut 2:
  no `pg_try_advisory_lock`; one cron instance is enough at V1
  scale).
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: connection status flips to `error`;
  audit row written via `oauth_refresh_cron`. Email notification is
  deferred to the `9.8.email` follow-up per V1 lean cut 2 (the path
  exists in code; the email-side wiring lands later).
- **Rotating vs sliding**: rotating. Each refresh issues a new
  refresh token; old token becomes invalid. The
  `LightspeedLskOAuthClient.refresh` impl writes the new envelope to
  `vendor_credentials` atomically and discards the prior ciphertext.
- **Revocation**: vendor exposes `POST /oauth/revoke`. The adapter
  calls it on disconnect (best-effort; vendor outage does not block
  the local credential wipe).

---

## Per-location vs operator-wide grant

`perLocation`.

Match `VendorCapabilityProfile.grantScope`. Each F&F location
requires its own OAuth flow. The vendor's `business_id` claim in the
access token identifies one Lightspeed business location only. F&F
records the `business_id` in
`connector_connection.metadata.business_id` so the inbound webhook
binding cross-check (step 2 of `InboundWebhookHandler.dispatch`) can
refuse cross-tenant misroutes with 403.

---

## Module disambiguation

N/A — single module. Lightspeed K-Series is a single product;
unlike ADP / QuickBooks, there is no Workforce-Now-vs-Manager-vs-RUN
fork.

---

## Edge cases

- **Refresh token expiry** (40 days unused with `offline_access`):
  connection flips to `error` with operator-facing copy "Please
  reconnect Lightspeed Restaurant K-Series and sign in again."
- **Account deletion** (vendor returns 404 on token introspection):
  connection flips to `error` with copy "Your Lightspeed account no
  longer exists. Please connect a different account or check with
  Lightspeed support."
- **Scope downgrade by vendor**: vendor returns access token whose
  `scope` claim is missing one of the requested scopes → adapter
  rejects, surfaces error "Lightspeed denied required permissions;
  please reconnect and approve all requested permissions."
- **Unknown errors during refresh**: log + retry once; on second
  failure, increment `consecutive_refresh_failures`; on third, flip
  to `error`.
