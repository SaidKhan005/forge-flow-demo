# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Endpoint: `GET /reservations/search` page item (or webhook delivery)
- Notes: `serviceDateTimestamp` and `lastUpdatedTimestamp` are 73 years
  in the future. The framework's sanity hook (mandatory framework
  call #1 — see
  `lib/integrations/reservation/tock_reservation_adapter.dart`
  backfill / pollIncremental paths) MUST reject this payload on the
  polling path (`isDeliberateBackfill: false`); on the deliberate
  60-day backfill path the future ceiling is still enforced. Adapter
  assertion: `sanity_log` row written, no canonical fact write,
  `connector_sync_log` records the drop. This fixture mirrors the
  `p2-res-future` row in
  `test/integrations/reservation/fixtures/tock_reservations_fixture.dart`.

## Sourcing context

Public reservation reference + engineering-slice fixture mirror. No
live HTTP calls.
