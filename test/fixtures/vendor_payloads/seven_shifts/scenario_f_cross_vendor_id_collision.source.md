# Source

- URL: https://developers.7shifts.com/reference/listtimepunches
- URL (idempotency contract):
  `docs/contracts/vendor_adapter_slice_contract.md`
  ("idempotency UNIQUE on `(vendor_id, operator_id, vendor_entity_id,
  vendor_modified_at)`")
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: documented `time_punch.edited` envelope where the
  `time_punch.id` (712001) coincides with a previously-written
  QuickBooks Time time-clock entity id under the same operator
- Notes: adversarial Scenario F. 7shifts and QuickBooks Time are
  both labor vendors with separate id namespaces; a numeric
  collision is plausible because both vendors expose integer ids.
  The framework's idempotency UNIQUE includes `vendor_id`, so the
  7shifts row inserts as a NEW canonical fact even though the bare
  numeric id matches a row stored under `vendor_id='quickbooks_time'`.
  Sink-side test asserts no shadow-write of the existing QuickBooks
  row. The `_fixture_envelope.shadow_write_pre_existing` block is
  the data the harness pre-loads into the sink before invoking the
  adapter on the 7shifts payload.
