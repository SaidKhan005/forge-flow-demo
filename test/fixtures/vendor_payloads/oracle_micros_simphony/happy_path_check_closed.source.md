# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape — single
  page of `items[]`)
- Notes: shape mirrors the adapter's documented assumptions in
  `test/integrations/pos/fixtures/oracle_micros_simphony_checks_fixture.dart`
  (`documented_per_oracle_micros_simphony_v2`) and the field-mapping table at
  `docs/integrations/oracle_micros_simphony/field_mapping.md`. Cursor token
  `nextCursor` is opaque per the vendor docs; the value here is a base64-ish
  placeholder. `rvcNum` (revenue center) and `tblNum` / `tblName` are
  documented Simphony header fields; the F&F adapter does not consume them
  but they appear in real Gen2 responses, so the fixture preserves shape
  fidelity. No covers degrade — `guestCount = 5` is direct.
- Adapter assertion at this fixture:
  - `_mapGuestCheckToCanonical` produces `covers = 5`,
    `actual_sales = 124.85`, `opened_at = 2026-05-02T22:45:00Z`,
    `closed_at = 2026-05-02T23:32:14Z`,
    `vendor_modified_at = 2026-05-02T23:32:14Z`,
    `covers_source = "direct"`.
  - `pollIncremental` paginates to `nextCursor`; second call with that
    cursor returns the next page.
