# Source

- URL: https://libroreserve.github.io/api-documentation/#operation/listReservations
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.completed`)
- Notes: Cross-timezone fixture. The pressure-test operator
  `op_pressure_test_001` has multiple locations: a Toronto venue
  (`America/Toronto`) and a Vancouver venue (`America/Vancouver`). This
  payload is from the Vancouver venue (`venue-vancouver-yaletown`).

  Libro emits restaurant-local wall-clock with no tz hint (per
  `vendor_timestamp_policy['libro'] = asLocationLocal`). Per
  `LibroReservationAdapter._materialize` (line 788 of the adapter), the
  adapter resolves the per-LOCATION `restaurantTimezone` from
  `LibroConnectionContext.restaurantTimezone`, NOT the operator
  default. The pressure harness asserts:

  - `reservation_at` materializes to UTC `2026-05-05T03:00:00Z`
    (Vancouver 20:00 PDT).
  - `business_date` projects against `America/Vancouver` +
    `business_day_rollover_hour` (typically 03:00 local), NOT
    Toronto's. A naive operator-default picker would mis-project to
    `business_date = 2026-05-04` in Toronto's frame.

  Phase 7.55 Rule 11 is the source-of-truth for the business-date
  projection. Time guardrails: `TIMESTAMPTZ` on the
  operator-scoped fact table, `business_date` denormalized as `DATE`
  in the same row.
