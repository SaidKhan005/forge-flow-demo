# Source

- URL: https://developers.7shifts.com/reference/listtimepunches
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: `time_punch.created` webhook envelope
- Notes: documented edge case — operator clocks in without a planned
  shift OR before the role assignment is finalized. Per the
  developer reference, `role` is documented as a nested object that
  can be null when no role is assigned; `shift_id` is documented
  nullable when the punch is unscheduled (operator clocked in
  without a planned shift). The adapter's `_canonicalizePunch`
  defaults `roleName` to empty string when `role` is null/missing
  and persists null `shiftId` so the wage merge falls through to
  substituted-wage provenance — see
  `lib/integrations/labor/seven_shifts_labor_adapter.dart`. Open
  punch (`clocked_out: null`) is also exercised here.
