# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape — guest
  check with `guestCount` absent)
- Notes: Real-world Simphony deployments sometimes ship checks where
  `guestCount` is not entered at the POS terminal (counter-service, takeout,
  bartender ringing in a beer with no cover count). The Gen2 doc lists
  `guestCount` as optional on `header`. The adapter handles this by leaving
  `covers = null`. The framework's metric-honesty contract (per `8.0` lean
  cut) renders covers metrics as `partial` when null is observed at the
  vendor source, surfacing on the dashboard pill — never a phantom zero.
- Adapter assertion at this fixture:
  - `_mapGuestCheckToCanonical` produces `covers = null`,
    `actual_sales = 18.50`. Canonical write succeeds.
  - Downstream metric pipeline must mark this fact's `covers_provenance`
    as `vendor_omitted`; PPA aggregation excludes it (or counts as zero
    covers per the metric_card_honesty_contract).
