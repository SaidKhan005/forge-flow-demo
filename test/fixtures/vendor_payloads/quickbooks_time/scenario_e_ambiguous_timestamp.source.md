# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#timesheets
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: GET https://rest.tsheets.com/api/v1/timesheets
- Notes: An ambiguous-timezone variant. Vendor docs state every `start` /
  `end` / `last_modified` instant carries an explicit `Z` (UTC). This
  fixture deliberately strips the `Z` (and offers no `+/-HH:MM` offset),
  which makes the timestamp ambiguous (it could be UTC or it could be
  location-local). Per
  `docs/integrations/quickbooks_time/field_mapping.md` and the adapter's
  `vendor_timestamp_policy.quickbooks_time.asUtc` declaration, the
  adapter must REJECT the row, not best-effort guess. The `tz` /
  `tz_str` sibling fields (vendor's documented timezone-of-origin) are
  metadata only and DO NOT rescue the timestamp — business-date
  bucketing happens via `iana_timezone_converter.toBusinessDate` against
  the location's IANA zone, not vendor `tz_str`. The Phase 2 adapter
  harness must assert no canonical fact is written.
