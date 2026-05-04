# 7shifts — OAuth Shape

**Vendor ID**: `seven_shifts`
**Source documentation**: <https://developers.7shifts.com/reference/oauth>
**Retrieval date**: 2026-05-04

---

## Flow type

`authorization_code`

The proxy mints a state token on the start route, redirects the
operator to 7shifts' hosted sign-in, and the callback route exchanges
the authorization code for an access + refresh token via
`POST /v2/oauth/token`. Cite vendor doc:
<https://developers.7shifts.com/reference/oauth>

---

## Scopes requested

Exact scope strings — minimum-privilege subset chosen per
<https://developers.7shifts.com/reference/oauth-scopes>:

| Scope | Unlocks | Required for |
|---|---|---|
| `time_punches.read` | Read time punches (incl. `approved` boolean) | Backfill + polling + Phase 7.58 Primary Driver `is_approved` source |
| `schedules.read` | Read planned shifts + schedule data | Read-only schedule context (alongside punches) |
| `users.read` | Read user roster + per-employee wage rates | Wage-source binding + role-mapping override |
| `roles.read` | Read role hierarchy | FOH/BOH/manager/excluded mapping |
| `payroll_periods.read` | Read payroll-period close instants | Phase 7.58 Primary Driver `payroll_period_closed_at` source (poll-only fallback) |
| `webhooks.write` | Auto-register webhook subscriptions | First-connect webhook setup (Gourmet plan only) |
| `companies.read` | Read company metadata + plan tier | Plan-tier detection that gates webhook auto-registration |
| `locations.read` | Read locations under the operator-wide grant | OperatorWide grant scope mapping |

Extra scopes the vendor offers but the adapter does NOT request:

- `time_punches.write` / `schedules.write` / `users.write` /
  `roles.write` — F&F is read-only at the scheduling surface; the
  adapter never mutates vendor state. Hard Promise #6 (advisor
  speaks recommendations, not commands) excludes write-back at
  launch.
- `payments.*` / `tips.*` — out of PCI / payroll scope.
- Guest / customer scopes — n/a for a labor vendor.

The `8.S.7S.live.sandbox` slice will verify the exact scope strings
against the live OAuth grant and trim down if the vendor exposes a
narrower read-only scope.

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | 1h (assumed) | Refresh proactively at `expires_at - 1h` per the framework's `oauth_refresh_cron`. |
| Refresh token | 30-90 days, rotating (assumed) | Each refresh issues a new refresh token; old token revoked. |

Both numbers are the developer-reference defaults; verify exact
lifetimes in `8.S.7S.live.sandbox`. If the access token TTL is
shorter (e.g., 30 minutes), the refresh cron's 1-hour horizon still
picks up the expiring rows; no adapter change required.

---

## Refresh semantics

- **Proactive refresh**: cron at 5min past every hour scans
  `vendor_credentials` for tokens with `token_expires_at < now() + 24h`
  and refreshes via `POST /v2/oauth/token` with
  `grant_type=refresh_token`. See
  `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: connection status flips to `error`;
  audit row written. Email notification deferred to `9.8.email`
  follow-up per V1 lean cut 2 (no auto-disable email wiring at V1).
- **Rotating vs sliding**: rotating per the developer reference. Each
  refresh issues a new refresh token; the old token is revoked.
- **Revocation**: 7shifts v2 OAuth does not document a `/revoke`
  endpoint at the 2026-05-04 retrieval date. The adapter's
  `disconnect()` calls a no-op `revoke()` on the transport so the
  surface is in place; vendor outage MUST NOT block the local
  credential wipe.

---

## Per-location vs operator-wide grant

`operatorWide`

A single 7shifts OAuth grant covers every location under the
operator's company per the developer reference. The adapter's
`connect()` flow:

1. Exchanges the authorization code for tokens.
2. Calls `fetchCompanyInfo()` to discover the company id + plan tier.
3. Stores `company_id` in `connector_connection.metadata` for the
   inbound-webhook binding cross-check.

The connect flow does NOT re-run per location — one OAuth grant maps
to N F&F locations, all bound to the same `company_id`. The admin
widget surfaces the location list (via
`GET /v2/company/{id}/locations`) so the operator can map each
7shifts location to an F&F location during onboarding.

Match `VendorCapabilityProfile.grantScope =
VendorGrantScope.operatorWide`.

---

## Module disambiguation

N/A — 7shifts does not expose multiple modules from the same OAuth
flow. `VendorCapabilityProfile.modules = const <String>[]`.

ADP (Workforce Now / Workforce Manager / RUN) and QuickBooks
(Time / Accounting / Payroll) are the two scheduling vendors that
require module disambiguation; 7shifts ships a single product
surface.

---

## Plan-tier detection (gates webhook auto-registration)

`fetchCompanyInfo()` reads the company's pricing tier from
`GET /v2/company/{company_id}` (the response includes
`plan_tier` / `subscription` per the developer reference). The
adapter compares the lower-cased value against
`kSevenShiftsGourmetPlanTier`:

- Gourmet → `connect()` invokes `registerWebhook()` with every event
  in `kSevenShiftsSubscribedWebhookEvents`.
- Lower tier (Entree / Appetizer / The Works) → `connect()` skips
  the webhook call; `ConnectResult.metadata` omits `webhook_id`;
  `TestConnectionResult.note` carries the operator-facing copy
  `kSevenShiftsNonGourmetNote` (`"Webhooks require Gourmet plan;
  falling back to polling-only."`).

The polling path runs in both cases — Gourmet operators get webhooks
PLUS polling for resilience; lower-tier operators get polling only.
Phase 7.58 Primary Driver `payroll_period_closed_at` lands in
canonical facts on every polling tick via
`fetchLatestPayrollPeriodClosedAt()` regardless of tier.

---

## Edge cases

- **Refresh token expiry** (30-90 days unused): connection flips to
  `error` with operator-facing copy "Please reconnect 7shifts and
  sign in again."
- **Plan downgrade after connect**: if the operator drops from
  Gourmet to a lower tier mid-connection, the webhook subscription
  remains registered but 7shifts stops delivering events. The next
  polling tick still lands every punch + payroll-period close; the
  admin widget surfaces a "Webhooks unavailable on current plan;
  using polling" note when the most recent webhook delivery is older
  than 24h. Verified in `8.S.7S.live.sandbox`.
- **Account deletion / vendor revocation** (vendor returns 4xx on
  token introspection): connection flips to `error` with copy "Your
  7shifts connection is no longer authorized; please reconnect or
  contact 7shifts support."
- **Scope downgrade by vendor**: vendor returns access token with
  fewer scopes than requested → adapter rejects, surfaces error
  "7shifts denied required permissions; please reconnect and approve
  all requested permissions."
- **Unknown errors**: log + retry once; on second failure, flip to
  `error`. The 3-consecutive-failure auto-disable behavior runs
  through the framework's `oauth_refresh_cron` (no separate adapter
  surface needed).

Every edge case above is the **intended** behavior; the
`8.S.7S.live.sandbox` slice exercises each one against the vendor
sandbox.
