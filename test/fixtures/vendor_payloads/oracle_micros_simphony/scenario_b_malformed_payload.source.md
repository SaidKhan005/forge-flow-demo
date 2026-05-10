# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape — header
  missing the documented required field `lastUpdatedUTC`)
- Notes: A malformed Simphony guest-check payload — `header.lastUpdatedUTC`
  is absent. The adapter requires this field to:
    1. Populate `vendor_modified_at` (canonical fact).
    2. Compute idempotency on `(vendor_id, operator_id, vendor_entity_id,
       vendor_modified_at)`.
    3. Advance the watermark.
  Without it, the framework's malformed-payload defense (Phase 8 `8.0`
  lean cut: "Adapter framework wraps DTO parsing in try-catch and drops
  the event with a single log row") fires.
- Adapter assertion at this fixture:
  - `_mapGuestCheckToCanonical` returns a record with
    `vendor_modified_at = null`. Canonical sink upsert MUST refuse the
    write (UNIQUE on `(vendor_id, operator_id, vendor_entity_id,
    vendor_modified_at)` requires non-null components).
  - `connector_sync_log` row written with kind `parse_drop` and
    payload preview.
  - `recordsWritten` does NOT increment.
