# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Endpoint: `GET /reservations/search` page item
- Reference: `docs/contracts/phase_7_55_time_boundary_contract.md`
  (operator-scoped Postgres fact tables store `TIMESTAMPTZ` UTC plus
  denormalized `business_date` `DATE`; `iana_timezone_converter` owns
  the local-business-date computation)
- Notes: 2026-03-08 is the US spring-forward date — at 02:00
  America/New_York, the wall clock jumps to 03:00 (the 02:00–03:00
  window does not exist in the local zone). `serviceDateTimestamp`
  here is `2026-03-08T07:30:00Z` which is `02:30 EST` BEFORE the
  jump — but the operator's location-local timezone resolver MUST
  decide whether `business_date` is 2026-03-07 (prior day, "still
  Saturday for late seatings") or 2026-03-08 (calendar date) per the
  framework's `iana_timezone_converter.toBusinessDate`. The Phase 2
  harness MUST assert the canonical fact's `business_date` matches
  the operator's location-local cutover policy and that the
  `reservation_at` UTC value round-trips losslessly through the
  TIMESTAMPTZ column.

## Sourcing context

Public reservation reference + framework time-boundary contract.
Per the format spec README, the DST edge uses the 2026-03-08 US
spring-forward window (the 2025-11-02 fall-back window is the
mirror edge, covered by scenario E for the ambiguous-hour case).
No live HTTP calls.
