# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope)
- Notes: Adversarial scenario B exercises the
  `OpenTableReservationAdapter._canonicalize` reject path. The
  fixture violates three contract rows from
  `documentedPerOpentableV1FieldMapping` simultaneously: (1)
  `party_size` MUST be `int` (canonicalizer guards `partySizeRaw is!
  num` at line 928); (2) `reserved_at` MUST be ISO-8601 (`DateTime.tryParse`
  returns null for non-ISO formats at line 917); (3) `status` MUST be
  a non-empty string (line 933). Any single one of these would force
  `_canonicalize` to return null. The fixture combines all three so
  Phase 2 harness asserts the rejection is robust under multiple
  simultaneous violations.
- Adapter assertion (Phase 2): `_canonicalize` returns null;
  `handleWebhook` returns `HandleWebhookResult(recordsWritten: 0)`.
  Sink assertion: no row written to `reservation_facts`. Framework
  emits `connector_sync_log` row at the dispatch unwind path per the
  in-line comment in `handleWebhook`.
