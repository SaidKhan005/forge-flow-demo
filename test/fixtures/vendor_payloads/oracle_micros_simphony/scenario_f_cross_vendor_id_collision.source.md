# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- URL (idempotency contract): docs/contracts/vendor_adapter_slice_contract.md
- URL (toast field mapping for collision context): docs/integrations/toast/field_mapping.md
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape — same
  shape as `happy_path_check_closed.json` but with a `chkNum` colliding
  with a Toast `orderGuid`/`displayNumber` integer)
- Notes: The Simphony `chkNum` is scoped to (`locRef`) — see
  `field_mapping.md` "Ambiguity calls" → "chkNum uniqueness across locations".
  The integer 412901 also happens to be a valid Toast `displayNumber`. The
  collision is real-world: an operator with both Simphony and Toast on
  different locations could see the same numeric id from both vendors.
- Adapter assertion at this fixture:
  - Canonical UNIQUE is `(vendor_id, operator_id, vendor_entity_id,
    vendor_modified_at)`. The `vendor_id` column namespaces by vendor
    — `oracle_micros_simphony` vs `toast` are distinct keys. The
    cross-vendor collision CANNOT shadow-write.
  - The framework's `inbound_webhook_idempotency` table also keys on
    `(vendor_id, operator_id, vendor_event_id)` per `8.0` lean cut.
  - The Phase 2 sink harness asserts: insert this fixture under
    `vendor_id = oracle_micros_simphony`, then insert the Toast
    fixture with `vendor_entity_id = 412901` under `vendor_id = toast`.
    Both writes succeed; canonical table has TWO rows.
  - If the harness instead writes both under the same `vendor_id`,
    the second is rejected by UNIQUE.
- Cite vendor docs (both):
  - Simphony: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
  - Toast: https://doc.toasttab.com/openapi/orders/operation/ordersGet/
