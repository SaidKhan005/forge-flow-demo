# Source

- URL: https://libroreserve.github.io/api-documentation/#section/Webhooks
- URL: https://libroreserve.github.io/api-documentation/#operation/listReservations
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.completed`)
- Notes: Same `reservation.id` as the `seated` fixture so the harness
  can verify idempotent UPSERT behavior driven by the partial UNIQUE on
  `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)` in
  `reservation_facts`. The status transition `completed_at` is the
  party-left timestamp; `updated_at` is bumped to the same instant.
  Status `completed` normalizes to
  `CanonicalReservationStatus.completed`. Vendor docs treat
  `completed` and `left` as equivalent (see ambiguity calls in
  `docs/integrations/libro/field_mapping.md`).
