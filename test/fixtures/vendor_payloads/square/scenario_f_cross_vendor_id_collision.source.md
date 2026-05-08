# Source

- URL: https://developer.squareup.com/reference/square/objects/Order
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- Webhook event: `order.updated`.

## Adversarial scenario

The same operator (`op_001`) has BOTH:

- A Square POS connection (this fixture).
- A Toast POS connection on a different location.

Square's `order.id` happens to equal the literal string
`GUEST_4815162342`, which ALSO appears as a Toast `guestGuid` value
on an unrelated Toast order for the same operator.

Without proper namespacing, the canonical fact's idempotency key
`(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
could collide IF the implementation were buggy and dropped
`vendor_id` from the key. This fixture proves the namespace
is enforced.

## Adapter assertions

1. `_orderToCanonicalFact(...)` produces a `SquareCanonicalFact`
   with `vendorEntityId = 'GUEST_4815162342'`, `operatorId =
   'op_001'`.
2. `factWriter.upsertSalesFact(fact)` calls the repository whose
   UNIQUE index is exactly:
   `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`.
3. The Toast adapter's parallel write for the colliding string
   targets the SAME table but with `vendor_id = 'toast'` —
   distinct row, no collision, both rows persist.
4. The Phase 2 harness asserts both Square and Toast canonical
   facts coexist, joined to the operator's facts table without
   either masking the other.

## Repository contract reference

`OperatorScopedRepository<T>` is the primary defense (per
`docs/contracts/hardening_rls_and_repository_pattern_contract.md`),
RLS is the backup. The `vendor_id` column on every operator-scoped
fact table is non-NULL and participates in:

- The fact-row UNIQUE constraint.
- Every fact-table B-tree index leading column
  `(operator_id, location_id)` — `vendor_id` follows in the
  composite key on idempotency-relevant indexes.

## Field-level edits

- `order.id` set to `GUEST_4815162342` to deliberately mimic a
  Toast `guestGuid` shape (Toast uses string GUIDs for guests).
- `customer_id` mirrors `id` for additional collision surface.
- All other field paths verbatim per Square's published Order
  object reference.
