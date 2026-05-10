# Source

- URL: https://libroreserve.github.io/api-documentation/#operation/listReservations
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.confirmed`)
- Notes: Adversarial scenario E. The fall-back DST window for the
  adapter's primary deployment region (`America/Toronto`, the operator
  timezone in the Libro fixture suite) occurs at 2026-11-01 01:30 —
  this wall-clock instant exists TWICE (once in EDT before the rollback,
  once in EST after). Libro emits restaurant-local wall-clock with no
  tz hint per `vendor_timestamp_policy['libro'] = asLocationLocal` (see
  `docs/integrations/libro/field_mapping.md` Timestamp shapes). The
  adapter projects via `LibroIanaConverter.wallClockToUtc`. The
  converter MUST refuse the timestamp rather than silently picking one
  of the two interpretations. The framework's response: log a
  `connector_sync_log` parse_error row and drop the record. The
  pressure-test acceptance criterion is **reject, not best-effort**.
