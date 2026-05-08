# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope)
- Notes: Time-edge fixture covering the 2026-03-08 US DST spring-
  forward window. The local interval `[02:00, 03:00) America/New_York`
  on 2026-03-08 does not exist. Per the assumed OpenTable timestamp
  shape (UTC ISO-8601 with explicit `Z` per `field_mapping.md`
  "Timestamp shapes"), the vendor never emits a local-only string,
  so the canonicalizer simply parses 10:30Z as a UTC instant and the
  DST transition is invisible at the parse boundary. The Phase 2
  harness's job is to verify (1) the parse succeeds, (2) the
  business_date resolver
  (`IanaTimezoneConverter.toBusinessDate(utcInstant,
  'America/New_York')`) lands 2026-03-08 (not 2026-03-07 or
  2026-03-09 — a buggy resolver could mis-bucket near the DST
  transition), and (3) `vendor_modified_at` strictly advances. If the
  live-sandbox slice discovers OpenTable actually emits offset-less
  local strings (Libro-style), the contract changes: the resolver
  switches to `wallClockToUtc(restaurantTimezone)` and the parser
  must refuse a `2026-03-08T02:30:00` local instant (non-existent
  during spring-forward). That refusal path is captured by Scenario
  E's `AmbiguousTimestampConvention.refuse`.
- Adapter assertion (Phase 2): `_canonicalize` accepts;
  `reservation_at = 2026-03-08T10:30:00Z` (UTC); business_date for
  `America/New_York` resolves to `2026-03-08`. Sink assertion: row
  written with the explicit UTC instant; no DST drift.
