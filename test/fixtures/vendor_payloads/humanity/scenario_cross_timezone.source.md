# Source

- URLs:
  - https://platform.humanity.com/v1.0/shifts (documented in `docs/integrations/humanity/api_consumed.md`)
  - https://platform.humanity.com/v1.0/company (documented in `docs/integrations/humanity/api_consumed.md` table line: "GET /company — Account-wide config (timezone, business-day rollover hint) read on first connect")
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoints: GET /v1.0/company (paired metadata response) + GET /v1.0/shifts (paged listing)
- Notes:
  - Per CLAUDE.md "Time Guardrails" section: "restaurant-local timing wins; business date is the anchor". The operator's `restaurant_locations.iana_timezone` is authoritative; Humanity's `/company.timezone` is metadata only.
  - Fixture combines an operator-Toronto location (`America/Toronto`) with a vendor company-record reporting `America/Vancouver` — a 3-hour gap that surfaces resolver bugs. The Vancouver value is plausible (operator may have set it before opening the Toronto location, or the company HQ uses different timezone than the restaurant).
  - Three rows trace the divergence:
    - 9700: in_time 03:30 UTC — both Toronto and Vancouver resolve to 2026-05-04 business_date (within their respective rollover windows). Same answer either way.
    - 9701: in_time 06:00 UTC — both still resolve to 2026-05-04 business_date due to rollover_hour=4 in both zones. Same answer.
    - 9702: in_time 08:00 UTC — Toronto resolves to business_date 2026-05-05; Vancouver resolves to 2026-05-04. **DIFFERENT.** Phase 2 harness asserts the Toronto answer (operator location authority) is what lands on the canonical row.
  - The `_resolver_note` keys are fixture annotations stripped before the page is handed to the adapter.
- Outcome: adapter writes 3 canonical facts; downstream business_date for row 9702 = `2026-05-05` (Toronto-derived, NOT Vancouver-derived).
