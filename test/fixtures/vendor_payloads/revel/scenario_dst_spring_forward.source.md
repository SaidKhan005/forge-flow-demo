# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: webhook subscription `order.finalized` — DST spring-forward edge.
- Notes:
  - DST date used: 2026-03-08 (US/Canada spring-forward — 02:00 EST → 03:00 EDT in `America/Toronto`). Per `test/fixtures/vendor_payloads/README.md`: "the 2026-03-08 US spring-forward window or the equivalent fall-back for the vendor's primary deployment region".
  - Revel emits ISO 8601 UTC timestamps. UTC has no DST so the wire shape itself is unambiguous; the resolution work happens in the `iana_timezone_converter.toBusinessDate` step at canonical-fact write time using `location.timezone` per Phase 7.55 Rule 11.
  - Two business-date risks the harness must check:
    1. Operator running with default `business_day_rollover_hour = 04:00` local: both timestamps (01:30 EST and 04:30 EDT) bucket to the prior business day `2026-03-07`. The order is one business "day" event, not two.
    2. The 02:00-03:00 EST hour does not exist on this calendar date; any code that does naive `local_time = utc_time + utc_offset` arithmetic across the boundary would mis-bucket. The IANA converter must use a real timezone library, not a fixed-offset shortcut.
  - Phase 2 sink/spine harness assertion: canonical fact written exactly once with `business_date = '2026-03-07'`; no duplicate row; no row written with `business_date = '2026-03-08'` AND a second mirror row with `business_date = '2026-03-07'`.
