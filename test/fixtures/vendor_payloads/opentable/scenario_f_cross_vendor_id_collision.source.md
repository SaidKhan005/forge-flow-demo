# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope)
- Notes: Adversarial scenario F exercises the cross-vendor namespace
  defense. The OpenTable adapter contract says `vendor_entity_id` is
  the OpenTable-issued reservation id (`reservation.id`, an opaque
  string per `field_mapping.md` "Ambiguity calls" → "assumed string
  per industry standard"). The fixture intentionally chooses a value
  that matches the Libro fixture's id pattern (`lbr-evt-7c2f-001`,
  declared in
  `test/integrations/reservation/fixtures/libro_reservations_fixture.dart`)
  to verify the sink's UPSERT key includes `vendor_id` per the
  vendor-adapter slice contract. The sink's idempotency key is the
  4-tuple `(vendor_id, operator_id, vendor_entity_id,
  vendor_modified_at)`; without `vendor_id` segregation, a malicious
  or accidental id-collision could shadow-update or shadow-read a
  competing vendor's row for the same operator.
- Adapter assertion (Phase 2): `_canonicalize` accepts the row
  (the id-shape match doesn't break parsing; OpenTable adapter
  treats the id as opaque). The sink upsert lands a NEW row keyed
  on `vendor_id = opentable`, even when a Libro row with the same
  `vendor_entity_id` value already exists under `vendor_id = libro`
  for the same operator. Sink assertion: two rows in
  `reservation_facts` after both writes — one with `vendor_id =
  libro`, one with `vendor_id = opentable`, both holding
  `vendor_entity_id = lbr-evt-7c2f-001`. The framework's inbound
  `inbound_webhook_idempotency` UNIQUE on `(vendor_id, operator_id,
  vendor_event_id)` similarly allows the OpenTable event to dedupe
  only against other OpenTable events.
