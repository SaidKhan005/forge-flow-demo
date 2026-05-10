# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope)
- Notes: Sparse-path payload omits `modified_at` (which the field-
  mapping doc lists as "When absent, the canonicalizer falls back to
  `reservation.reserved_at` so the watermark advances. Verify
  presence + format" under "Ambiguity calls"). The adapter's
  `_canonicalize` already implements the fallback at line 920-925 of
  `lib/integrations/reservation/opentable_reservation_adapter.dart`.
  Also no guest block, no notes, no special_requests — the minimum
  set of required fields per
  `documentedPerOpentableV1FieldMapping`.
- Adapter assertion (Phase 2): `_canonicalize` accepts;
  `vendor_modified_at == reservation_at` (fallback path);
  `party_size = 2`, `status = booked`. Sink assertion: row written
  with `vendor_modified_at` equal to `reservation_at`. Watermark
  advances on this fallback timestamp; the live slice will verify
  whether OpenTable always emits `modified_at` (in which case the
  fallback never fires in practice).
