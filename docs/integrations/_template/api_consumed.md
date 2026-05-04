# `<vendor_display_name>` — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `<vendor_id>`
**Category**: `pos` | `labor` | `reservation`
**Source documentation**: `<https://...>`
**Retrieval date**: YYYY-MM-DD
**API version pinned**: `<vendor's version string>`

---

## Auth method

`oauth` | `api_key` | `legacy_username_password` | `bearer_token` | `mutual_tls`

Cite vendor doc section: `<URL#section>`

If OAuth, see `oauth_shape.md` for the flow detail.

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| GET | `/v1/orders` | Backfill + poll | 100/min | cursor (`next_url`) |
| GET | `/v1/orders/{id}` | Webhook lookup | shared with above | n/a |
| POST | `/v1/webhooks/subscriptions` | Auto-register | 10/min | n/a |
| ... | ... | ... | ... | ... |

Every endpoint listed here MUST be invoked by the adapter code; every
endpoint invoked by the adapter code MUST be listed here. Codex
verifies the diff.

---

## Sandbox / test environment

**Base URL**: `<https://...>`
**Sign-up**: `<URL or "via partnership; see partnership_status.md">`
**Known limitations**:
- e.g., "Sandbox does not emit webhooks for voided checks; verified
  in `*.live.sandbox` only."
- e.g., "Sandbox returns synthetic data only; no real timestamps."

If no sandbox exists, document the workaround:
- e.g., "Sandbox requires Standard Tier sign-up — `partnership_status.md`."

---

## Production environment

**Base URL**: `<https://...>`
**Partnership requirements**: `<none / partnership review / sales-rep onboarding>`
**Rate-limit policy**: `<URL>`
**Quota**: `<requests/min, daily caps if any>`

---

## Versioning

**Vendor's deprecation policy**: `<URL>`
**Adapter pinned to**: `<API version>`
**Vendor's last announced breaking change**: `<date + URL>`
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner.
