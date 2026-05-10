# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/shifts
- Notes: Minimal payload that contains exactly the six fields the
  adapter consumes per `field_mapping.md` (`id`, `employee_id`,
  `position_name`, `start_at`, `end_at`, `updated_at`). All optional
  vendor-side fields (`position_id`, `published`, `published_at`,
  `notes`) are absent from the response. Tests that the adapter does
  not break when the vendor omits documented-but-not-consumed
  fields. Phase 2A harness asserts canonical write succeeds with
  every required field populated.
