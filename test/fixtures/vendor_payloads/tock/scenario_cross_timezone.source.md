# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Endpoint: `GET /reservations/search` page item
- Reference: `docs/contracts/phase_7_55_time_boundary_contract.md`
  (location-local IANA tz drives `business_date` computation;
  TIMESTAMPTZ stores UTC; `business_date` denormalized DATE)
- Notes: `serviceDateTimestamp = 2026-05-09T03:30:00Z` is:
  - `20:30` on 2026-05-08 in `America/Vancouver` (PDT, UTC-7) —
    i.e. an 8:30pm seating in Vancouver, business_date = 2026-05-08.
  - `23:30` on 2026-05-08 in `America/Toronto` (EDT, UTC-4) —
    i.e. an 11:30pm seating in Toronto, business_date = 2026-05-08.
  - `03:30` on 2026-05-09 in `UTC` — i.e. a calendar-date 2026-05-09
    moment.
  This forces the resolver to choose: business_date follows the
  operator's **location-local** zone, NOT the UTC calendar. The
  Phase 2 harness drives this fixture once with the location's
  `iana_timezone = "America/Vancouver"` and asserts `business_date
  == 2026-05-08`; runs again with `iana_timezone = "America/Toronto"`
  and asserts `business_date == 2026-05-08` (still 2026-05-08
  locally, despite the UTC date being 2026-05-09); and a third run
  with operator misconfigured tz (`UTC`) where the resolver MUST
  refuse to write rather than silently producing a 2026-05-09
  business_date that contradicts the operator's restaurant-local
  reality. Adapter assertion: canonical fact carries the documented
  UTC `reservation_at`; the framework-side `business_date`
  denormalization respects the location-local cutover.

## Sourcing context

Public reservation reference + framework time-boundary contract.
Time guardrail (per `CLAUDE.md` "Time Guardrails"):
restaurant-local timing wins; business date is the anchor; closed
truth is not rewritten by later cycles or weekly plans. No live
HTTP calls.
