# Lightspeed K-Series Pressure Fixtures

Sources:
- Vendor docs: <https://api-docs.lsk.lightspeed.app/>
  - Get Sales: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
  - Get business day sales: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsalesofabusinessday>
  - Create Webhook (orders/payments): <https://api-docs.lsk.lightspeed.app/operation/operation-apecreatewebhookoo>
  - Authorization Overview: <https://api-portal.lsk.lightspeed.app/quick-start/authentication/authorization-overview>
  - Family-wide HMAC pattern: <https://apidoc.kounta.com/webhooks/>
- Per-vendor pack: `docs/integrations/lightspeed_lsk/`
- Adapter notes: `lib/integrations/pos/lightspeed_lsk_pos_adapter.dart`
- Existing test-fixtures (cross-reference): `test/integrations/pos/fixtures/lightspeed_lsk_orders_fixture.dart` and `test/integrations/pos/fixtures/lightspeed_lsk_webhook_fixture.dart`

Adapter: `lib/integrations/pos/lightspeed_lsk_pos_adapter.dart`
Webhook verifier: `lib/integrations/pos/lightspeed_lsk_webhook_signature_verifier.dart`
Production API client: `lib/integrations/pos/lightspeed_lsk_pos_production_api_client.dart`
Canonical fact name: `pos_sale` (mapping per `field_mapping.md`)
API version pinned: `f-v2-2026-05` (matches `kLightspeedLskApiVersion`)

This is a **Wave 1 launch vendor** (one of the 3 trio launch vendors with sandbox creds per the V1 operator punchlist). Phase 4 emulator E2E will exercise this corpus first.

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_sale_completed.json` | accept (1 row) | `_projectCanonicalRecord` returns non-null; `covers = 2`, `actual_sales = 11.00`, `vendor_entity_id = 'A65315.17'` | one row inserted; `business_date` projects per location tz |
| `happy_path_payment_record.json` | accept (1 row, modified bump) | `vendor_modified_at = max(timeOfOpening, timeClosed) = 2023-07-27T20:35:11.080Z`; tip ignored | one row inserted; replay of the same key conflict-do-nothing |
| `happy_path_void.json` | accept (1 row, zero sales) | `payments = []` → `actual_sales = 0.0`; `cancelled = true` flag preserved on payload but not on canonical | one row inserted with `actual_sales = 0` (Phase 5 to decide if `cancelled` should suppress) |
| `sparse_no_covers.json` | accept (1 row, covers=0) | `nbCovers` absent → `covers = 0`; `direct` source preserved | one row with `covers = 0`; metric-card honesty contract still flags `direct` source |
| `scenario_a_forged_signature.json` | reject | signature verifier raises `SignatureMismatch` BEFORE adapter is invoked | no DB write |
| `scenario_b_malformed_payload.json` | reject (parse drop) | `_projectCanonicalRecord` returns null because `accountFiscId` is missing; `handleWebhook` returns `recordsWritten = 0` | no DB write; one `connector_sync_log` row `event_kind = 'parse_drop'` |
| `scenario_c_future_dated_event.json` | reject (sanity drop) | framework sanity rule `opened_in_future` drops the row at `InboundWebhookHandler.dispatch` step 4 | no DB write; one `sanity_log` row |
| `scenario_d_oauth_near_expiry.json` | refresh path triggers | `LightspeedLskOAuthClient.refresh` POSTs `grant_type=refresh_token`; new envelope written atomically; old refresh token discarded | `vendor_credentials` row updated with new ciphertext IDs; `connector_sync_log` `event_kind = 'token_refresh'` |
| `scenario_e_ambiguous_timestamp.json` | reject (timezone resolution fails) | `vendor_timestamp_policy.lightspeed_lsk.asUtc` MUST refuse a naive `timeOfOpening` (no `Z`) — current adapter has the bug; this fixture is the detector | no DB write expected; finding filed if write occurs |
| `scenario_f_cross_vendor_id_collision.json` | accept (with namespacing) | adapter writes the LSK row at `(vendor_id='lightspeed_lsk', vendor_entity_id='A65315.17', ...)`; the matching Toast fixture's `(vendor_id='toast', ...)` row coexists distinct | both rows persist; idempotency UNIQUE namespacing prevents shadow write |
| `dst_spring_forward.json` | accept (3 rows) | all three sales project to `business_date = 2026-03-07` against `America/New_York` + 4 AM rollover | 3 rows inserted; `dst-skip` row does NOT throw (the missing 02:00–02:59 local hour is irrelevant — wire is UTC) |
| `cross_timezone_operator_toronto_vendor_pacific.json` | accept (2 rows) | `xtz-late` → `business_date = 2026-05-08`; `xtz-rollover` → `business_date = 2026-05-09` (operator-side `America/Toronto` + 4 AM rollover) | 2 rows; resolver uses operator tz NOT vendor tz |

## Notes

### Credential type for scenario D

OAuth (authorization-code grant). Refresh path is rotating: each refresh returns a new `refresh_token` and the old one is invalidated by the vendor. F&F always requests `offline_access` so the refresh TTL is 40 days (vs 30 minutes without). Cron at 5 minutes past every hour scans `vendor_credentials` for `token_expires_at < now + 24h` and refreshes. 3 consecutive refresh failures flip the connection to `error`. Token response shape: `{access_token, refresh_token, expires_in, refresh_expires_in, token_type, scope, not-before-policy, session_state}` — verbatim from the documented Authorization Overview page.

### Timezone resolver behavior

K-Series timestamps are documented as UTC ISO-8601 with `Z`. The framework's `vendor_timestamp_policy.lightspeed_lsk` is set to `asUtc` — naive timestamps (no `Z` and no offset) MUST be rejected, NOT silently coerced to local time. Scenario E exists specifically to detect a silent-coerce regression. `business_date` is computed in the OPERATOR's IANA timezone, not the vendor's observation timezone.

### Idempotency-key shape

Gateway UNIQUE on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`. The `vendor_id = 'lightspeed_lsk'` namespacing is the primary defense against scenario F cross-vendor id collisions. `vendor_entity_id` maps to `sales[].accountFiscId`; `vendor_modified_at` is `max(timeOfOpening, timeClosed)`.

