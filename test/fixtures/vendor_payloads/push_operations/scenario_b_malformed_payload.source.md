# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/shifts (corrupt response)
- Notes: Per `field_mapping.md` Push Operations documents
  `shifts[].id` as `int (stringified at canonical write)` and the
  three timestamp fields as ISO 8601 with explicit `Z`. This fixture
  violates the documented shape on every documented field path:
  - `shifts[0].id` is a non-numeric string
  - `shifts[0].end_at` is unparseable
  - `shifts[0].updated_at` is null
  - `shifts[0]` is missing `employee_id`
  - `shifts[1].employee_id` is null
  - `shifts[1].position_name` is an int (wrong type)
  - `shifts[1]` is missing `updated_at`
  - The pagination envelope is corrupt (`page = "one"`,
    `limit = -1`, `total = "?"`)

  The adapter's `_mapShiftToCanonical` calls
  `DateTime.parse(...)` on the timestamp fields; a malformed string
  throws `FormatException`. The Phase 2A harness asserts the
  adapter raises a `PayloadParseError` (per the binding A-F set) and
  no canonical write occurs. The pagination envelope corruption
  also exercises the page-cursor parser.
