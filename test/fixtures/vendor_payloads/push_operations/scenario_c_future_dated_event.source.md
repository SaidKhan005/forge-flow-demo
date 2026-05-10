# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/shifts
- Notes: Same shape as the documented engineering-slice fixture
  `futureDatedPushOperationsShift` in
  `test/integrations/labor/fixtures/push_operations_punches_fixture.dart`.
  All timestamps are pushed one full year into the future (2027-...)
  relative to the sprint baseline (2026-05-08). The adapter's
  poll/backfill loop calls
  `command.sanityHook(vendorEventId: ..., payload: ...,
  isDeliberateBackfill: ...)` before every canonical write; the
  framework's `VendorTimestampSanity` flags
  `shift_start > now() + 1 hour` and the hook returns `false`. The
  Phase 2A harness asserts:
  1. `sanityHook` returned `false`
  2. `_canonicalSink.upsertShift` was NOT invoked
  3. The framework wrote a `sanity_log` row + a `connector_sync_log`
     row with `event_kind = 'sanity_drop'`
  4. `pollIncremental` returned with `sanityDropped >= 1`
