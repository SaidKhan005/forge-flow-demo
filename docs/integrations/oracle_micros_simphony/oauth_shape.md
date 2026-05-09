# Oracle MICROS Simphony — OAuth Shape

**Vendor ID**: `oracle_micros_simphony`
**Source documentation**: <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/authenticate.html>
**Retrieval date**: 2026-05-04

---

## Flow type

`client_credentials` — Oracle MICROS Simphony issues a client id and
client secret at partner activation, scoped to one organization +
location reference. The adapter exchanges the credential pair for a
short-lived bearer access token via the documented `POST
/sim/api/v2/oauth/token` endpoint. There is no end-user authorization
hop; the operator authorizes F&F at the partner-portal level when
sandbox / production credentials are issued.

Cite vendor doc:
<https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/authenticate.html>

---

## Scopes requested

Simphony's documented `client_credentials` flow does not expose a
granular scope vocabulary in the public docs as of the 2026-05-04
retrieval. The bearer access token's permissions are bound to the
client id at partner activation; F&F's partner application requests
the minimum-privilege subset the partnership permits:

| Scope (Simphony permission) | Unlocks | Required for |
|---|---|---|
| `posData.getGuestChecks.read` | Read paged guest checks for the bound `locRef` | Backfill + polling |
| `posData.getCheckById.read` | Reconciliation lookup by `chkNum` | Optional manual reconcile from admin debug surface |
| `orgData.locations.read` | Enumerate the org's locations to bind one F&F `location_id` per OAuth grant | Connect-flow location selection |

Extra Simphony permissions the adapter doesn't request:

- payment / cardholder data — out of scope (PCI; see `field_mapping.md`).
- employee / labor data — labor adapter family (Phase 8.S) handles it.
- inventory / menu writes — out of scope for V1.

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | ~1h (vendor-documented short-lived bearer) | Refresh proactively at `expires_at - 1h` |
| Refresh token | n/a (`client_credentials` re-uses the secret) | The adapter re-runs the token endpoint with the stored client id + secret to mint a new access token; there is no refresh-token rotation |

---

## Refresh semantics

- **Proactive refresh**: `pg_cron` job at 5 minutes past every hour
  scans `vendor_credentials` for tokens with
  `token_expires_at < now() + interval '24 hours'` and re-runs
  `POST /sim/api/v2/oauth/token`. See
  `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: `connector_connection.status` flips to
  `error`; audit row written. Email notification deferred to
  `9.8.email` follow-up per V1 lean cut 2 — no `email_outbox` row at
  V1 ship.
- **Rotating vs sliding**: client_credentials does not rotate. The
  client id + secret pair is the durable credential; the adapter
  rotates the access token only.
- **Revocation**: Simphony documents a partner-portal-driven
  revocation; the adapter does not call a revoke endpoint on
  disconnect (none is documented for the `client_credentials` token).
  Disconnect wipes the stored client secret so a future refresh
  attempt fails fast.

---

## Refresh handling (broker delegation)

The cross-tenant OAuth refresh worker
(`tool/oauth_refresh_worker/main.dart`) DOES carry a closure for
Oracle MICROS Simphony — `oracle_micros_simphony` is in the
unconditionally-wired set in `buildProductionRefreshClosures` because
the `client_credentials` exchange uses per-tenant
`metadata.client_id` + `metadata.client_secret` (no app-wide secrets
to gate on). The closure factory is
`makeOracleMicrosSimphonyOauthExchangeClosure` in
`lib/integrations/_common/production_oauth_refresh_closures.dart`.

Phase 5 audit reconciliation: an earlier audit framed Simphony as
mTLS. That was incorrect; Simphony Gen2 uses OAuth `client_credentials`
per the vendor's authenticate doc. The audit reconciliation is
recorded in
`docs/contracts/hardening_rls_and_repository_pattern_contract.md`.

---

## Per-location vs operator-wide grant

`perLocation`

Match `VendorCapabilityProfile.grantScope`. Each Simphony `locRef`
(location reference) is bound to its own partner-issued credential
pair, so each F&F location requires its own OAuth flow. The
connect-flow widget surfaces a per-location "Connect Oracle MICROS
Simphony" button; multi-location operators repeat the flow per
location. Bound `locRef` is stored in
`connector_connection.metadata.simphony_loc_ref` (see adapter `connect`
method).

---

## Module disambiguation

N/A — single module.

---

## Edge cases

- **Refresh token expiry** (n/a — client_credentials does not rotate;
  the secret is durable): the adapter never sees a "refresh expired"
  error from Simphony's token endpoint. The 3-strike auto-disable
  path triggers when the secret is revoked at the partner portal.
- **Account / location deletion** (vendor returns 404 on
  `getGuestChecks` for the bound `locRef`): connection flips to
  `error` with copy "Your Oracle MICROS Simphony location no longer
  responds. Please confirm the location is still active in your
  Simphony portal."
- **Scope downgrade by vendor**: Simphony returns access tokens with
  the permissions the partner application requested. If the partner
  application later loses a permission (e.g., partnership tier
  change), `getGuestChecks` returns 403 → adapter flips to `error`
  on the third consecutive failure.
- **Unknown errors**: log + retry once; on second failure within the
  same poll tick, surface the error to `connector_sync_log` and
  count as one of the 3-strike consecutive failures.
