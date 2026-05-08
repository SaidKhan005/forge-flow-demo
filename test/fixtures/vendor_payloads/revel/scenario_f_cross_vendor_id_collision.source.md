# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: webhook subscription `order.finalized` — adversarial Scenario F (cross-vendor ID collision).
- Notes:
  - Per `docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` Phase 8 V1 lean cut 2:
    > "Idempotency keyed on `(vendor_id, operator_id, vendor_event_id)` stored in `inbound_webhook_idempotency` with 30-day TTL via `pg_partman`."
    > "Canonical fact writes upsert on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`."
  - Both keys are namespaced by `vendor_id`, so a Revel order with numeric id `8842301` and a Square order with the same numeric `8842301` for the same operator do NOT collide in the database. The fixture documents this guarantee against the case where two adapters happen to assign overlapping integer id spaces.
  - Phase 2 adapter harness assertion: write succeeds in the Revel namespace; verify by inspecting `inbound_webhook_idempotency` row count for `(vendor_id='revel', operator_id, vendor_event_id='8842301')` = 1 AND for `(vendor_id='square', operator_id, vendor_event_id='8842301')` = 1 (independent rows). Verify canonical fact rows under the two vendor namespaces are independent — neither overwrites the other.
  - Specifically test the negative path: any attempt to upsert this Revel row INTO the Square namespace (or vice versa) must be a DB-level violation, not silently absorbed.
