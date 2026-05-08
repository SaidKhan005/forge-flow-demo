# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/shifts
- Notes: 2026-03-08 is the US/Canada spring-forward boundary
  (clocks jump from 02:00 -> 03:00 local in `America/Toronto`).
  Both `start_at` values are emitted in UTC (per documented Push
  Operations shape with explicit `Z`):
  - `2026-03-08T07:00:00Z` = 02:00 EST = local DST gap (does not
    exist on the wall clock); the IANA timezone resolver MUST
    bump to 03:00 EDT for `business_date` purposes.
  - `2026-03-08T08:30:00Z` = 04:30 EDT (post-jump, unambiguous).

  Per `field_mapping.md` "Timestamp shapes" the `business_date` is
  computed via `iana_timezone_converter.toBusinessDate(...)`. The
  Phase 2A harness asserts:
  1. `_parseUtcInstant` accepts both UTC instants without complaint.
  2. The IANA resolver computes `business_date = 2026-03-08` for
     both shifts (the operator's location is in
     `America/Toronto` with the documented 4 AM business-day
     cutoff per the time-boundary contract — both shifts begin
     after 04:00 local).
  3. The duration calculation handles the lost hour correctly:
     a 7AM-3PM-UTC shift on a spring-forward day spans 8 hours of
     UTC clock time, but only 7 hours of wall time in the local
     time zone — facts and metrics use UTC durations to avoid the
     trap.
