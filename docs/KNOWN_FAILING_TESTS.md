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
| `test/advisor_proxy_test.dart` | Windows checkout CRLF flake in the Phase 9 auth schema foundation group. Confirmed pre-existing on clean HEAD: `legacy users.role column is migrated into user_roles and dropped` and sibling SQL-shape assertions compare LF-only substrings against CRLF migration content. Not a B33 regression. | 2026-04-29 | test hygiene |
