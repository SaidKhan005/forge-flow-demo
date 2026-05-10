# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms (documented shape, future timestamp)
- Internal contract: existing reference fixture `sevenRoomsFutureDatedReservation` at `test/integrations/reservation/fixtures/sevenrooms_reservations_fixture.dart`
- Sanity rule reference: integration sanity hook `reservation_in_future` (Phase 8R framework)
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: any (incremental poll, export, or webhook)
- Notes: Reservation with `arrival_time` set to 2099-12-31 — well past any reasonable booking horizon. The shape is fully valid SevenRooms partner-API JSON (parses cleanly through `_projectCanonicalRecord`), so the boundary-parse stage accepts it. The timestamp guard fires inside the framework's `sanityHook` (rule 2: `reservation_in_future`) — `pollIncremental` short-circuits with `sanityDropped += 1`, no `connector_reservation_fact` row is written. Note: `arrival_time` MUST be parseable; the fixture uses a 2099 future date with a valid offset (`-05:00`) so the parse path is exercised end-to-end before the sanity guard rejects.
