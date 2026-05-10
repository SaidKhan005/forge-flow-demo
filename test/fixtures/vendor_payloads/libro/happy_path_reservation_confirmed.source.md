# Source

- URL: https://libroreserve.github.io/api-documentation/#section/Webhooks
- URL: https://libroreserve.github.io/api-documentation/#operation/listReservations
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.confirmed`)
- Notes: Webhook envelope shape (`id`, `type`, `venue_id`, `occurred_at`,
  `reservation`) per `docs/integrations/libro/webhook_signature.md`.
  The nested `reservation` object mirrors the `GET /v1/reservations`
  row shape per `docs/integrations/libro/field_mapping.md`. Adapter
  drops `notes` and `guest_*` fields per the field-mapping "Forbidden
  fields" section (privacy / scope). Status `confirmed` normalizes to
  `CanonicalReservationStatus.confirmed`.
