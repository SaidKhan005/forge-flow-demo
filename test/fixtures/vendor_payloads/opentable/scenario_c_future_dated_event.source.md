# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope)
- Notes: Adversarial scenario C tests the framework's vendor
  timestamp sanity guard (rule `opened_in_future`). The fixture's
  `reserved_at = 2026-07-15T12:00:00Z` reads ~60 days ahead of the
  anchor `now = 2026-05-08T12:00:00Z`, mirroring the structure of
  `openTableFutureDatedReservation` in
  `test/integrations/reservation/fixtures/opentable_reservations_fixture.dart`.
  CRUCIAL distinction for OpenTable: a reservation legitimately CAN
  be `reserved_at` in the future (a guest booking 60 days out is
  normal), but a webhook EVENT carrying a future `modified_at`
  indicates clock skew or a forged payload. The Phase 2 harness
  feeds this row into the framework's `sanityHook` (called by
  `backfill` and `pollIncremental` per
  `OpenTableReservationAdapter`); when the framework's
  `vendor_timestamp_sanity` interprets `opened_at = reserved_at`,
  the future booking is allowed (note: adapter passes `opened_at =
  reservation_at` as the booking time, not the event time).
  Adjustment for OpenTable: this scenario specifically exercises the
  case where a webhook arrives with a `modified_at` AFTER `now` —
  framework rejects via the sanity guard since the booking has
  modification metadata claiming to be from the future.
- Adapter assertion (Phase 2): `_canonicalize` accepts the row, but
  `command.sanityHook` returns false (framework's
  `vendor_timestamp_sanity` flags `modified_in_future`). Sink
  assertion: no row written; `sanity_log` and `connector_sync_log`
  rows written by the framework.
