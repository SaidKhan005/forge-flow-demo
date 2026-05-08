# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/labour (poll-incremental — same `id` as
  `happy_path_punch_clock_out.json` but with a strictly-newer
  `updated_at` after a manager edit)
- Notes: Tests the adapter's idempotency-on-update path. The
  canonical UNIQUE is `(vendor_id, operator_id, vendor_entity_id,
  vendor_modified_at)`; this payload shares the same vendor
  `id = 700401` as the clock-out fixture but advances `updated_at`
  to a later instant, so the canonical sink should upsert (not
  duplicate). Edit metadata (`edited_by_user_id`, `edit_reason`) is
  documented as present on edited entries; the adapter retains it on
  `raw_payload` only (see `field_mapping.md` "Forbidden fields").
  `clocked_in_at` was bumped from `16:00:00` to `16:05:00` and
  `hours` recomputed from 7.07 to 6.92, mirroring the documented
  manager-edit shape.
