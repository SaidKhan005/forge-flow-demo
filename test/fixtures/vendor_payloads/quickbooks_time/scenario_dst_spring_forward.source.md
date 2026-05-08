# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#timesheets
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: GET https://rest.tsheets.com/api/v1/timesheets
- Notes: 2026 US/Canada DST spring-forward window — clocks advance from
  02:00 to 03:00 Pacific local time on Sunday 2026-03-08. The vendor
  emits `start` / `end` as ISO 8601 with explicit `Z` (UTC), so the
  vendor payload itself is unambiguous: 09:00 UTC = 01:00 PST (before
  spring-forward), 15:00 UTC = 08:00 PDT (after spring-forward); the
  shift's wall-clock window crosses the DST jump (02:00 → 03:00 local).
  The `tz_str` field still reads `-08:00` (the operator's location's
  standard offset registered with QBT) — this is informational metadata
  only and the adapter MUST NOT use it for business-date bucketing. The
  framework resolves business_date by passing the UTC instant through
  `iana_timezone_converter.toBusinessDate(zone: America/Vancouver)`.
  The Phase 2 adapter harness asserts:
  - `shift_start_utc = 2026-03-08T09:00:00Z` (canonical UTC)
  - `business_date = 2026-03-08` (Vancouver local)
  - vendor `duration = 21600` (6h elapsed UTC). Note: local wall-clock
    spans 01:00 → 08:00 (7h of clock advancement) but the spring-forward
    eats one hour, so true on-clock time is 6h. F&F honors the vendor
    `duration` field exactly — the adapter does NOT recompute duration
    from `(end - start)` in local wall time.
