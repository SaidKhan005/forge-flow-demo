# Source

- URL: https://platform.humanity.com/v1.0/shifts (documented in `docs/integrations/humanity/api_consumed.md`)
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/shifts
- Notes:
  - Two distinct malformations in one page so the adapter loop exercises both rejection branches:
    - Row 1 is missing `in_time` and `out_time` entirely → `tryFromMap` returns null at the `inRaw is! String` guard (humanity_labor_adapter.dart line 202).
    - Row 2 has `out_time` typed as integer (epoch seconds) instead of an ISO 8601 string → same guard rejects.
  - Per V1 lean cut 2: no `parse_warnings` / `parse_partial` channel. Adapter either writes a clean canonical fact or refuses; the rows are dropped silently and `recordsWritten` does not increment.
  - The malformed-payload counter on `connector_sync_log` should still advance so the field-mapping diff in `*.live.sandbox` can flag the upstream regression. Adapter never reaches `_gateway.writeShiftFact`.
- Outcome: adapter drops both rows; no canonical write; watermark still advances on `last_modified_seen` (per-page commit).
