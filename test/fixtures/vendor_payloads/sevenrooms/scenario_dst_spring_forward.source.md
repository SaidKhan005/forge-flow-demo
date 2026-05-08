# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms (documented timestamp shape: ISO-8601 with offset)
- Internal contract: docs/integrations/sevenrooms/field_mapping.md "Timestamp shapes" — `arrival_time` is venue-local with offset
- Phase 7.55: `docs/contracts/phase_7_55_time_boundary_contract.md` — restaurant-local timing wins; business date is the anchor
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: any
- Notes: 2026-03-08 is US/Canada spring-forward day. In `America/Toronto`, the wall-clock 02:00–02:59 does not exist — clocks jump from 01:59 EST (`-05:00`) to 03:00 EDT (`-04:00`). The fixture's `arrival_time` `2026-03-08T03:30:00-04:00` is post-jump (03:30 EDT, the first valid wall-clock half-hour after the spring-forward). The corresponding UTC instant is 2026-03-08T07:30:00.000Z, which the adapter's `DateTime.tryParse(...)?.toUtc()` resolves correctly via the explicit `-04:00` offset. The IANA business-date projection (rollover hour 4 AM local for the test suite default) places this reservation on `business_date = 2026-03-08`. Phase 2 harness asserts: canonical `reservation_at_utc = 2026-03-08T07:30:00.000Z`, `business_date = 2026-03-08`, no DST-related parse failures. Counterpoint shape that MUST reject: `2026-03-08T02:30:00-05:00` (a wall-clock that does not exist) — that is the negative space this fixture's positive case is paired against.
