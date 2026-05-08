# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope) /
  `GET /v1/reservations/{reservation_id}` response shape (assumed)
- Notes: OpenTable Partner API documentation is gated by the
  partnership program (see
  `docs/integrations/opentable/partnership_status.md`). The payload
  shape follows the F&F engineering target captured verbatim in
  `lib/integrations/reservation/opentable_reservation_adapter.dart`
  `documentedPerOpentableV1FieldMapping` (`api_version:
  partner-v1-2026-05-04-assumed`) and mirrored in
  `test/integrations/reservation/fixtures/opentable_reservations_fixture.dart`
  `openTableSampleReservation` (id `OT-12345`, party_size 4, status
  `booked`, reserved_at ISO-8601 UTC with explicit `Z`). Every field
  here lands on a row marked `verify_in_live_sandbox: true` in the
  field-mapping doc — the `8R.OT.live.sandbox` slice will diff this
  shape against the first observed sandbox payload.
- Adapter assertion (Phase 2): `_canonicalize` accepts; canonical
  fact written with `vendor_entity_id = OT-RES-2026050801`,
  `reservation_at = 2026-05-12T19:30:00Z`, `party_size = 4`,
  `status = booked`. Forbidden guest fields absent — adapter does
  not need to drop them on this payload.
