# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08 (mirroring the 2026-05-03 retrieval that fed
  `documentedPerToastV2` in `lib/integrations/pos/toast_pos_adapter.dart`
  and the existing `test/integrations/pos/fixtures/toast_orders_fixture.dart`)
- API version: `orders/v2` (Toast Standard / Partner tier)
- Endpoint / event: `GET /orders/v2/ordersBulk` Order shape, also emitted
  inline as the `orders.modified` webhook body per
  <https://doc.toasttab.com/doc/devguide/apiWebhooksOverview.html>

## Notes

- Field set is the union of (a) the canonical fields the adapter reads
  per `documentedPerToastV2` (`guid`, `modifiedDate`, `openedDate`,
  `closedDate`, `numberOfGuests`, `totalAmount`) and (b) the additional
  Order envelope fields documented in `docs/integrations/toast/`
  (entityType, restaurant, server, revenueCenter, diningOption, table,
  paymentStatus, businessDate, totalTaxAmount, totalDiscountAmount,
  totalAmountWithoutTaxAndDiscounts, voided, deleted, source, duration).
- `_event_envelope` is the test-side wrapper holding the headers Toast
  delivers alongside the body. The HMAC value is a placeholder
  (`<<HMAC_SHA256_BASE64_OF_BODY_USING_TEST_HMAC_SECRET>>`) — production
  tests sign the raw body with `<<TEST_HMAC_SECRET>>` to obtain a real
  signature; see `webhook_signature.md` for the algorithm.
- `numberOfGuests` is intentionally non-null and integer — covers
  source = `direct` per `docs/integrations/toast/field_mapping.md`.
- All timestamps end in `Z` (UTC) per Toast's documented timestamp
  policy.
- `Toast-Webhook-Timestamp` header is Unix epoch seconds; `1778011500`
  ≈ `2026-05-04T19:55:00Z` (matches `modifiedDate`).
- Forbidden fields (`customer.*`, `payments.cardholderName`,
  `payments.cardLast4`) intentionally omitted per
  `field_mapping.md#forbidden-fields`.

## Sourcing fallback

Toast public docs (`doc.toasttab.com`) returned 403/404 for direct
WebFetch calls during 2026-05-08 retrieval (Toast partner-tier intake
gates the openapi pages and the support center). The fixture is
therefore reconstructed from the in-repo curated sources:

1. `lib/integrations/pos/toast_pos_adapter.dart` — `documentedPerToastV2`
2. `test/integrations/pos/fixtures/toast_orders_fixture.dart`
3. `docs/integrations/toast/field_mapping.md`
4. `docs/integrations/toast/webhook_signature.md`

These mirror the 2026-05-03 retrieval cited in those files. See the
per-vendor README "Vendor-doc gap notes" section for Phase 5
escalation.

## Expected adapter behavior

- Webhook signature verifies (`Toast-Signature` matches HMAC-SHA256 of
  raw body using `<<TEST_HMAC_SECRET>>`).
- Sanity hook passes (timestamps in past + within 90-day floor).
- `_canonicalize` produces canonical fact:
  `{vendor_entity_id: "d1f9cd4a-4f4b-4d6e-9b7d-9a4f1f7c8e21",
    vendor_modified_at: "2026-05-04T19:55:00.000Z",
    opened_at: "2026-05-04T18:30:00.000Z",
    closed_at: "2026-05-04T19:55:00.000Z",
    covers: 4, covers_source: "direct",
    actual_sales: 87.20}`.
- `ToastFactSink.upsertOrderFact` writes one row.
