# Known Failing Tests

Quarantine list for tests known to be red on `master` that are out of scope
for the current slice.

Read this before claiming a regression: a failure here is pre-existing and
does not block the current slice unless the slice explicitly names it.

Codex maintains this file. Add an entry when verification confirms a failure
is pre-existing on clean HEAD. Remove an entry once the failure is fixed.
Removed entries live in git history; do not keep a "resolved" section here.

## Open

| File | Notes | Discovered | Owning slice |
|------|-------|------------|--------------|
| `test/labor_model_boh_sales_test.dart` | 2 failing cases | 2026-04-24 | tbd |
