# Source

- URL: https://platform.humanity.com/v1.0/shifts (documented in `docs/integrations/humanity/api_consumed.md`)
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/shifts
- Notes:
  - Humanity uses small numeric ids (`shifts.id`) shared by other labor vendors (e.g. 7shifts uses similar small integer ids). The risk: a Phase 8 sink that did NOT include `vendor_id` in the upsert UNIQUE would shadow-write an existing 7shifts canonical row with the Humanity row.
  - Per `docs/contracts/vendor_adapter_slice_contract.md` and the gateway contract in `humanity_labor_adapter.dart` lines 357-358 ("idempotency UNIQUE `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`"), the canonical UNIQUE INCLUDES `vendor_id`. The `humanity` namespace isolates this row.
  - Phase 2 harness setup: pre-seed the `seven_shifts` row described in `_pre_existing_canonical_row`, then run the Humanity poll using the `data[]` page above. Assertion: both rows persist; neither was overwritten.
  - The `_pre_existing_canonical_row` field is fixture metadata (not a Humanity payload) — included so the Phase 2 harness can pre-seed it without a separate fixture file.
- Outcome: adapter writes 1 new canonical fact (`vendor_id=humanity`, `vendor_entity_id=9001`); the pre-existing `vendor_id=seven_shifts, vendor_entity_id=9001` row is unaffected; total canonical rows = 2.
