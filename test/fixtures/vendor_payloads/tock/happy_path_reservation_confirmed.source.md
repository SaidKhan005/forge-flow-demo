# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03` (per
  `docs/integrations/tock/api_consumed.md` — slug derived from doc
  retrieval date 2026-05-04; Tock does not publish a numeric API
  version on the public reservation reference)
- Endpoint: `GET /reservations/search` (cursor-paginated; this fixture
  represents one element of the `reservations` array)
- Notes: shape mirrors `documentedPerTockReservation20260504` constant
  in `lib/integrations/reservation/tock_reservation_adapter.dart` and
  the `tockSampleReservation` mirror in
  `test/integrations/reservation/fixtures/tock_reservations_fixture.dart`.
  Status `EXPECTED` is the documented "reservation confirmed, guest
  has not yet arrived" state per the Tock public reservation reference.
  Forbidden fields (`guest.firstName`, `guest.lastName`, `guest.email`,
  `guest.phone`, `paymentInstrument`) are intentionally absent — the
  adapter never reads them; the fixture not carrying them protects
  test runs from accidentally teaching the adapter a forbidden path.

## Sourcing context

Tock is partner-only; the full Premium-tier developer surface is gated
to credentialed accounts. This fixture is shaped from the **public**
reservation reference + the existing engineering-slice fixture mirror
(`test/integrations/reservation/fixtures/tock_reservations_fixture.dart`,
which Codex already graded against the public doc on 2026-05-04). No
live HTTP calls; no sandbox credentials consumed.
