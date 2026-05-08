# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#timesheets
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: GET https://rest.tsheets.com/api/v1/timesheets
- Notes: Approved + locked timesheet. The vendor doc records `locked = 1`
  for time entries that have been finalized (e.g., closed payroll period
  approval) and an `approved` flag for the explicit timesheet-approval
  action. Captured here so the adapter pipeline test can confirm the
  approval/locked metadata round-trips through the `rawPayload` field
  without affecting canonical-fact mapping (lock/approval state is not
  part of `documented_per_quickbooks_time_v1` at V1).
