# Source

- URL: https://developer.squareup.com/reference/square/objects/Order
- URL (webhook envelope): https://developer.squareup.com/docs/webhooks/build-with-webhooks
- Retrieved: 2026-05-08
- API version: `2024-01-18` (matches `kSquareApiVersion` in
  `lib/integrations/pos/square_pos_adapter.dart`)
- Webhook event: `order.updated` with `closed_at` set
  (state transition to `COMPLETED`).

## Adapter mapping

The adapter's `_orderToCanonicalFact` reads from
`payload.data.object.order` and produces one `SquareCanonicalFact`
with:

- `vendor_entity_id` = `order.id` = `CAISENgvlHdNqA`
- `opened_at` = `order.created_at` = `2026-05-08T17:30:00Z`
- `closed_at` = `order.closed_at` = `2026-05-08T18:45:00Z`
- `vendor_modified_at` = `order.updated_at` = `2026-05-08T18:45:00Z`
- `actual_sales` = `order.total_money.amount / 100.0` = `35.03 CAD`
- `covers` = `null`, `covers_source` = `forecast_fallback` (Square
  Order schema has no guest-count field).

## Field-level edits

- Currency: switched to `CAD` (Square doc example uses `USD`).
  F&F's primary deployment is Canadian operators; Square supports
  multi-currency. No field shape change.
- `merchant_id` / `location_id` / `customer_id` use placeholder
  values matching the format Square's docs use
  (`M_TEST_MERCHANT_001`, `L_RESTAURANT_A`). No PII.
- Line item names ("Cheeseburger", "Fountain Drink") are public
  example product names — no operator-specific strings.

All other field paths and casing are verbatim per Square's
published Order object reference.
