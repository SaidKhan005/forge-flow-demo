# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape — voided
  check)
- Notes: Simphony Gen2 records voided checks as a guest-check element with
  `voidFlag = true` (header-level). `subTtlCents = 0` is the documented
  net-of-void value for voided checks; `lastUpdatedUTC` advances when the
  void posts so polling re-pulls the row. The fixture exercises a covers-
  with-zero-sales shape — the adapter still writes the canonical fact (a
  voided check is still data the operator may want to see in audit logs);
  the read-side honesty contract handles "operator dashboard shows the
  void" rendering downstream.
- Adapter assertion at this fixture:
  - `_mapGuestCheckToCanonical` produces `covers = 4`,
    `actual_sales = 0.00`, `vendor_entity_id = "412903"`.
  - The `voidFlag` field rides through on `raw_payload` for downstream
    audit consumers (Phase 9 audit log).
