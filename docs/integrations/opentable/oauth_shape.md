# OpenTable — OAuth Shape

**Vendor ID**: `opentable`
**Source documentation**: <https://restaurant.opentable.com/products/opentable-platform/>
(operator-facing only — partner doc gated; see `api_consumed.md`)
**Retrieval date**: 2026-05-04

> **Every section in this file is an assumption to verify in
> `8R.OT.live.sandbox`.** OpenTable's OAuth grant shape, scope strings,
> and token lifetimes are released to partners after the partnership
> program clears (see `partnership_status.md`). The adapter is
> engineered against `authorization_code` because every operator-
> facing OpenTable surface routes through a "Sign in with OpenTable"
> step, and against rotating refresh tokens because that is the
> industry-standard reservation-vendor shape.

---

## Flow type

`authorization_code` — assumption.

The proxy mints a state token on the start route, redirects the
operator to OpenTable's hosted sign-in, and the callback route
exchanges the authorization code for an access + refresh token via
`POST /api/v2/oauth/token` (assumed path, see `api_consumed.md`).

Cite vendor doc:
<https://restaurant.opentable.com/products/opentable-platform/>

---

## Scopes requested

Exact scope strings — assumption. The minimum-privilege subset
requested at the start route is the smallest set required to read
reservation data and register a webhook subscription:

| Scope (assumed) | Unlocks | Required for |
|---|---|---|
| `reservations.read` | Read reservation list + detail | Backfill + polling |
| `webhooks.write` | Auto-register webhook subscription | First-connect webhook setup |

Extra scopes the vendor likely offers but the adapter does NOT request:

- guest-detail / customer-record scopes — not requested per privacy
  posture (`field_mapping.md` "Forbidden fields").
- payment / card-on-file scopes — out of PCI scope.
- write-back scopes (creating, modifying, cancelling reservations) —
  F&F is read-only at the reservation surface; the adapter never
  mutates vendor state.

The `8R.OT.live.sandbox` slice will verify the exact scope strings
against the partner doc and trim down if the vendor exposes a
narrower read-only scope.

---

## Token lifetime

| Token | TTL (assumed) | Notes |
|---|---|---|
| Access token | 1h | Refresh proactively at `expires_at - 1h` per the framework's `oauth_refresh_cron`. |
| Refresh token | 90 days, rotating | Each refresh issues a new refresh token; old token revoked. Industry standard. |

Both numbers are assumptions; verify against the partner doc in
`8R.OT.live.sandbox`. If the access token TTL is shorter (e.g.,
30 minutes), the refresh cron's 1-hour horizon still picks up the
expiring rows; no adapter change required.

---

## Refresh semantics

- **Proactive refresh**: cron at 5min past every hour scans
  `vendor_credentials` for tokens with `token_expires_at < now() + 24h`
  and refreshes via `POST /api/v2/oauth/token` with
  `grant_type=refresh_token`. See
  `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: connection status flips to `error`;
  audit row written. Email notification deferred to `9.8.email`
  follow-up per V1 lean cut 2 (no auto-disable email wiring at V1).
- **Rotating vs sliding**: rotating (assumed). Each refresh issues a
  new refresh token; the old token is revoked.
- **Revocation**: vendor exposes `/api/v2/oauth/revoke` (assumed);
  adapter calls it on disconnect best-effort. Vendor outage MUST NOT
  block the local credential wipe.

---

## Refresh handling (broker delegation)

The OAuth refresh worker (`tool/oauth_refresh_worker/main.dart`) does
NOT carry a refresh closure for OpenTable. Rotation lives INSIDE the
production transport class
`OpenTableReservationProductionApiClient.refresh(...)` in
`lib/integrations/reservation/opentable_reservation_production_api_client.dart`,
which reads the per-tenant `client_id` / `client_secret` from
`OpenTableCredentialStore` and POSTs the `refresh_token` grant
directly. Duplicating that path in the broker would split rotation
responsibility across two surfaces.

Behavior at runtime:

- The transport's `refresh(...)` method is invoked by the adapter on
  the reactive 401 path (and by any future internal scheduling
  surface inside the production client).
- When the cross-tenant OAuth refresh worker claims a near-expiry
  OpenTable row, it log-and-skips with the structured reason
  `opentable_transport_internal_refresh` (see
  `kVendorsWithoutRefreshClosureReason` in
  `tool/oauth_refresh_worker/main.dart`). No failure-count increment
  on the row, no auto-disable.

If a future slice consolidates all rotation behind the broker, the
closure factory lands in
`lib/integrations/_common/production_oauth_refresh_closures.dart` and
this section flips to "wired."

---

## Per-location vs operator-wide grant

`perLocation`

OpenTable's `rid` (restaurant identifier) scopes a single OAuth
grant to one restaurant. Each F&F location requires its own OAuth
flow with the vendor; the connect flow re-runs the start → callback
loop per location. Match `VendorCapabilityProfile.grantScope =
VendorGrantScope.perLocation`.

The `restaurant_id` claim discovered on the first reservations page
(see `connect()` in
`lib/integrations/reservation/opentable_reservation_adapter.dart`)
lands in `connector_connection.metadata.restaurant_id` and the
inbound-webhook binding-cross-check uses that key.

---

## Module disambiguation

N/A — OpenTable does not expose multiple modules from the same OAuth
flow. `VendorCapabilityProfile.modules = const <String>[]`.

---

## Edge cases

- **Refresh token expiry** (90 days unused): connection flips to
  `error` with operator-facing copy "Please reconnect OpenTable and
  sign in again."
- **Account deletion / partnership revoked** (vendor returns 4xx on
  token introspection): connection flips to `error` with copy "Your
  OpenTable connection is no longer authorized; please contact
  OpenTable support or reconnect."
- **Scope downgrade by vendor**: vendor returns access token with
  fewer scopes than requested → adapter rejects, surfaces error
  "OpenTable denied required permissions; please reconnect and
  approve all requested permissions."
- **Unknown errors**: log + retry once; on second failure, flip to
  `error`. The 3-consecutive-failure auto-disable behavior runs
  through the framework's `oauth_refresh_cron` (no separate adapter
  surface needed).

Every edge case above is the **intended** behavior; the
`8R.OT.live.sandbox` slice exercises each one against the vendor
sandbox once partnership credentials arrive.
