# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape — guest
  check with `payments[]` populated)
- Notes: a closed check with one Visa tender. The Simphony Gen2 doc lists
  `payments[]` as a sibling array under each `items[]` element with
  `tenderTypeName`, `tenderTypeNum`, `totalCents`, `tipCents` (typical
  numeric-cents convention seen across the vendor's documented payment
  endpoints). The F&F adapter does NOT consume `payments[]` at V1 (PCI
  scope; `field_mapping.md` "Forbidden fields" excludes per-tender / per-
  cardholder data). The fixture exists so Phase 2 sink tests can assert that
  the canonical write ignores `payments[]` and only persists `header.*` to
  the canonical fact + the full record under `raw_payload`. Empty
  `nextCursor` signals end of page.
- Adapter assertion at this fixture:
  - `_mapGuestCheckToCanonical` produces canonical fact with
    `covers = 2`, `actual_sales = 57.90`. `payments` is preserved on
    `raw_payload` but not promoted to a column.
