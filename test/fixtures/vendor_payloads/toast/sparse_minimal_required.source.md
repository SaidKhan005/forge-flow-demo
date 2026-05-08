# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08
- API version: `orders/v2`
- Endpoint / event: minimal Order envelope containing only the
  fields the adapter consumes per `documentedPerToastV2`
  (`guid`, `openedDate`, `closedDate`, `modifiedDate`,
  `numberOfGuests`, `totalAmount`) plus the documented required
  envelope wrappers (`entityType`, `restaurant`).

## Notes

- Optional Order fields (server, revenueCenter, table, diningOption,
  source, businessDate, totalTaxAmount, etc.) are omitted to verify
  the adapter does not crash when Toast's response is shape-minimal
  (e.g. permissions downgrade or partner-tier scope variation).
- Bookend test for the happy-path corpus: confirms the
  `_canonicalize` path needs only the 6 documented input paths.
- `voided: false` retained because it is a non-nullable boolean per
  the Toast Order schema documentation.

## Sourcing fallback

Same as `happy_path_order_closed.source.md` — reconstructed from
in-repo curated mirror of `doc.toasttab.com`.

## Expected adapter behavior

- Signature verifies, sanity hook passes.
- `_canonicalize` produces canonical fact with all required
  fields populated.
- Row written; sink does not error on missing optional fields
  (raw_payload column stores the minimal shape verbatim).
