# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Endpoint: `GET /reservations/search` (cursor-paginated)
- Notes: This payload carries ONLY the fields the canonicalization
  pipeline consumes per
  `lib/integrations/reservation/tock_reservation_adapter.dart`
  `_canonicalize`: `id`, `createdTimestamp`, `lastUpdatedTimestamp`,
  `serviceDateTimestamp`, `partySize`, `status`. The `businessId`
  field — present on every documented Tock reservation — is omitted in
  this fixture to model a "sparse" payload where the connection
  binding is resolved upstream by `WebhookBindingExtractor` (using
  `connector_connection.metadata.business_id` carried in the
  credential handle) rather than from the per-record envelope. Per
  `docs/integrations/tock/field_mapping.md`, the adapter never reads
  guest PII (`guest.firstName`, `guest.lastName`, `guest.email`,
  `guest.phone`) or `paymentInstrument` — those fields are forbidden
  at lifecycle = `documented` and excluded from every fixture.
- A "no phone" sparse variant from the format spec maps to this
  fixture: Tock does not surface `guest.phone` to F&F at all (it is
  on the forbidden list), so the absence of phone is the default
  shape, not an edge case.

## Sourcing context

Public reservation reference. The minimum-viable shape for the
adapter to produce a canonical reservation fact.
