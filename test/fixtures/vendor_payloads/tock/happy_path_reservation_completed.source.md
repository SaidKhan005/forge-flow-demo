# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Endpoint: `GET /reservations/search` (cursor-paginated)
- Notes: status `LEFT` is Tock's documented "guest has finished and
  departed" terminal state — the analog to a POS shift's "completed"
  reservation. Adapter `_canonicalize` normalizes `LEFT` (uppercase) to
  the canonical `left` (lower-snake-case) per
  `kTockCanonicalStatusString` in
  `lib/integrations/reservation/tock_reservation_adapter.dart`. The
  `lastUpdatedTimestamp` lands ~2h47m after `serviceDateTimestamp`
  (typical seated-to-departed dwell for a party of six).

## Sourcing context

Public reservation reference + engineering-slice fixture mirror
(`tockBackfillPage1Reservations()` `p1-res-003` carries the same
LEFT-status shape). No live HTTP calls.
