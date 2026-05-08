# Source

- URL: https://platform.humanity.com/v1.0/shifts (documented in `docs/integrations/humanity/api_consumed.md`)
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/shifts (returns both `type=shift` and `type=time_off` records inline)
- Notes:
  - Humanity v1 surfaces time-off requests as a parallel record alongside regular shifts on the `/shifts` listing. The `type` field distinguishes them; auxiliary fields (`leave_type`, `paid`, `duration_hours`) are populated only on time-off rows.
  - `HumanityShiftDto.tryFromMap` (humanity_labor_adapter.dart lines 193-227) does NOT branch on `type` — it parses any row with valid id/in_time/out_time/updated/employee_id/position_name. Time-off rows that include all required fields therefore CURRENTLY land in the canonical labor fact table indistinguishable from worked shifts. Whether this is the intended behavior is an open question for `*.live.sandbox` and the Phase 2 harness will pin the assertion the team wants.
  - Recommended Phase 2 assertion: time-off row writes a canonical fact with `shift_start=2026-05-11T00:00:00Z`, `shift_end=2026-05-12T00:00:00Z`. Downstream wage / hours computations treat the row as 24h elapsed — likely INCORRECT for time-off semantics. This fixture pins the bug surface; remediation is a separate slice.
- Outcome: adapter writes 2 canonical facts (1 shift, 1 time-off treated as a 24h shift); Phase 2 harness flags the time-off row as a known divergence and recommends an adapter-side filter on `type != "time_off"` for a future hardening slice.
