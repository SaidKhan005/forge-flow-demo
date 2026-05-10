# Source

- URL: https://platform.humanity.com/v1.0/shifts (documented in `docs/integrations/humanity/api_consumed.md`)
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/shifts
- Notes:
  - Humanity's documented v1 response shape always carries trailing `Z` (UTC) on `in_time`/`out_time`/`updated` per `field_mapping.md` "Timestamp shapes" table.
  - Two documented-shape regressions captured here:
    - Row 1 uses `YYYY-MM-DD HH:MM:SS` (space separator, no timezone) — the vendor doc convention requires `T` and `Z`. `DateTime.tryParse('2026-05-01 16:00:00')` returns a Dart-local DateTime; calling `.toUtc()` converts from local time, which silently mis-attributes business_date.
    - Row 2 uses `YYYY-MM-DDTHH:MM:SS` (no `Z`) AND falls inside the DST spring-forward window (2026-03-08 02:30 local, which in US Eastern does NOT exist). Naively parsing without timezone information produces an ambiguous result.
  - Per `humanityTimestampPolicy.asUtc` (humanity_labor_adapter.dart lines 140-149): "the policy stays declarative as `asUtc` so a future API change that drops `Z` does not silently break business-date bucketing." `field_mapping.md` notes that for vendors with policy `refuse`, scenario E rejects ambiguous timestamps. Humanity declares `asUtc`, but the adapter's parser DOES reject naive timestamps in practice because `DateTime.tryParse` returns local-zoned DateTime and the row fails downstream invariants.
  - The CORRECT future fix path (out of Phase 1 scope): Humanity adapter should explicitly reject any timestamp without an explicit `Z` rather than implicitly best-effort.
- Outcome: adapter parses naively, but downstream invariant checks (closes-after-open after `.toUtc()` conversion may flip when local-time interpretation crosses DST) catch the regression. Phase 2 harness asserts: "no canonical write for either row from this fixture."
