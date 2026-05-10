# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#timesheets
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: GET https://rest.tsheets.com/api/v1/timesheets
- Notes: A `timesheets[]` row missing the required `id` field. Per the
  vendor doc every timesheet row carries a numeric `id` (used as the
  `vendor_entity_id`). The adapter's `mapTimesheetToCanonical` returns
  null when `id` is missing or empty (see
  `lib/integrations/labor/quickbooks_time_labor_adapter.dart` — first
  guard in the function). The Phase 2 adapter harness must assert no
  canonical fact is written and `connector_sync_log` records the drop.
