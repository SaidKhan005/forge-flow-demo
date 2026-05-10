# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope)
- Notes: `cancelled` matches the assumed enum vocabulary
  (`docs/integrations/opentable/field_mapping.md` "Ambiguity calls").
  The adapter normalizes via `statusRaw.toLowerCase()` so any of
  `Cancelled` / `CANCELLED` / `cancelled` would canonicalize to the
  same string. The Tock and SevenRooms adapters use `canceled` (US
  spelling) in their docs; OpenTable's exact spelling is partnership-
  gated and verified in `8R.OT.live.sandbox`.
- Adapter assertion (Phase 2): `_canonicalize` accepts; canonical
  fact written with `status = cancelled`. Sink assertion: vendor
  cancellation does not delete the prior booked-state fact —
  idempotency upsert on `(vendor_id, operator_id, vendor_entity_id,
  vendor_modified_at)` writes a new row with the post-cancellation
  `vendor_modified_at`.
