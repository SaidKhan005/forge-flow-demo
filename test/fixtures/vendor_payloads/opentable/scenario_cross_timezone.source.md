# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope)
- Notes: Cross-timezone fixture covering two F&F locations under the
  same operator: one in `America/Toronto`, one in `America/Vancouver`.
  Both receive a webhook with the same UTC instant
  (`2026-05-09T03:30:00Z`) and a third late-night Vancouver row
  (`2026-05-09T07:30:00Z`). The fixture forces the business_date
  resolver to consult per-location IANA timezone; a buggy resolver
  that uses host TZ or the UTC date would mis-bucket. The Phase 7.55
  time boundary contract
  (`docs/contracts/phase_7_55_time_boundary_contract.md`) requires
  operator-scoped fact tables to store `TIMESTAMPTZ` (UTC) plus a
  denormalized `business_date` `DATE`; the canonicalizer's job is to
  emit both correctly. OpenTable's UTC-Z assumption (per
  `field_mapping.md` "Timestamp shapes") makes this fixture's parse
  step trivial; the harness's real assertion is on the
  `business_date` derivation across two timezones from the SAME UTC
  instant.
- Adapter assertion (Phase 2): all three rows' `reservation_at`
  parses cleanly to UTC; `_canonicalize` produces three canonical
  facts. Sink assertion: each row's `business_date` is derived from
  the location's IANA tz (`America/Toronto` for Toronto rows,
  `America/Vancouver` for Vancouver rows). Specifically: Toronto
  03:30Z (= 23:30 EDT 2026-05-08) → `business_date = 2026-05-08`;
  Vancouver 03:30Z (= 20:30 PDT 2026-05-08) → `business_date =
  2026-05-08`; Vancouver 07:30Z (= 00:30 PDT 2026-05-09) →
  `business_date = 2026-05-09` (assuming midnight cutover). The
  framework's `business_date` is NOT the UTC date.
