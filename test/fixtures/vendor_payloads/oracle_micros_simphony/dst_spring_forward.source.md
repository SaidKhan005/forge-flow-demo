# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- URL (IANA scenarios): docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md (Scenarios A-F binding lines 238-243)
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape — guest
  check straddling US 2026 spring-forward)
- Notes: 2026-03-08 02:00 local in `America/New_York` is the spring-forward
  jump — clocks skip from 02:00 EST to 03:00 EDT. The fixture's check
  opens at 06:55 UTC (02:55 EST, just before the jump) and closes at
  08:30 UTC (04:30 EDT, after the jump). Simphony documents all timestamps
  in UTC with explicit `Z`, so parsing is unambiguous; the work the
  framework does is in IANA-converting these to local business-date for
  the operator's dashboard.
- Adapter assertion at this fixture:
  - Both timestamps parse cleanly via `_parseUtcInstant`.
  - The framework's `iana_timezone_converter.toBusinessDate` projects
    `closed_at = 2026-03-08T08:30:00Z` to `2026-03-08T04:30:00-04:00`
    in `America/New_York`, then applies the operator's business-day
    cutoff (04:00 local) to get business_date = `2026-03-07` (the
    cutoff lands at 04:00 EDT post-shift, so 04:30 is just past — but
    if cutoff is treated as "after 04:00 belongs to next day" then
    `2026-03-08`. The Phase 2 harness must assert the framework's
    documented rounding rule explicitly.
  - The point is: a fixed-offset converter would silently mis-bucket;
    IANA disambiguates.
- Cite vendor doc:
  https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- Cite IANA scenario doc: docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md (lines 238-243)
