# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms (documented timestamp shape)
- Internal contract: docs/integrations/sevenrooms/field_mapping.md "Timestamp shapes": `arrival_time` is venue-local with offset; `last_updated_at` is UTC
- Phase 7.55: `docs/contracts/phase_7_55_time_boundary_contract.md` — restaurant-local timing wins; `business_date` is computed via `IanaTimezoneConverter` against the location's IANA timezone
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: any
- Notes: Vancouver venue (`America/Vancouver`, `-07:00` PDT in May), but `last_updated_at` is the SevenRooms partner-API UTC cursor that's emitted from the vendor's primary datacenter — typically a US East Coast region, ~3 hours offset from venue-local. The fixture forces the resolver to choose: `arrival_time` = 2026-05-04T19:00:00-07:00 = 2026-05-05T02:00:00Z (Toronto-equivalent wall clock 22:00 EDT), but `last_updated_at` (vendor cursor) of 2026-05-04T20:00:00Z is the *vendor*-side modification stamp — chronologically earlier than the arrival instant, which is correct (the booking was created and last touched before the guest's arrival window). The Vancouver-local `business_date` projection: 2026-05-04T19:00:00-07:00 lands on `business_date = 2026-05-04` (rollover hour 4 AM PDT). A naive resolver that reads `last_updated_at` (UTC) and applies the venue offset would mis-classify the cursor as 2026-05-04T13:00:00 venue-local — the test asserts the resolver does NOT do this; `last_updated_at` is the canonical UTC instant unchanged. Phase 2 harness asserts: `reservation_at_utc = 2026-05-05T02:00:00Z`, `business_date = 2026-05-04`, `vendor_modified_at_utc = 2026-05-04T20:00:00Z`.
