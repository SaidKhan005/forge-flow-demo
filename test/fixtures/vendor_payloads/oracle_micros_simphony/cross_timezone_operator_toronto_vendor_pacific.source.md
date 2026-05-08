# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- URL (multi-location decision): docs/integrations/oracle_micros_simphony/oauth_shape.md (Per-location vs operator-wide grant)
- URL (Scenario D — multi-location chain): docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md line 241
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape — guest
  check from a Vancouver location of a Toronto-HQ operator)
- Notes: This fixture forces the framework's IANA resolver to choose
  between two zones — the operator's HQ zone (Toronto) and the location's
  zone (Vancouver). The Phase 8 plan's IANA Scenario D ("multi-location
  chain — Two locations on the same operator with different timezones —
  'Today's covers' for each resolves against the location's own
  timezone, not the operator's device clock") binds this exact case.
  Simphony's per-location grant scope (each `locRef` has its own OAuth
  credential pair) makes the location-binding load-bearing.
- Adapter assertion at this fixture:
  - `connector_connection.metadata.simphony_loc_ref = "002-PIE-VAN"`.
  - The framework looks up the location's IANA zone from
    `restaurant_locations.iana_zone = "America/Vancouver"`, NOT the
    operator's HQ zone.
  - `iana_timezone_converter.toBusinessDate` projects
    `cmplOrClsdUTC = 2026-05-03T06:35:00Z` to
    `2026-05-02T23:35:00-07:00` in Vancouver. With 04:00 local cutoff,
    business_date = 2026-05-02.
  - If the framework wrongly used the operator's Toronto zone,
    business_date would resolve to 2026-05-03 (off by one day).
  - The Phase 2 harness asserts business_date = `2026-05-02`.
- Cite vendor doc:
  https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- Cite IANA scenario doc: docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md (line 241)
