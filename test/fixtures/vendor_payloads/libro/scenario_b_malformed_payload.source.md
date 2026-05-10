# Source

- URL: https://libroreserve.github.io/api-documentation/#operation/listReservations
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.confirmed`)
- Notes: Adversarial scenario B. The webhook envelope is valid but the
  nested `reservation` object is missing four required fields:
  `venue_id`, `size`, `reservation_at`, `updated_at`. Per
  `docs/integrations/libro/field_mapping.md` these are non-optional.
  `LibroReservationDto.fromMap` (lines 139-155 of
  `libro_reservation_adapter.dart`) uses non-null assertions on
  `venue_id`/`size`/`status` and `_parseInstant` throws
  `FormatException('libro reservation timestamp missing')` when the
  required timestamps are absent. The framework MUST surface this as a
  parse failure: no canonical write, `connector_sync_log` row with
  `event_kind='parse_error'`, no caller-visible 500.
