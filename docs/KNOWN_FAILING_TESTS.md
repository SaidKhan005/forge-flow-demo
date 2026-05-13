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
| `test/pressure/p3c_oauth_refresh_storm_runner_test.dart` | Two assertions in the "Closure registry coverage" group drift from production: (a) `oauth-flavored vendors NOT in the worker registry` expects `containsAll(['agendrix', 'opentable', 'adp', 'sevenrooms'])` but the registry has been pared back to `['sevenrooms', 'agendrix']` only; (b) `worker registry wires exactly the 11 expected OAuth vendors` expects `hasLength(10)` but the wired set is now `hasLength(12)`. Pre-existing on clean master at the 2026-05-12 A10.1 consolidation pass; reproduced before the consolidation. The other 5 group cases pass. | 2026-05-12 | follow-up — re-pin the assertions against the current `buildProductionRefreshClosures` + `kVendorsWithoutRefreshClosure` constants, or split into a generated reconciliation finding |
