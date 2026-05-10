# Source

- URL: https://platform.humanity.com/v1.0/timeclocks (documented in `docs/integrations/humanity/api_consumed.md` table line: "GET /timeclocks — Adjacent surface for clock-in / clock-out punches; same shape as /shifts for the canonical fact write")
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/timeclocks
- Notes:
  - Per `api_consumed.md`, /timeclocks shares the same row shape as /shifts for the canonical fact write. Field paths (`id`, `employee_id`, `position_name`, `in_time`, `out_time`, `updated`) are identical.
  - The `breaks[]` array is documented in Humanity v1's timeclock surface as a child collection on the parent punch row; adapter currently does NOT extract break rows into separate canonical facts (per V1 lean cut 2 — adapter either writes a clean canonical fact or refuses; break rows remain in `rawPayload` for downstream consumers).
  - `type=shift` distinguishes the parent record from break-only timeclock rows. Break details (`type=meal_unpaid`, `duration_minutes`) round-trip via the canonical `raw_payload` field.
  - `start_time`/`end_time` on the break entries deliberately use different keys than parent `in_time`/`out_time` — vendor doc inconsistency captured here so the field-mapping diff in `*.live.sandbox` confirms the adapter ignores the inner shape.
- Outcome: adapter writes one canonical fact (vendorEntityId "TC-9201"); break details preserved on `rawPayload` but not separately materialized.
