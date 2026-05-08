# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08
- API version: `orders/v2`

## Notes

- Operator-side device timezone: `America/Toronto` (EDT in May,
  UTC-4).
- Location/restaurant timezone: `America/Los_Angeles` (PDT in
  May, UTC-7).
- Order opens at `06:30Z` = `23:30 PT (2026-05-06)` =
  `02:30 ET (2026-05-07)`. The location's business_date is
  `2026-05-06` (still inside the LA business day with a typical
  04:00 cutoff); a naive computation against the operator's
  Toronto clock would produce `2026-05-07`.
- `businessDate: 20260506` matches the location-local resolution
  per the documented Toast Order schema (Toast itself computes
  `businessDate` against the restaurant's timezone — the
  framework's spine MUST do the same when re-deriving rather than
  relying on the operator's device clock).
- `_test_operator_iana` / `_test_location_iana` /
  `_test_local_intent` are test-side metadata, not part of the
  Toast wire shape.
- `restaurant.guid: 9b3a7c5e-...` differs from the other fixtures'
  Toronto-implicit demo restaurant guid, signaling a second
  location row exists for the same operator with a different
  IANA timezone.

## Sourcing fallback

Reconstructed from `phase_8_live_pos_labor_adapter_plan.md`
Scenario D (multi-location chain) + `field_mapping.md`
(business_date computed via `iana_timezone_converter.toBusinessDate`)
+ Toast Order schema documentation cited in `documentedPerToastV2`.

## Expected adapter behavior

- Signature verifies; sanity hook passes.
- `_canonicalize` produces canonical fact with UTC timestamps.
- Sink-level business_date denormalization resolves against the
  LOCATION's IANA timezone (looked up from
  `restaurant_locations.timezone_iana` keyed on
  `restaurant.guid`), NOT the operator's device clock or a
  default UTC.
- Resulting `business_date = 2026-05-06`.
- `upsertOrderFact` writes one row.

## What this scenario asserts

- HP #1 + Time Guardrail: "restaurant-local timing wins; business
  date is the anchor."
- The operator-scoped repository's per-location timezone lookup
  is the source of truth, not any operator-wide default.
- Multi-location operators with different timezones produce
  correct per-location `business_date` even when the operator's
  device or backend orchestrator runs in a third timezone.
