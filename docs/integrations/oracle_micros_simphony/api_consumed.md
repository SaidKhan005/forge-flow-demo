# Oracle MICROS Simphony — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `oracle_micros_simphony`
**Category**: `pos`
**Source documentation**: <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/>
(Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
**Retrieval date**: 2026-05-05
**API version pinned**: `v2` (Gen2 — STSGen2)

---

## Auth method

`oauth` — OAuth 2.0, `client_credentials` grant. Bearer access token
returned from the token endpoint; access token TTL is short-lived
(approx. 1 hour) and refreshed proactively. Per-location grant scope:
each `locRef` (Simphony location reference) requires its own credential
pair issued through the Simphony Partner Integration Program. See
`oauth_shape.md`.

Cite vendor doc:
<https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/authenticate.html>

> **Partner activation gate.** Sandbox and production credentials are
> issued only after the partner application clears the Simphony
> Partner Integration Program. Engineering can complete the
> documented adapter without credentials; live verification (sandbox /
> prod) requires partnership progress per `partnership_status.md`.
> Estimated lead time at slice ship: **8-16 weeks**.

---

## Endpoints consumed

All paths below resolve under the Gen2 (STSGen2) base —
`/sim/api/v2/...`. Response shape is the documented Gen2 envelope:
`items[]` array of guest-check objects, each carrying a `header`
sub-object with `chkNum`, `guestCount`, `opnUTC`, `cmplOrClsdUTC`,
`lastUpdatedUTC`, `subTtlCents` (see `field_mapping.md`). The Gen1
`guestChecks[]` envelope and `numOfGst` field are not consumed.

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| POST | `/sim/api/v2/oauth/token` | Token issuance (`client_credentials` grant). Doc: <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/authenticate.html> | partner-issued; vendor does not document a public number | n/a |
| POST | `/sim/api/v2/posData/getGuestChecks` | Backfill + poll-incremental — paged listing of `items[]` guest checks since `lastModified`. Doc: <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html> | ~60 req/min/org (vendor-soft; partner activation may raise) | server-issued cursor token; empty cursor = end of listing |
| GET | `/sim/api/v2/posData/getCheckById/{chkNum}` | Optional reconciliation lookup for a single check. Doc: <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getcheckbyid.html> | shared with above | n/a |
| GET | `/sim/api/v2/orgData/locations` | List the organization's locations so the connect flow can map an OAuth grant's `locRef` claim to one F&F `location_id`. Doc: <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getlocations.html> | low cadence | n/a |

Every endpoint listed here is invoked by the adapter at
`lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart`; every
endpoint invoked by the adapter is listed here. Codex verifies the
diff.

> **Webhook delivery.** Oracle MICROS Simphony's documented public API
> exposes **no** webhook delivery surface. The adapter is therefore
> poll-only: `webhookSupport = pollOnly` on the capability profile and
> `handleWebhook` throws `UnsupportedError` per
> `docs/contracts/vendor_adapter_slice_contract.md`. See
> `webhook_signature.md` (single-line N/A).

---

## Sandbox / test environment

**Base URL**: `https://<partner-issued sandbox host>.simphony.oracleindustry.com/sim/api/v2/`
(exact host issued at partner activation; not knowable until
sandbox credentials land)
**Sign-up**: via Simphony Partner Integration Program — see
`partnership_status.md`. Self-serve sandbox is not available.
**Known limitations**:
- Sandbox returns synthetic guest checks only; real timestamps are
  not guaranteed. Live verification of timestamp shape happens against
  production (`8.OR.live.prod`).
- Sandbox does not exercise webhook delivery (vendor does not document
  webhooks).

---

## Production environment

**Base URL**: `https://<partner-issued prod host>.simphony.oracleindustry.com/sim/api/v2/`
**Partnership requirements**: Simphony Partner Integration Program;
partner activation required. F&F is `not_started` at slice ship per
`partnership_status.md`.
**Rate-limit policy**: <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/>
(consult partner portal at activation; vendor does not publish a
single rate-limit document.)
**Quota**: ~60 req/min/org documented soft cap; partner activation
may raise per use case.

---

## Versioning

**Vendor's deprecation policy**: <https://docs.oracle.com/en/industries/food-beverage/simphony/>
(consult release notes section)
**Adapter pinned to**: `v2` (STSGen2 Cloud API)
**Vendor's last announced breaking change**: not announced as of
2026-05-05 retrieval.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. The
`api_consumed.md` retrieval date drives the CI lint warning.
