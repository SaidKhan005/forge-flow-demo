# Source

- URL: https://platform.humanity.com/v1.0/shifts (documented in `docs/integrations/humanity/api_consumed.md`)
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/shifts
- DST window: 2026-03-08 02:00 EST → 03:00 EDT (US spring-forward)
- Notes:
  - Per `field_mapping.md` "Timestamp shapes" table, Humanity's `in_time`/`out_time`/`updated` are ISO 8601 with explicit `Z`. The vendor stays in UTC across DST transitions (spring-forward and fall-back); the framework converts to operator-local for `business_date` bucketing via `iana_timezone_converter.toBusinessDate`.
  - Three rows cover the transition envelope:
    - 9600 ends right before the local jump (out_time 06:00 UTC = 02:00 EST, the last EST instant — local clock then leaps to 03:00 EDT).
    - 9601 STRADDLES the transition: in_time 05:00 UTC = 00:00 EST; out_time 13:00 UTC = 09:00 EDT. The local-clock duration appears to "lose" an hour (00:00 → 09:00 looks like 9h locally) but the UTC duration is exactly 8h. Wage / hours computations MUST use UTC duration; business_date MUST use the local in_time date.
    - 9602 sits entirely after the transition (03:30 EDT → 11:30 EDT).
  - The `_local_window_note` keys are fixture annotations (stripped by the Phase 2 harness before the page is handed to the adapter).
  - 2026-03-08 is the official 2026 US spring-forward date (per `test/fixtures/vendor_payloads/README.md` "Time edges" guidance).
- Outcome: adapter writes 3 canonical facts; downstream business_date bucketing yields:
  - 9600 → business_date `2026-03-07` (in_time 17:00 EST on 2026-03-07)
  - 9601 → business_date `2026-03-08` (in_time 00:00 EST on 2026-03-08)
  - 9602 → business_date `2026-03-08` (in_time 03:30 EDT on 2026-03-08)
