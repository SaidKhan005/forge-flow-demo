# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#timesheets
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: GET https://rest.tsheets.com/api/v1/timesheets
- Notes: A documented-shape timesheet whose `start` is one year in the
  future. The vendor's API itself does not refuse future-dated punches
  (admins may pre-create scheduled punches), but F&F's
  `VendorTimestampSanity` framework guard rejects any payload whose
  `shift_start > now() + 1 hour` and the adapter's polling/backfill loops
  call `command.sanityHook` for every row before writing. The hook
  returns `false` for `opened_in_future`, the canonical fact write is
  skipped, and `sanity_log` + `connector_sync_log 'sanity_drop'` are
  written by the framework. Mirrors `futureDatedQuickBooksTimePunch` in
  `test/integrations/labor/fixtures/quickbooks_time_punches_fixture.dart`.
