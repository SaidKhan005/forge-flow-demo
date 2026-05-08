# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08
- API version: `orders/v2`

## Notes

- The Toast Order schema declares `guid` as required + non-nullable
  (it is the entity's identity field, mapped to canonical
  `vendor_entity_id` in `documentedPerToastV2`).
- This fixture intentionally omits `guid`. Per the binding
  framework rule, the adapter's `_canonicalize` reads
  `order['guid']` and the framework's idempotency seam requires a
  non-null vendor entity id; absence MUST be rejected at parse
  time.
- All other fields documented and well-formed — the omission is
  surgical so the assertion is unambiguous.

## Sourcing fallback

Reconstructed from `documentedPerToastV2.vendor_entity_id_path`
(`'guid'`) and the schema reference in `field_mapping.md`.

## Expected adapter behavior

- Signature verifies (body would compute correctly).
- Sanity hook receives `vendor_entity_id: null` → MUST reject as
  malformed.
- `_canonicalize` raises (or returns a fact whose
  `vendor_entity_id` is null, which the sink's `(vendor_id,
  operator_id, vendor_entity_id, vendor_modified_at)` UNIQUE
  rejects).
- No row written via `upsertOrderFact`.
- Audit log records parse failure.
