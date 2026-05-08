# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08
- API version: `orders/v2`
- Endpoint / event: Order with `voided: true` and populated
  `voidDate` / `voidBusinessDate` per the Order schema in
  `doc.toasttab.com`'s ordersBulk reference.

## Notes

- Toast represents void as a state on the Order envelope rather than
  a separate event type. Operators void via the POS UI; the resulting
  `orders.modified` carries `voided: true`, `totalAmount: 0.00`,
  `paymentStatus: "OPEN"`.
- The adapter's `_canonicalize` path produces a canonical fact with
  `actual_sales: 0.00` and `covers: 3`. The framework's downstream
  tools (Phase 2 sink + spine) decide whether to surface voided
  orders; the adapter itself is intentionally agnostic.
- `closedDate` matches `voidDate` here (the void closes the order at
  the same instant). Documented behavior per Toast Order schema.

## Sourcing fallback

`doc.toasttab.com` returned 403 on direct WebFetch on 2026-05-08.
Fixture reconstructed from:

- `lib/integrations/pos/toast_pos_adapter.dart`
- `test/integrations/pos/fixtures/toast_orders_fixture.dart` (the
  base order shape; void variant is a documented state of the same
  envelope)
- `docs/integrations/toast/field_mapping.md`

## Expected adapter behavior

- Signature verifies, sanity hook passes.
- `_canonicalize` produces:
  `{vendor_entity_id: "c4e8b1a2-4d57-4f91-8e32-7b6a9d4c5e1f",
    actual_sales: 0.00, covers: 3, ...}`.
- Row written via `upsertOrderFact`.
- Phase 2 sink-level assertion (out of scope for the adapter
  fixture): `voided` flag round-trips into the raw payload column
  for downstream consumers.
