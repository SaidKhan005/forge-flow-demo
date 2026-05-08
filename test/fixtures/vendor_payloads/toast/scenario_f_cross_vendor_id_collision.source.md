# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08
- API version: `orders/v2`

## Notes

- Toast's documented `Order.guid` format is UUID v4. Square's
  documented `Payment.id` is an opaque alphanumeric string
  (e.g. `VK0123ABCDEF` shape). The two namespaces never overlap
  in production, but the framework's idempotency key
  (`vendor_id`, `operator_id`, `vendor_entity_id`,
  `vendor_modified_at`) MUST namespace by `vendor_id` so that
  even a hypothetical collision (or a hostile attacker forging
  a payload) cannot shadow-write a row stamped with the wrong
  `vendor_id`.
- This fixture sets the Toast Order's `guid` to a Square-shaped
  identifier (`VK0123ABCDEF`) to exercise that namespacing.
  Toast's schema permits arbitrary string values for `guid`;
  the framework's idempotency seam — not the wire format — is
  the defense.
- `_test_collision_partner` documents the partner-side row that
  the test pre-populates as a Square payment fact with the same
  identifier. The Toast event MUST land in its own row (vendor_id
  = 'toast'), NOT update or shadow-write the existing Square row.
- Existing adapter test
  `test/integrations/pos/toast_pos_adapter_test.dart` already
  exercises related namespacing; this fixture promotes the
  adversarial form to the pressure corpus.

## Sourcing fallback

Reconstructed from `documentedPerToastV2` (vendor_entity_id_path
= 'guid'), `lib/services/integration/integration_adapter_common.dart`
(idempotency-key shape), and Square's public docs at
<https://developer.squareup.com/reference/square/payments-api/list-payments>
(retrieved 2026-05-08, used only to confirm Square's id format).

## Expected adapter behavior

- Signature verifies; sanity hook passes.
- `_canonicalize` produces canonical fact with
  `vendor_entity_id: "VK0123ABCDEF"`.
- `upsertOrderFact` writes a Toast row keyed
  `(vendor_id='toast', operator_id, location_id,
    vendor_entity_id='VK0123ABCDEF',
    vendor_modified_at=...)`.
- The pre-existing Square row keyed
  `(vendor_id='square', ..., vendor_entity_id='VK0123ABCDEF', ...)`
  is **untouched**.
- Both rows coexist; downstream queries filter by `vendor_id`.
- Audit log records the write (no flag — the namespacing means
  this is normal behavior, not an attack).

## What this scenario asserts

- Idempotency key namespace prevents shadow-write.
- `vendor_entity_id` alone is NOT a primary key; the tuple
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  is.
- Cross-vendor identifier overlap is benign as long as the
  namespace is enforced at the storage layer.
