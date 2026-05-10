# ADP Workforce Now / Workforce Manager — OAuth Shape

**Vendor ID**: `adp`
**Source documentation**: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
(public ADP developer-portal API catalog. OAuth scope strings + token
TTLs are released to partners after the ADP Marketplace Developer
Participation Agreement clears; see `partnership_status.md`.)
**Retrieval date**: 2026-05-04

> **Every section in this file is an assumption to verify in
> `8.S.ADP.live.sandbox`.** The adapter is engineered against
> `authorization_code` because every operator-facing ADP Marketplace
> surface routes through a hosted "Sign in with ADP" step, and against
> rotating refresh tokens because that is the documented ADP
> Marketplace partner flow.

---

## Flow type

`authorization_code` — assumption.

The proxy mints a state token on the start route, redirects the
operator to ADP's hosted sign-in (per module — WFN or WFM exposes
slightly different sign-in surfaces but the OAuth callback shape is
shared), and the callback route exchanges the authorization code for
an access + refresh token via `POST /auth/oauth/v2/token` (assumed
path, see `api_consumed.md`).

At production the flow ALSO requires mutual TLS — partner-issued
client certs land on the proxy at `*.live.prod` time.

Cite vendor doc:
<https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>

---

## Scopes requested

Exact scope strings — assumption. The minimum-privilege subset
requested at the start route is the smallest set required to read
schedule + punch + role data and register an event subscription:

| Scope (assumed) | Unlocks | Required for |
|---|---|---|
| `time.read` | Read time events / time cards / work schedules | Backfill + polling |
| `hr.workers.read` | Read worker directory + position / work-assignment | Role mapping + binding context |
| `event-subscriptions.write` | Auto-register ADP Marketplace event subscription | First-connect webhook setup |

Extra scopes the vendor likely offers but the adapter does NOT
request:

- Compensation / payroll scopes (`payroll.*`, `compensation.*`) —
  out of scope at V1; wage ingestion uses the worker `pay_rate`
  surface only when wage ingestion lights up at a later slice.
- Write-back scopes (creating, modifying, cancelling shifts) —
  F&F is read-only at the labor surface; the adapter never mutates
  vendor state.
- HR / benefits / demographic scopes — not requested per privacy
  posture (`field_mapping.md` "Forbidden fields").

The `8.S.ADP.live.sandbox` slice will verify the exact scope strings
against the partner doc and trim down if ADP exposes narrower
read-only scopes.

---

## Token lifetime

| Token | TTL (assumed) | Notes |
|---|---|---|
| Access token | 1h | Refresh proactively at `expires_at - 1h` per the framework's `oauth_refresh_cron`. |
| Refresh token | 90 days, rotating | Each refresh issues a new refresh token; old token revoked. ADP Marketplace standard. |

Both numbers are assumptions; verify against the partner doc in
`8.S.ADP.live.sandbox`. If the access token TTL is shorter (e.g.,
30 minutes), the refresh cron's 1-hour horizon still picks up the
expiring rows; no adapter change required.

---

## Refresh semantics

