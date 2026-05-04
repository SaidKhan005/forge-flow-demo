# Revel Systems — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `revel`
**Category**: `pos`
**Source documentation**: <https://developer.revelsystems.com/revelsystems/docs/webhooks>
**Retrieval date**: 2026-05-03
**API version pinned**: `v1-2026-05-03`

---

## Auth method

`oauth` — OAuth 2.0 `client_credentials` grant.

Token endpoint: `POST https://authentication.revelup.com/oauth/token`
(`grant_type=client_credentials`, `client_id`, `client_secret`,
`audience` form fields). Returns a JWT bearer with an 86,400-second
(24-hour) TTL. There is no refresh token; the framework's hourly
`pg_cron` refresh job re-exchanges the same `client_id` /
`client_secret` pair via [RevelOAuthRefresher].

See `oauth_shape.md` for the flow detail.

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| POST | `https://authentication.revelup.com/oauth/token` | Mint JWT bearer (`client_credentials`) | undocumented; safe to call once per 24h per location | n/a |
| GET | `/external/integrations` | Discover the operator's integration scope; backfill / poll order history (modified-since window) | undocumented; framework caps poll cadence at 5min | `page` + `pageSize` (default 10, max 100); `totalItems`, `totalPages`, `items[]` |
| GET | `/external/integrations/{id}` | Fetch a specific order on webhook fall-through (rare; partial payload escape hatch) | shared with above | n/a |
| GET | `/external/message-log` | Operator-self-serve "view recent webhook deliveries" surface; F&F admin can use it during `*.live` triage | same window | same shape; filters: `state`, `instanceName`, `createdOnStart`, `createdOnEnd` |
| POST | `/webhooks/subscriptions` (auto-register, exact path TBD at sandbox) | Register the F&F webhook URL on first connect; subscribe to `order.finalized` | undocumented | n/a; returns subscription id stored in `connector_connection.metadata.webhook_subscription_id` |
| DELETE | `/webhooks/subscriptions/{subscription_id}` | Unregister webhook on disconnect | undocumented | n/a |

Every endpoint listed here is invoked by the adapter
(`lib/integrations/pos/revel_pos_adapter.dart`) via [RevelTransport];
every transport method has a row here. The `*.live.sandbox` slice
diffs the documented endpoint list against the calls the adapter
actually makes against vendor sandbox.

Production base URL: `https://api.revelsystems.com`.

---

## Sandbox / test environment

**Base URL**: Revel issues a per-customer sandbox subdomain on the
`api.revelsystems.com` hostname; the exact base URL is provisioned at
QA-credential issue time. Docs: <https://developer.revelsystems.com/revelsystems/docs>.

**Sign-up**: Self-serve OAuth signup at
<https://developer.revelsystems.com/>. The Revel developer portal
provisions a QA sandbox alongside the production credentials at the
same time. No partnership review required.

**Known limitations**:

- Sandbox webhook delivery is documented in the same portal; the
  `*.live.sandbox` slice will verify whether sandbox emits
  `order.finalized` for QA-seeded orders or only on real POS
  activity. Until verified, expect the field-mapping diff to surface
  any sandbox-only payload-shape quirks (Revel's developer portal
  notes that some fields are populated only when the underlying
  POS-side feature is enabled).
- Sandbox tokens use the same 24h TTL as production; the refresh
  cron treats them identically.

---

## Production environment

**Base URL**: `https://api.revelsystems.com`
**Partnership requirements**: none — public OAuth (`partnershipGated:
false`). Operators issue `client_id` + `client_secret` from their own
Revel admin portal. F&F never holds vendor production keys; each
operator's credentials are encrypted at rest in `vendor_credentials`.
**Rate-limit policy**: not published in the developer portal as of
the 2026-05-03 retrieval. The framework polls once every 5 minutes
per active connection, well under any plausible Revel ceiling. The
adapter retries on a 429 with exponential backoff bounded by the
framework's transport layer; the `*.live.prod` slice will measure the
observed ceiling and tighten the cadence if needed.

---

## Versioning

**Vendor's deprecation policy**: Revel's developer portal does not
publish a formal deprecation cadence; the adapter pins to the v1
shape captured at the 2026-05-03 retrieval and re-verifies on every
`*.live.*` slice run.
**Adapter pinned to**: `v1-2026-05-03` (matches the `api_version`
key inside `documentedPerRevelV1` in
`lib/integrations/pos/revel_pos_adapter.dart`).
**Vendor's last announced breaking change**: none observed at
retrieval.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. CI lint warns when
this file's retrieval date is older than 180 days without a
`*.live.sandbox` re-verification in that window.
