# Source

- URL: https://libroreserve.github.io/api-documentation/#operation/listReservations
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.confirmed`)
- Notes: Time-edge fixture. The 2026 spring-forward window in
  `America/Toronto` skips 02:00:00–02:59:59 on 2026-03-08 (clocks jump
  EST→EDT). The wall-clock instant `2026-03-08T02:30:00` does not
  exist in this zone. Libro's policy is `asLocationLocal` per
  `docs/integrations/libro/field_mapping.md`, so the adapter projects
  via `LibroIanaConverter.wallClockToUtc(restaurantTimezone='America/Toronto')`.
  The harness MUST observe one of two deterministic outcomes:

  1. The converter surfaces a gap-time error and the framework drops
     the record with a `connector_sync_log` parse_error row (preferred,
     matches scenario E philosophy).
  2. The converter projects to a single deterministic UTC instant
     (e.g. shifts forward by 1h). If outcome 2 holds, the harness
     documents the chosen projection so downstream pressure runs can
     assert it.

  No silent best-effort behavior; whatever choice ships MUST be
  documented and consistent across runs.