- **Proactive refresh**: cron at 5min past every hour scans
  `vendor_credentials` for tokens with
  `token_expires_at < now() + 24h` and refreshes via
  `POST /auth/oauth/v2/token` with `grant_type=refresh_token`. See
  `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: connection status flips to `error`;
  audit row written. Email notification deferred to `9.8.email`
  follow-up per V1 lean cut 2 (no auto-disable email wiring at V1).
- **Rotating vs sliding**: rotating (assumed). Each refresh issues
  a new refresh token; the old token is revoked.
- **Revocation**: vendor exposes `/auth/oauth/v2/revoke` (assumed);
  adapter calls it on disconnect best-effort. Vendor outage MUST
  NOT block the local credential wipe.

---

## Refresh handling (broker delegation)

**Status (2026-05-09)**: wired (broker-driven via
`makeAdpOauthRefreshClosure` in
`lib/integrations/_common/production_oauth_refresh_closures.dart`).

PR #455 (2026-05-08) initially placed ADP on
`kVendorsWithoutRefreshClosureReason` with reason
`adp_partner_ops_mtls_out_of_band`, on the theory that all rotation
was driven by ADP partner-ops on a vendor cadence. The 2026-05-09
re-investigation found that conflated two SEPARATE rotation surfaces:

1. **Partner-issued mTLS client certificate** — ADP partner-ops rotates
   the cert on a vendor-driven cadence. The cert lives in the worker's
   `http.Client` `SecurityContext` (Cloud Run-injected via
   `ADP_MTLS_CERT_PATH` / `ADP_MTLS_KEY_PATH`); F&F has no
   programmatic refresh path for the cert itself.
2. **OAuth `refresh_token`** — standard `grant_type=refresh_token`
   against `/auth/oauth/v2/token` using the per-tenant
   `client_id` / `client_secret` (HTTP Basic). The transport's
   `AdpLaborProductionApiClient.refresh(refreshToken:, module:)`
   already implements this; the persisted credential row carries the
   refresh token + per-tenant client credentials. This rotation IS
   programmatic and IS reachable from the worker's vantage point.

Behavior at runtime (post-2026-05-09):

- The cross-tenant OAuth refresh worker claims near-expiry ADP rows
  and calls `makeAdpOauthRefreshClosure` for each. The closure POSTs
  `grant_type=refresh_token` against `/auth/oauth/v2/token` with HTTP
  Basic auth (`client_id` / `client_secret` from `metadata`) and an
  `x-adp-module` header (read from `connectionMetadata.module`,
  falling back to `metadata.module`, then to the documented default
  `workforce_now`).
- ADP rotates the refresh token on every refresh; the new
  refresh_token threads back through `TokenRefreshResult.refreshToken`
  so the broker re-encrypts and persists it.
- mTLS continues to land on the worker's `http.Client` at boot; the
  closure itself is mTLS-agnostic. Partner-cert rotation remains a
  partner-ops out-of-band concern (covered in
  `partnership_status.md`).

If a future ADP partner-program change requires a different refresh
shape (e.g., assertion-based grants), the closure factory in
`production_oauth_refresh_closures.dart` is the single point of
update.

---

## Per-location vs operator-wide grant

`operatorWide`

ADP organizes a company across multiple worksites under a single
grant; one OAuth flow with the vendor covers all of the operator's
ADP-managed worksites. The adapter discovers worksite → F&F location
bindings from the worker directory after the grant lands; per-worksite
isolation comes from F&F's own `(operator_id, location_id)` scope on
canonical fact writes (`OperatorScopedRepository.withTenant`), not
from the OAuth grant itself.

Match `VendorCapabilityProfile.grantScope =
VendorGrantScope.operatorWide`.

---

## Module disambiguation (LOAD-BEARING)

ADP exposes three product surfaces. The connect flow MUST
disambiguate:

| Module id | Vendor portal label | Adapter behavior |
|---|---|---|
| `workforce_now` | ADP Workforce Now (WFN) | INTEGRATE — `connect()` proceeds: OAuth callback → token exchange → event-subscription auto-register → first backfill enqueued. |
| `workforce_manager` | ADP Workforce Manager (WFM) | INTEGRATE — same code path as WFN. Module is recorded in `connector_connection.metadata.module` so the adapter routes to WFM-specific endpoint shapes (e.g., `workAssignment.jobTitle` for role) at request time. |
| `run` | ADP RUN | REFUSED — `connect()` throws `ModuleRefusalException(vendorId='adp', moduleId='run', message=kAdpRunRefusalCopy)`. The picker renders the friendly copy verbatim and the connect modal aborts. |

The friendly RUN refusal copy is locked word-for-word in
`docs/phases/phase_8/vendor_master_list.md` "Module Disambiguation
Flags" and mirrored as `kAdpRunRefusalCopy` in
`lib/integrations/labor/adp_labor_adapter.dart`. The slice's tests
pin the constant to the master-list copy with an exact-string match;
any drift between the two fails the test.

`VendorCapabilityProfile.modules = ['workforce_now',
'workforce_manager', 'run']`. RUN is listed for picker
disambiguation only and bounces at connect time.

`connect()` also refuses unknown future modules (e.g., a hypothetical
`'lyric'`) with `ModuleRefusalException` so a new ADP product can't
silently slip through if ADP adds another product before F&F adopts
it. The picker does not yet expose this fourth path; the defense is
purely engineering-side.

---

## Edge cases

- **Refresh token expiry** (90 days unused): connection flips to
  `error` with operator-facing copy "Please reconnect ADP and
  sign in again."
- **Account deletion / DPA revoked** (vendor returns 4xx on
  introspection): connection flips to `error` with copy "Your ADP
  connection is no longer authorized; please contact ADP support
  or reconnect."
- **Scope downgrade by vendor**: vendor returns access token with
  fewer scopes than requested → adapter rejects, surfaces error
  "ADP denied required permissions; please reconnect and approve
  all requested permissions."
- **Module mismatch on reconnect**: if the operator originally
  connected with `workforce_now` and the reconnect callback returns
  a token claim that resolves to `workforce_manager`, the adapter
  flips `connector_connection.metadata.module` and writes an audit
  row. The framework treats this as a normal reconnect; downstream
  reads see the module change in metadata.
- **Unknown errors**: log + retry once; on second failure, flip to
  `error`. The 3-consecutive-failure auto-disable behavior runs
  through the framework's `oauth_refresh_cron` (no separate adapter
  surface needed).
- **mTLS cert expiry at production**: certs are operator-scoped and
  rotated by the framework; the adapter receives the active cert
  through `VendorCredentialHandle` and never sees plaintext. Cert
  rotation is a `*.live.prod` follow-up concern.

Every edge case above is the **intended** behavior; the
`8.S.ADP.live.sandbox` slice exercises each one against the vendor
sandbox once partnership credentials arrive.
