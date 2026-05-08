# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#timesheets
- Companion vendor doc:
  https://developer.7shifts.com/ (7shifts time-clock IDs are also small
  integers; collisions inevitable across vendors)
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: GET https://rest.tsheets.com/api/v1/timesheets (this vendor)
- Notes: QuickBooks Time `timesheets[].id` is a small monotonic integer
  in the documented shape (e.g., the punches fixture file uses ids in
  the 901000 range — see
  `test/integrations/labor/fixtures/quickbooks_time_punches_fixture.dart`).
  All other labor vendors in the F&F roster (7shifts, ADP, Humanity,
  Agendrix, Push Operations) emit similarly-small integer ids in their
  documented shapes, so an operator running two labor vendors during a
  migration window will hit numeric-id collisions immediately. The
  framework's idempotency UNIQUE on the canonical fact table is
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)` — the
  leading `vendor_id` column is the namespace defense. The Phase 2
  adapter harness must assert that injecting both this fixture and a
  matching 7shifts fixture with the same numeric id results in TWO
  canonical fact rows (not a shadow-overwrite).
