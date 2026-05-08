# Source

- URL: https://libroreserve.github.io/api-documentation/#operation/listReservations
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.created`)
- Notes: Sparse-contact scenario — guest contact missing (`guest_phone`
  null). Libro's vendor docs note that sandbox does not always emit
  every contact field (per `docs/integrations/libro/api_consumed.md`
  "Known limitations"). The adapter ignores all `guest_*` fields per
  the forbidden-fields rule in
  `docs/integrations/libro/field_mapping.md`, so this scenario MUST NOT
  cause a parse failure or a sanity drop — the canonical fact is
  written normally with `party_size = 3`. Status `pending` normalizes
  to `CanonicalReservationStatus.expected`.
