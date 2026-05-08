# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#timesheets
- Retrieved: 2026-05-08
- API version: v1 (QuickBooks Time / TSheets developer API; Intuit-rebranded brand)
- Endpoint: GET https://rest.tsheets.com/api/v1/timesheets
- Notes: Documented "List Timesheets" response shape — outer `results.timesheets[]`
  array, sibling `results.supplemental_data` (joined `users` + `jobcodes` keyed by id),
  and `results.more` boolean for pagination. The example here is a closed
  (clocked-out) regular timesheet — `end` is a non-empty ISO 8601 instant with
  explicit `Z`, `on_the_clock` is `false`, and `duration` (seconds) matches
  `end - start`. Field paths align with `documented_per_quickbooks_time_v1`
  (see `lib/integrations/labor/quickbooks_time_labor_adapter.dart`).
