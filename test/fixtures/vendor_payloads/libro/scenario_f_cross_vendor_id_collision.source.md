# Source

- URL: https://libroreserve.github.io/api-documentation/#operation/listReservations
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.confirmed`)
- Notes: Adversarial scenario F. The Libro `reservation.id` is set to
  the same string-shaped value (`OT-CONF-9876`) that OpenTable's
  adversarial fixture uses for `confirmation_number`. Both vendors
  emit the same opaque ID for two different operator-bound
  reservations.

  The pressure-test guarantee: the canonical `reservation_facts`
  partial UNIQUE on `(operator_id, vendor_id, vendor_entity_id,
  vendor_modified_at)` (per the framework migration) MUST namespace by
  `vendor_id`. The Libro adapter writes `vendor_id = 'libro'` (per
  `kLibroVendorId` constant); the OpenTable adapter writes
  `vendor_id = 'opentable'`. Two distinct rows result. Same applies to
  the proxy's `idempotency_keys` table, which keys by
  `(vendor_id, operator_id, vendor_event_id)`.

  The harness MUST verify: two rows in `reservation_facts` after both
  payloads land, no row count of 1 (which would prove a cross-vendor
  shadow write). This guards against an adapter-side bug where the
  vendor_entity_id is allowed to be the canonical key without
  namespacing.
