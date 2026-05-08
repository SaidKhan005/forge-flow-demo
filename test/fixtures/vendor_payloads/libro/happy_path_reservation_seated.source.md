# Source

- URL: https://libroreserve.github.io/api-documentation/#section/Webhooks
- URL: https://libroreserve.github.io/api-documentation/#operation/listReservations
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.seated`)
- Notes: Carries the full status-transition timeline per Libro v1 field
  mapping (`created_at`, `confirmed_at`, `arrived_at`, `seated_at`).
  Adapter materializes each into `status_transitions.<state>` after the
  IANA wall-clock-to-UTC projection. Status `seated` normalizes to
  `CanonicalReservationStatus.seated`. Subscribed event verified in
  `kLibroSubscribedEvents` in `lib/integrations/reservation/libro_reservation_adapter.dart`.
