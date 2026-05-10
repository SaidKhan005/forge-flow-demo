# Source

- URL: https://platform.humanity.com/v1.0/shifts (documented in `docs/integrations/humanity/api_consumed.md`)
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/shifts
- Notes:
  - Reproduces a real-world shape: when an employee is scheduled before role assignment, vendor docs show `position_name`/`position` may be omitted from the row. Adapter `HumanityShiftDto.tryFromMap` (lib/integrations/labor/humanity_labor_adapter.dart lines 215-217) requires a non-empty position string and returns null otherwise.
  - Per `field_mapping.md` "Forbidden fields" section: Humanity exposes only position-level pay rates (`positions.pay_rate`), not per-employee. The adapter's wage path falls back to `wage_source = app_fallback` for any employee whose position cannot be resolved. This sparse path validates that fallback chain.
  - The drop is silent at the adapter boundary (no `parse_warnings` channel per V1 lean cut 2); the framework's connector_sync_log captures the count via the malformed-payload counter.
- Outcome: adapter drops row; no canonical fact written; wage path for this employee_id falls through to app_fallback.
