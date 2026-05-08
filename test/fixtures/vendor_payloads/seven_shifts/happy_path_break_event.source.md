# Source

- URL: https://developers.7shifts.com/reference/listtimepunches
- URL (breaks): https://developers.7shifts.com/reference/listtimepunches
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: `time_punch.edited` webhook envelope (matches the
  documented `breaks` array nested on a time_punch row)
- Notes: documented break shape — each break carries `in`, `out`,
  `paid`. Two breaks (one paid, one unpaid) cover both branches. The
  break boundaries are inside the punch's `clocked_in` /
  `clocked_out` window per the developer reference. The canonical
  fact does not yet persist the breaks array (Phase 8 ships
  `is_approved` + payroll-period close as the load-bearing fields);
  Phase 2 harness can extend coverage when break-aware aggregation
  ships.
