# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope) /
  `GET /v1/reservations/search` row shape (assumed)
- Notes: Status `completed` is the terminal lifecycle state in the
  assumed enum `{booked, seated, completed, no_show, cancelled}`
  (`docs/integrations/opentable/field_mapping.md` "Ambiguity calls"
  → `reservation.status`). `modified_at` is strictly greater than
  `reserved_at` (post-meal close), exercising the watermark advance
  path in `pollIncremental` (`mapped.vendorModifiedAt.isAfter(...)`).
- Adapter assertion (Phase 2): `_canonicalize` accepts; canonical
  fact written with `status = completed`, `vendor_modified_at =
  2026-05-07T20:48:11Z`. Watermark advances on the new
  `vendor_modified_at`.
