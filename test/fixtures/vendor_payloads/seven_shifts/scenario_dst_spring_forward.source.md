# Source

- URL: https://developers.7shifts.com/reference/listtimepunches
- URL (timestamp contract):
  `docs/contracts/phase_7_55_time_boundary_contract.md`
- URL (vendor timestamp policy):
  `docs/integrations/seven_shifts/field_mapping.md` "Timestamp shapes"
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: documented `time_punch.edited` envelope, instants
  spanning the 2026-03-08 DST spring-forward window in
  America/Toronto
- Notes: time edge — the 02:00→03:00 spring-forward jump on the
  second Sunday in March 2026 is the canonical North American DST
  transition. The 7shifts API documents UTC timestamps, so the wall
  clock gap is invisible on the wire; the UTC delta (4h 30m) is the
  truth. The fixture exercises the adapter's reliance on UTC
  parsing (`DateTime.tryParse(...).toUtc()` at line ~1356 of
  `seven_shifts_labor_adapter.dart`) and the location-local
  business_date computation downstream. A naive "subtract local
  wall clocks" implementation would mis-count by 1h.
