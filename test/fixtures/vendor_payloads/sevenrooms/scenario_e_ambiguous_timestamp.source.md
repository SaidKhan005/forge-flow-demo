# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms (documented shape under negation — adapter requires ISO-8601 with offset)
- Internal contract: docs/integrations/sevenrooms/field_mapping.md "Timestamp shapes" — `arrival_time` is documented as ISO 8601 with offset (venue-local); `vendor_timestamp_policy.sevenrooms.asUtc` parses offset → UTC
- Adapter contract: `_projectCanonicalRecord` lines 821-822 of `sevenrooms_reservation_adapter.dart`: `DateTime.tryParse(reservationAtRaw)?.toUtc()` returns null for naive timestamps without offset on this Dart shape
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: any
- Notes: Two ambiguity faults compound here: (1) the timestamp uses a `space` separator instead of `T` and carries no offset / `Z` suffix — neither UTC nor venue-local can be unambiguously resolved; (2) the wall-clock value `2026-11-01 01:30:00` falls inside the US/Canada DST fall-back ambiguous hour (01:00–02:00 happens twice on 2026-11-01 in `America/Toronto`, once at offset `-04:00` and again at offset `-05:00`), so even if the adapter inferred venue-local time, the IANA resolver could not pick a unique instant. Per `field_mapping.md`, the framework's `AmbiguousTimestampConvention.asUtc` declaration explicitly disallows silent coercion to venue-local — the adapter must reject. The adapter's `_projectCanonicalRecord` returns null on the parse-failure branch (line 822: `if (reservationAt == null) return null;`); the framework's `connector_sync_log` records `event_kind = 'parse_drop'` and no canonical fact is written.
