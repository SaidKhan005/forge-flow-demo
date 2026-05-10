# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Endpoint: `GET /reservations/search` page item (or webhook delivery)
- Reference: `lib/integrations/reservation/libro_reservation_adapter.dart`
  (other reservation vendor consuming string ids via the same
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  idempotency key)
- Notes: This Tock reservation carries `id: "RES-2026-05-09-12345"` —
  a non-`res_`-prefixed string deliberately chosen to **collide
  literally** with a Libro reservation that may carry the same
  `id`. Libro's id format is documented as a free-form string per
  `lib/integrations/reservation/libro_reservation_adapter.dart`
  (`vendorEntityId` field), so a literal collision IS plausible across
  vendors. Tock's documented id format prefixes with `res_…` per the
  field-mapping doc, but the public reference does not enforce a
  format constraint at the wire level. The Phase 2 harness MUST
  pre-seed a Libro reservation fact with the same `vendor_entity_id`
  AND same `(operator_id, location_id)`, then drive the Tock adapter
  with this fixture and assert: a NEW canonical fact row is written
  with `vendor_id = 'tock'` (not 'libro'); the existing Libro row is
  NOT shadow-written; the idempotency UNIQUE namespace prevents the
  shadow.

## Sourcing context

Public reservation reference + Libro adapter for the cross-vendor
id collision lane. No live HTTP calls.
