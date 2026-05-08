# Source

- URL: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`); adapter constant
  `kLightspeedLskApiVersion = 'f-v2-2026-05'`.
- Endpoint: `GET /f/v2/business-location/{businessLocationId}/sales`
- Notes:
  - DST anchor: 2026-03-08 in `America/New_York` — clocks jump from
    01:59:59 EST (UTC-5) directly to 03:00:00 EDT (UTC-4). The
    02:00–02:59 local hour does not exist.
  - Three sales straddle the spring-forward boundary in UTC:
    - `A65315.dst-pre` opened `2026-03-08T06:45:00Z` (= 01:45 EST) —
      pre-jump.
    - `A65315.dst-skip` opened `2026-03-08T07:01:00Z` (= 03:01 EDT,
      since the local clock skipped 02:00–02:59) — would map to a
      non-existent local time if the resolver tried to invert.
    - `A65315.dst-post` opened `2026-03-08T12:45:00Z` (= 08:45 EDT)
      — post-jump, anchors to a normal brunch slot.
  - K-Series timestamps are UTC instants with `Z`, so the wire shape
    is unambiguous. The DST stress is on the framework's
    `IanaTimezoneConverter.toBusinessDate` — given a 4 AM rollover
    in `America/New_York`, all three sales should compute
    `business_date = 2026-03-07` (the prior business day, since
    none of them is past 04:00 local on the new day yet).
  - Adapter call site:
    `_projectCanonicalRecord` calls
    `_converter.toBusinessDate(restaurantTimezone: 'America/New_York',
    businessDayRolloverHour: 4, instant: openedAt)` for each row.
- Expected harness assertion: all three rows project to
  `business_date = 2026-03-07`. The `dst-skip` row in particular
  must NOT throw or silently shift to 2026-03-08.
