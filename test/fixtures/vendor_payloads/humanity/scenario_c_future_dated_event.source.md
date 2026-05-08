# Source

- URL: https://platform.humanity.com/v1.0/shifts (documented in `docs/integrations/humanity/api_consumed.md`)
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/shifts
- Notes:
  - Mirrors the existing `humanityFutureDatedShift` constant in `test/integrations/labor/fixtures/humanity_punches_fixture.dart` lines 130-139 (id "HUM-9999", reads as 60+ days into the future relative to the adapter test harness's `nowFixed`).
  - Future-dated rows ARE valid Humanity v1 shapes — the vendor allows scheduling shifts well in advance. The reject is enforced by the framework's vendor-timestamp sanity guard (rule: `opened_in_future`), not by `HumanityShiftDto.tryFromMap` which parses the row cleanly.
  - The sanity hook is invoked from `humanity_labor_adapter.dart` lines 630-642 (backfill) and lines 712-723 (pollIncremental); a `passed=false` return from the hook causes the adapter to skip the canonical write while leaving sanity_log + connector_sync_log unmodified by the adapter (the hook owns those writes).
- Outcome: adapter parses the row but `command.sanityHook(...)` returns false → no canonical write; sanity_log row is recorded by the framework; watermark advances per the page.
