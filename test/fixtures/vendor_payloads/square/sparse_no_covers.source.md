# Source

- URL: https://developer.squareup.com/reference/square/objects/Order
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- Webhook event: `order.updated` (state = `COMPLETED`).

## Adapter mapping

This fixture exercises the **covers fallback** path — Square's Order
schema does NOT define a guest-count field anywhere, so EVERY Square
canonical fact records `covers = null` and
`covers_source = 'forecast_fallback'`. This isn't a missing-field
edge — it's the documented Square baseline (see
`docs/integrations/square/field_mapping.md` covers row + adapter
constant `documented_per_square_2024_01_18` row 6).

Adapter assertions for Phase 2 harness:

- `_orderToCanonicalFact` returns a `SquareCanonicalFact` with:
  - `covers = null`
  - `coversSource = 'forecast_fallback'`
- The dashboard chrome surfaces "Covers: forecast — Square does not
  expose guest count" pill (top-left, per
  `docs/contracts/metric_card_honesty_contract.md`).
- `wage_source` (computed downstream by the labor lane) defaults to
  `app_fallback` when no labor adapter is paired with this Square
  connection.

## Sparse-shape detail

Compared to `happy_path_order_completed.json`, this payload omits
optional fields that Square may or may not emit:

- No `reference_id`, no `source`, no `customer_id`.
- No `tenders` array (cash sale; some orders close without a tender
  record on the Order resource itself — payment lives on the
  `Payment` event family).
- No per-line-item `gross_sales_money` / `total_tax_money` /
  `total_discount_money` breakdown — only `total_money` per line.

The mandatory adapter inputs are still present: `id`, `created_at`,
`updated_at`, `closed_at`, `total_money.amount`, `location_id`.

## Field-level edits

- Currency: `CAD`.
- Identifiers are public-example placeholders.

All field paths verbatim per Square's published Order object
reference.
