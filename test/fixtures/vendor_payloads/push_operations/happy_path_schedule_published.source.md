# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/shifts
- Notes: Mirrors the documented `shifts[]` field paths from
  `docs/integrations/push_operations/field_mapping.md` (retrieved
  2026-05-04). Field paths captured: `shifts[].id`,
  `shifts[].employee_id`, `shifts[].position_name`,
  `shifts[].start_at`, `shifts[].end_at`, `shifts[].updated_at`. The
  adapter at `lib/integrations/labor/push_operations_labor_adapter.dart`
  consumes exactly these fields via `_mapShiftToCanonical`. The
  `position_id`, `published`, `published_at`, and `notes` fields are
  documented as present in the response but ignored by the adapter
  (see `field_mapping.md` "Forbidden fields" — `notes` is retained on
  `raw_payload` but not promoted to a canonical column). Pagination
  envelope (`page` / `limit` / `total`) per
  `api_consumed.md` "Pagination shape" row for `/shifts`.
