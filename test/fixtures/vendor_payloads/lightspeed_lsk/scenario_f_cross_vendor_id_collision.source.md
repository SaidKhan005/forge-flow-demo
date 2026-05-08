# Source

- URL: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`); adapter constant
  `kLightspeedLskApiVersion = 'f-v2-2026-05'`.
- Endpoint: inbound webhook delivery (`POST <fnf-webhook-url>`),
  event `order.DELIVERED`.
- Notes:
  - The vendor entity id `A65315.17` is the same string used in the
    documented Lightspeed K-Series Get Sales 200 example (and in
    `happy_path_sale_completed.json`). The Phase 2 harness pairs
    this fixture with a Toast `guid = "A65315.17"` fixture and
    asserts both rows coexist in the canonical fact table.
  - Idempotency UNIQUE: per
    `lib/integrations/pos/lightspeed_lsk_pos_adapter.dart` doc
    block, the gateway enforces UNIQUE on
    `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`.
    Because `vendor_id = 'lightspeed_lsk'` here and
    `vendor_id = 'toast'` for the matching Toast fixture, the
    composite key is distinct.
  - "Reject" outcome (per the binding scenario table) is enforced
    via the namespacing — the LSK fact and the Toast fact each
    write successfully, but neither shadows the other. A non-
    namespaced gateway would shadow-write; that is the bug this
    fixture detects.
- Expected harness assertion: ingest the LSK row first, then a
  Toast row with `guid = "A65315.17"`. Both rows persist; neither
  is suppressed; the Toast row's
  `(vendor_id='toast', vendor_entity_id='A65315.17')` is distinct
  from the LSK row's
  `(vendor_id='lightspeed_lsk', vendor_entity_id='A65315.17')`.
