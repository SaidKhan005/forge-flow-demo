# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Endpoint: `GET /reservations/search` (cursor-paginated; this fixture
  also represents the shape of an inbound webhook event delivered to
  `POST /v1/webhooks/tock/{operatorId}/{locationId}` — Tock webhook
  payloads are documented as the full reservation shape, not id-only
  events; per `docs/integrations/tock/field_mapping.md` Ambiguity
  calls)
- Notes: status `SEATED` indicates the guest has arrived and been seated.
  `lastUpdatedTimestamp` advances past `createdTimestamp` because the
  status transitioned (EXPECTED → ARRIVED → SEATED). Per-status
  transition timestamps (`arrived_at`, `seated_at`, `left_at`,
  `canceled_at`) are NOT documented on the public reservation
  reference and are intentionally absent — the
  `8R.TC.live.sandbox` slice diffs observed sandbox payloads and adopts
  any per-transition timestamps as a bounded fix (not a slice rebuild).

## Sourcing context

Public reservation reference + engineering-slice fixture mirror. No
live HTTP calls.
