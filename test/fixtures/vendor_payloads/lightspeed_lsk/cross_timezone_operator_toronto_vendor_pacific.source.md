# Source

- URL: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`); adapter constant
  `kLightspeedLskApiVersion = 'f-v2-2026-05'`.
- Endpoint: `GET /f/v2/business-location/{businessLocationId}/sales`
- Notes:
  - Cross-timezone fixture: operator restaurant in
    `America/Toronto` (`businessDayRolloverHour = 4`) consuming
    Lightspeed K-Series sales. K-Series wire timestamps are UTC
    instants regardless of the vendor's internal observation
    timezone, so the fixture's stress is on the
    `IanaTimezoneConverter.toBusinessDate` projection.
  - Two sales straddle the operator's 4 AM business-date rollover:
    - `A65315.xtz-late` opened `2026-05-08T23:30:00Z` (= 19:30 EDT,
      Toronto), closed `2026-05-09T03:55:00Z` (= 23:55 EDT). Both
      timestamps fall on Toronto-local business date `2026-05-08`
      (still before 04:00 next day).
    - `A65315.xtz-rollover` opened `2026-05-09T08:10:00Z` (= 04:10
      EDT) and closed `08:30:00Z` (= 04:30 EDT). Both timestamps
      fall on Toronto-local business date `2026-05-09` (past 04:00
      rollover).
  - Per `docs/integrations/lightspeed_lsk/field_mapping.md`
    Timestamp shapes table, `business_date` is computed as
    `iana_timezone_converter.toBusinessDate(restaurantTimezone, ...)`
    using the OPERATOR's timezone, not the vendor's. This fixture
    locks in that contract — a non-conformant resolver that picked
    the vendor side would compute a Pacific business date instead.
- Expected harness assertion:
  - `xtz-late` row → `business_date = '2026-05-08'`.
  - `xtz-rollover` row → `business_date = '2026-05-09'`.
  - Neither row uses any field from `_pressure_envelope` — that
    block is fixture metadata only and is stripped before adapter
    ingest.
