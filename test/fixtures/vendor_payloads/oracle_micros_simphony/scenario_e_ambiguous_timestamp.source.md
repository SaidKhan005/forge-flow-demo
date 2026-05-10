# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- URL (timestamp policy): docs/integrations/oracle_micros_simphony/field_mapping.md (Timestamp shapes section)
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape —
  timestamps without timezone designator)
- Notes: All three timestamp fields drop the `Z` suffix. Simphony's
  documented Gen2 schema specifies ISO-8601 with explicit `Z` (UTC) on
  `opnUTC`, `cmplOrClsdUTC`, `lastUpdatedUTC`. The adapter's timestamp
  policy `oracle_micros_simphony.asUtc` says: parse strict; refuse
  ambiguous shapes (no Z, no offset). This is the classic Scenario E
  boundary from the framework's IANA Scenarios A-F set
  (`docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`
  lines 238-243).
- Adapter assertion at this fixture:
  - `_parseUtcInstant` is called via `DateTime.parse(...).toUtc()`. In
    Dart's parser, `2026-05-02T19:00:00` (no Z, no offset) parses as
    a *local* DateTime — calling `.toUtc()` on it converts using the
    runtime's local zone, which is wrong: the vendor declares UTC,
    so the value would silently shift by N hours of offset.
  - The adapter MUST refuse this record. Implementation: the
    framework's malformed-payload defense (try-catch around DTO
    parse) wraps the parse and the timestamp-shape check rejects
    timestamps without explicit `Z`.
  - `sanity_log` row written with rule `ambiguous_timestamp`.
  - `recordsWritten` does NOT increment.
  - The `8.OR.live.sandbox` slice verifies that production Simphony
    actually returns explicit-Z; if it does not, the adapter switches
    to a documented-shape rule (e.g., "treat as UTC").
- Cite vendor doc:
  https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
  (vendor schema lists ISO-8601 UTC with `Z` on every timestamp field
  in the documented Gen2 envelope).
