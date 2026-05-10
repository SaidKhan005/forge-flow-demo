# Source

- URL: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (response shape —
  guest check with future-dated `opnUTC` / `cmplOrClsdUTC`)
- Notes: A guest check whose timestamps are dated 2027-05-02 — about
  one year in the future relative to today (2026-05-08). The framework's
  `vendor_timestamp_sanity` guard (`8.0` lean cut) enforces:
    `opened_at <= now() + 1 hour`
  This shape mirrors the existing in-repo
  `futureDatedSimphonyGuestCheck` constant at
  `test/integrations/pos/fixtures/oracle_micros_simphony_checks_fixture.dart:96-104`.
- Adapter assertion at this fixture:
  - The framework binds a `sanityHook` callback on the
    `BackfillCommand` / `PollIncrementalCommand` per
    `vendor_adapter_slice_contract.md`. The adapter calls
    `command.sanityHook(...)` before each canonical write.
  - The hook returns `false` for this record (opened_at far future).
  - The adapter MUST skip the canonical fact write and increment
    `sanityDropped` on the `PollIncrementalResult`.
  - `sanity_log` row written with rule `opened_in_future`.
  - `recordsWritten` does NOT increment.
- Sanity-hook contract enforcement verified by the framework's
  `sanity_hook_call_lint.dart` per per_vendor_doc_pack_contract.md.
