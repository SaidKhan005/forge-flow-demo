# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed`
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`
- Notes: cross-vendor id collision scenario for binding F. ADP's
  documented `associate_oid` is normally a 16-character base32-style
  identifier (e.g. `G3WXX1Y2Z3A4B5C6` per the developer-portal sample
  shape in `test/integrations/labor/fixtures/adp_punches_fixture.dart`),
  but ADP does not constrain the field to that shape — a numeric-only
  `associate_oid` (e.g. `12345`) is permitted at the API surface and
  collides at the literal-value level with another labor vendor's
  identifier (7shifts `user_id`, Push Operations `employee_id`,
  Humanity `staff_id` — all numeric strings). The defense is in
  Forge & Flow's idempotency key shape: the canonical fact UNIQUE
  is `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  per `docs/contracts/vendor_adapter_slice_contract.md`, and the
  inbound webhook idempotency UNIQUE is
  `inbound_webhook_idempotency(vendor_id, operator_id,
  vendor_event_id)` (per `docs/integrations/adp/webhook_signature.md`).
  Both keys lead with `vendor_id`, so the ADP write and the 7shifts
  write live in disjoint slots even at literal collision. The Phase 2
  harness MUST assert two canonical fact rows (one per vendor) with
  no merge — cross-vendor employee identity is an explicit non-goal
  at V1 per `docs/integrations/adp/field_mapping.md`. Partner-only
  sourcing.
