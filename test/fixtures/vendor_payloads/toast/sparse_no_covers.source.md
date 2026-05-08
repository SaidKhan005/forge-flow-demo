# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08
- API version: `orders/v2`
- Endpoint / event: Order envelope with `numberOfGuests = null`
  (online-ordering / takeout source where Toast does not capture a
  guest count).

## Notes

- Toast's online ordering channel does not always populate
  `numberOfGuests`; the field is documented as nullable on the Order
  schema. `source: "Online Ordering"` reflects the documented Order
  source enumeration.
- This fixture probes whether the adapter / sink tolerates
  `covers = null` (canonical fact stored with null, no fabrication).
- `server: null` is also documented for online channels.

## Sourcing fallback

Same as `happy_path_order_closed.source.md`. Reconstructed from the
in-repo curated mirror of `doc.toasttab.com/openapi/orders/orders-bulk-v2`.

## Expected adapter behavior

- Signature verifies, sanity hook passes.
- `_canonicalize` produces:
  `{vendor_entity_id: "7f3e8c91-9b5a-4d2c-8e7f-1a4b3c5d6e7f",
    actual_sales: 24.50, covers: null, covers_source: "direct",
    opened_at: "2026-05-04T20:35:00.000Z",
    closed_at: "2026-05-04T20:50:00.000Z"}`.
- Row written; sink stores `covers = NULL` (no fabricated zero).
- `covers_source` remains `direct` even when `covers` is null —
  direct field exposure does not flip to `forecast_fallback` just
  because the value is missing for this transaction.
