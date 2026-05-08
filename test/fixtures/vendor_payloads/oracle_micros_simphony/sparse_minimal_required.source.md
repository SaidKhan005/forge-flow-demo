# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape —
  smallest legal `header` per documented schema)
- Notes: This is the minimum-shape envelope the Gen2 doc allows: `chkNum`
  + the three documented timestamps + `subTtlCents`. No `locRef`,
  `guestCount`, `rvcNum`, `tblNum`, etc. The adapter must succeed: every
  documented required field is present.
- Adapter assertion at this fixture:
  - `_mapGuestCheckToCanonical` produces `covers = null`,
    `actual_sales = 9.20`, `vendor_entity_id = "412911"`,
    `opened_at = 2026-05-02T19:55:00Z`,
    `closed_at = 2026-05-02T20:01:33Z`.
  - `pollIncremental` writes the canonical fact and advances watermark
    (no nextCursor).
