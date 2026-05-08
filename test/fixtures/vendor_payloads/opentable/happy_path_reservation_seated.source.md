# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope)
- Notes: Status `seated` is one of the five lower-case enum values
  the adapter recognizes per
  `documentedPerOpentableV1FieldMapping['status']` (`{booked, seated,
  completed, no_show, cancelled}`). The payload also includes the
  forbidden `guest` block (name, email, phone) so Phase 2 harnesses
  can assert the canonicalizer drops PII before persistence — the
  forbidden field paths are pinned in
  `lib/integrations/reservation/opentable_reservation_adapter.dart`
  (`forbidden_guest_email_path`, `forbidden_guest_name_path`,
  `forbidden_guest_phone_path`) and the field-mapping doc's "Forbidden
  fields" section. Source URL lists the operator-facing platform page
  only; the partner reference confirming the exact `seated` enum
  string lands in `8R.OT.live.sandbox`.
- Adapter assertion (Phase 2): `_canonicalize` accepts; canonical
  fact written with `status = seated`. Sink assertion: persisted row
  contains no guest fields (`guest.*` absent in `rawPayload` writes
  to forbidden tables).
