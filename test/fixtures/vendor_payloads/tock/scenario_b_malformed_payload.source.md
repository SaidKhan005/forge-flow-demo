# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Endpoint: webhook delivery (or `GET /reservations/search` malformed
  page item)
- Notes: Two type / format violations against the documented Tock
  reservation schema:
  1. `lastUpdatedTimestamp` is `"not-a-real-timestamp"` instead of an
     ISO-8601 UTC string with trailing `Z`.
  2. `partySize` is the string `"four"` instead of an int.
  The Phase 2 adapter harness asserts the parser rejects (or the sink
  rejects on type mismatch); either way no canonical fact is written.

## Sourcing context

Public reservation reference (documents both fields' types). No live
HTTP calls.
