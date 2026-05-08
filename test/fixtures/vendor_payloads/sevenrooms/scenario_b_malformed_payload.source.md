# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms (documented shape under negation)
- Internal contract: docs/integrations/sevenrooms/field_mapping.md (`reservations[].id` is required; `party_size` is `int`)
- Adapter contract: `_projectCanonicalRecord` in `lib/integrations/reservation/sevenrooms_reservation_adapter.dart` lines 809-866
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: any (incremental poll, export, or webhook)
- Notes: Two-fault malformed payload — `id` is missing entirely (the adapter's parse path requires `entityId is String && entityId.isNotEmpty`), and `party_size` is the string `"two"` instead of the documented int (the adapter requires `partySizeRaw is num`). Either fault alone is sufficient to drop the record; both are present so the test can assert "drop on first failed predicate" without ambiguity. Per the existing reference fixture at `test/integrations/reservation/fixtures/sevenrooms_reservations_fixture.dart` (`sevenRoomsMalformedReservation`), the parse-drop path writes one `connector_sync_log` row with `event_kind = 'parse_drop'` and no canonical fact write.
