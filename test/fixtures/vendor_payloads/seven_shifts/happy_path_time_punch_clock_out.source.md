# Source

- URL: https://developers.7shifts.com/reference/listtimepunches
- URL (webhooks reference): https://developers.7shifts.com/reference/webhooks
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04` per
  `docs/integrations/seven_shifts/api_consumed.md`)
- Endpoint: `time_punch.edited` webhook envelope (matches the row shape
  returned by `GET /v2/company/{company_id}/time_punches`)
- Notes: payload mirrors the v2 webhook envelope produced when an
  operator approves and edits a completed time punch. `clocked_in` /
  `clocked_out` are explicit-Z UTC strings per the developer reference;
  `approved=true` is the Phase 7.58 Primary Driver finalization signal
  per `docs/integrations/seven_shifts/field_mapping.md`. The breaks
  array, hourly_wage, and tips fields appear in the documented
  time_punch shape and are intentionally retained for adapter coverage
  even though only a subset (id, user_id, shift_id, role.name,
  clocked_in, clocked_out, approved, modified) populates the canonical
  fact today.
