# Source

- URL: https://developers.7shifts.com/reference/listtimepunches
- URL (locations endpoint):
  https://developers.7shifts.com/reference/listlocations
- URL (timestamp contract):
  `docs/contracts/phase_7_55_time_boundary_contract.md`
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: documented `time_punch.edited` envelope with the
  documented `location` nested object carrying a `timezone` field
- Notes: time edge — cross-timezone resolver verification. Per HP
  authority `phase_7_55_time_boundary_contract.md` the
  `business_date` anchor is the F&F location-bound IANA (the
  operator's restaurant-local truth), NOT the vendor's nested
  `location.timezone` field. This fixture pairs a Vancouver-bound
  F&F location with a Toronto-bound 7shifts vendor location and
  asserts the resolver picks Vancouver. The UTC instants
  (02:30→07:30 UTC) wrap midnight in Pacific (19:30 prior day to
  00:30 next day) so business_date computation is non-trivial — a
  resolver bug that picks Toronto would compute 2026-04-15 (since
  07:30 UTC = 03:30 Eastern, still on 2026-04-16 in Toronto but
  ambiguous when wrapping).