### Webhook signature

`HMAC-SHA256` over the raw request body, lowercase hex encoding, header `X-Lightspeed-Signature` (lowercased per framework convention to `x-lightspeed-signature`). Optional `X-Lightspeed-Timestamp` Unix seconds; 24h replay tolerance. Documented in `docs/integrations/lightspeed_lsk/webhook_signature.md` — exact header name + payload concatenation will be confirmed by the `8.LSK.live.sandbox` slice.

### Field mapping (canonical fact)

| Canonical | Vendor path | Notes |
|---|---|---|
| `covers` | `sales[].nbCovers` | Direct (K-Series exposes natively); double → int round-half-to-even |
| `opened_at` | `sales[].timeOfOpening` | UTC instant |
| `closed_at` | `sales[].timeClosed` | UTC instant; falls back to `timeOfOpening` if absent |
| `actual_sales` | sum `sales[].payments[].netAmountWithTax` | Major units (dollars), not cents; rounded to 2 decimals |
| `vendor_entity_id` | `sales[].accountFiscId` | Stable; e.g. `A65315.17` |
| `vendor_modified_at` | `max(timeClosed, timeOfOpening)` | Monotone proxy; K-Series has no dedicated lastModifiedAt |

### Wave 1 launch context

Phase 4 emulator E2E click-path will exercise this fixture corpus first because `lightspeed_lsk` is one of the 3 trio launch vendors with sandbox creds. The Wave-1 sandbox credentials are out of scope for Phase 1 (this directory is verbatim public-doc only); Phase 2 harnesses run against these fixtures, and the live sandbox path is owned by the `8.LSK.live.sandbox` slice.
