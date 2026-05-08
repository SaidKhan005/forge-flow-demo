# Source

- URL: https://docs.clover.com/reference/orderget
- URL: https://docs.clover.com/reference/orders
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: `GET /v3/merchants/{mId}/orders`
- Notes: alias filename named in the calling Phase 1 prompt
  (`cross_timezone_operator_toronto_vendor_pacific.json`) is
  normalized to the README binding filename
  `scenario_cross_timezone.json` for Phase 2 consumers.
- Scenario layout:
    - **Operator location TZ**: `America/Toronto` (UTC-04:00 in May,
      EDT — operator's restaurant lives in Toronto and the F&F
      `business_date` resolver runs there).
    - **Vendor merchant TZ**: `America/Los_Angeles` (UTC-07:00 in
      May, PDT — the underlying Clover merchant deployment is on
      Pacific time, e.g. a multi-location operator with a Vancouver
      tasting-room outpost served from a US-Pacific Clover device).
    - Two orders:
        - `CLV-ORDER-XTZ-LATE-NIGHT-001` —
          `createdTime = 1777699800000` (2026-05-02T05:30:00Z =
          **22:30 PDT on 2026-05-01** vendor-local =
          **01:30 EDT on 2026-05-02** operator-local)
        - `CLV-ORDER-XTZ-EARLY-MORNING-001` —
          `createdTime = 1777706100000` (2026-05-02T07:15:00Z =
          **00:15 PDT on 2026-05-02** vendor-local =
          **03:15 EDT on 2026-05-02** operator-local)
- Adapter cite: per
  `docs/integrations/clover/field_mapping.md` "Timestamp shapes",
  Clover emits epoch millis UTC and the framework's IANA converter
  computes `business_date` against the **operator location's**
  configured `iana_tz` — the vendor merchant's underlying timezone
  is irrelevant to F&F bucketing because the operator's restaurant-
  day calendar is the authoritative anchor (see
  `docs/contracts/phase_7_55_time_boundary_contract.md`).
- Outcome (Phase 2 harness):
    - Both orders write canonical sales facts.
    - `business_date` for both: depends on the operator location's
      restaurant-day cutover. With a 04:00 EDT cutover both rows
      roll into `business_date = 2026-05-01` (Friday's service
      day stretching past midnight). With a 02:00 EDT cutover the
      first stays on Friday and the second flips to Saturday.
    - The harness asserts the resolver uses the **operator's** tz,
      not the vendor merchant's — a regression that switched to
      vendor-local would put the late-night row on **Friday May 1**
      vendor-local but the early-morning row on **Saturday May 2**
      vendor-local, splitting a single Toronto service day across
      two business dates.
