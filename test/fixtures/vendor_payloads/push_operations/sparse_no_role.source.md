# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/shifts
- Notes: Tests the documented "ambiguity call" from
  `docs/integrations/push_operations/field_mapping.md` — the adapter
  records `position_name` directly; the live slice will verify the
  field is populated on every shift. This sparse fixture forces the
  ambiguity branch: `position_name = null` AND `position_id = null`.
  Per `field_mapping.md` the live slice's bounded fix would switch
  to a `position_id` -> `/api/v1/positions` join; the adapter at
  documented lifecycle MUST either write `role_name = null`
  (canonical) or skip the row. Phase 2A harness asserts no crash and
  no synthesis of a fake role label.
