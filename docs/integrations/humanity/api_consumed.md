# Humanity (TCP) — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `humanity`
**Category**: `labor`
**Source documentation**: <https://platform.humanity.com/v1.0>
(Humanity Platform v1 — operated by TCP Software since 2020)
**Retrieval date**: 2026-05-04
**API version pinned**: `v1.0`

---

## Auth method

`legacy_username_password` — Humanity's documented v1 API still uses
the OAuth 2.0 Resource Owner Password Credentials grant
(`grant_type=password`). The connect flow accepts a username (the
operator's Humanity account email) and a password posted server-side
to the token endpoint; the issued bearer token is stashed in
`vendor_credentials` (pgcrypto envelope) and the adapter only ever
sees a [VendorCredentialHandle].

Cite vendor doc:
<https://platform.humanity.com/v1.0/oauth2/token> (token endpoint
section).

> **No partnership program.** Humanity does not run a developer
> partner program for v1 — any operator with an active Humanity
> account can connect by pasting their existing credentials. The
> `*.live.sandbox` and `*.live.prod` slices verify against a F&F
> test account; production rollout does not gate on a partnership
> review.
>
> **No OAuth.** Humanity v1 does not offer an authorization-code
> OAuth flow on the public docs surface; the password grant is the
> documented path. F&F treats this as the framework's `keyPaste`
> code path (`authMode = keyPaste` on the capability profile) and
> tells operators in the connect modal that the credentials are
> stored server-side and used only to read scheduling data.

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| POST | `/oauth2/token` | Legacy password-grant token issuance (called by the proxy on connect; adapter never sees plaintext at runtime) | vendor-soft, undocumented | n/a |
| GET | `/shifts` | Backfill + poll-incremental — paged listing of shifts since `last_modified` | vendor-soft, undocumented | server-issued cursor token; null = end of listing |
| GET | `/shifts/sample` | Heavy-but-bounded sample probe used by `testConnection` | shared with above | n/a |
| GET | `/timeclocks` | Adjacent surface for clock-in / clock-out punches; same shape as `/shifts` for the canonical fact write | shared | server-issued cursor token |
| GET | `/positions` | Role hierarchy (`positions[].name`) for the role-mapping admin step | shared | n/a |
| GET | `/employees` | Employee directory for `employee_id` mapping | shared | server-issued cursor token |
| GET | `/company` | Account-wide config (timezone, business-day rollover hint) read on first connect | low cadence | n/a |
| POST | `/oauth2/revoke` | Best-effort credential revoke on disconnect | low cadence | n/a |

Every endpoint listed here is invoked by the adapter at
`lib/integrations/labor/humanity_labor_adapter.dart` (or by the proxy
on the adapter's behalf — `/oauth2/token` and `/oauth2/revoke` are
proxy-side hops since plaintext credentials never reach the
adapter); every endpoint invoked by the adapter is listed here.
Codex verifies the diff.

> **Webhook delivery.** Humanity's documented v1 API exposes **no**
> webhook delivery surface. The adapter is therefore poll-only:
> `webhookSupport = pollOnly` on the capability profile and
> `handleWebhook` throws `UnsupportedError` per
> `docs/contracts/vendor_adapter_slice_contract.md`. See
> `webhook_signature.md` (single-line N/A).

---

## Sandbox / test environment

**Base URL**: `https://platform.humanity.com/v1.0` (same host as
production; Humanity does not maintain a separate sandbox
hostname for v1)
**Sign-up**: any Humanity account can be used; F&F's
`8.S.HM.live.sandbox` slice will use a dedicated F&F-owned demo
restaurant account.
**Known limitations**:
- v1 does not expose webhook delivery, so live verification covers
  polling resume + idempotency only (no signature reject row).
- Sandbox returns real shift data when the demo account has shifts
  posted; the `*.live.sandbox` slice's first run seeds the demo
  account with synthetic shifts mirroring
  `humanityBackfillBatchPage1`.

---

## Production environment

**Base URL**: `https://platform.humanity.com/v1.0`
**Partnership requirements**: none — any operator with an active
Humanity v1 account can connect. The `8.S.HM.live.prod` slice
verifies the same code path against the same hostname using a real
operator's credentials provided once the operator opts in.
**Rate-limit policy**: vendor does not publish a single rate-limit
document; observed throttle behavior surfaces during the
`*.live.sandbox` run and lands in the slice report.
**Quota**: undocumented; the bridge worker token-bucket-throttles
defensively at 60 req/min/operator until the `*.live.*` slices
observe a higher safe ceiling.

---

## Versioning

**Vendor's deprecation policy**: <https://platform.humanity.com/v1.0>
(no separate deprecation document published)
**Adapter pinned to**: `v1.0`
**Vendor's last announced breaking change**: not announced as of
2026-05-04 retrieval. (Note: TCP's announced direction is to
encourage migration to TCP-branded scheduling products over the
medium term; v1 remains in service while existing customers keep
using it.)
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. The
`api_consumed.md` retrieval date drives the CI lint warning.
