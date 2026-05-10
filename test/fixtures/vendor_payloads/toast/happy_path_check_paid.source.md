# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08 (mirroring 2026-05-03 retrieval cited in
  `documentedPerToastV2`)
- API version: `orders/v2`
- Endpoint / event: `GET /orders/v2/ordersBulk` (Order with embedded
  `checks[]`, `selections[]`, `payments[]`)

## Notes

- Demonstrates the documented Order > Check > Selection / Payment
  nested shape. The adapter currently only reads top-level Order
  fields (per `documentedPerToastV2`) and does not consume Check or
  Selection level fields, but the fixture preserves them so Phase 2
  harnesses can probe whether the framework's idempotency + sanity
  layers correctly leave nested structures untouched.
- `payments[].cardholderName` and `payments[].cardLast4` are
  intentionally omitted per `field_mapping.md#forbidden-fields`.
- `selections[].displayName` retained (used in Phase 2 ledger
  reconciliation tests; Toast docs expose it on `MenuItemSelection`).
- `tipAmount` retained on `payments[]` for the same Phase 2 ledger
  audit (the adapter does not currently project it; the fixture
  shows the documented shape so future field expansions don't
  invalidate the corpus).
- `<<HMAC_SHA256_BASE64_OF_BODY_USING_TEST_HMAC_SECRET>>` is a
  placeholder; tests recompute via `signToastWebhookBody` from
  `test/integrations/pos/fixtures/toast_webhook_fixture.dart`.

## Sourcing fallback

Same as `happy_path_order_closed.source.md`. Toast `doc.toasttab.com`
returned 403/404 on direct WebFetch; fixture reconstructed from
in-repo curated mirror sources cited above.

## Expected adapter behavior

- Signature verifies, sanity hook passes.
- `_canonicalize` reads only top-level Order fields; nested checks
  ignored at the canonical-fact layer (per
  `documentedPerToastV2`'s pinned paths).
- `actual_sales = 56.00`, `covers = 2`, all timestamps `Z`-suffixed.
- One row written via `upsertOrderFact`.
