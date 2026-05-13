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
| `test/tool/advisor_proxy/admin_integrations_response_sanitization_test.dart` | Pre-existing `_StubHttpHeaders.forEach` shape mismatch in the dispatch wrapper sanitization test. Surfaced in PR #634 (B6 decompose) audit doc as a pre-existing failure verified on clean master, not introduced by B6. Surfaced again in wave-closeout `wave_audit_honest_disclosures.md` (U-1) and `wave_audit_test_coverage.md` (P3). | 2026-05-13 (wave closeout) | follow-up — update `_StubHttpHeaders` mock to match current `dart:io` `HttpHeaders.forEach` typedef OR widen the wrapper test |
| `test/infrastructure/persistence/postgres/repositories/weekly_plan_snapshot_repository_test.dart` | Compile error: references `PackagePostgresPool` without importing it (PR #459, pre-wave). Blocks 44 sibling tests in `test/infrastructure/persistence/postgres/repositories/` from running. Surfaced in wave-closeout `wave_audit_test_coverage.md` (P2). | 2026-05-13 (wave closeout) | follow-up — 1-line import add of `package_postgres_pool.dart` |
| `lib/operator_web/screens/permission_explainer_screen.dart` (via `test/operator_web/screens/permission_explainer_screen_test.dart`) | Wave-introduced regression: PR #481 added `team.hierarchy.suspend` to `lib/auth/permission_keys.dart` without adding the matching entry to `permission_explainer_screen.dart`'s `permissionKeyDescriptions` map. CI dark until 2026-06-01 let it through. Tracked in C-12 closeout as Finding B-2. | 2026-05-13 (wave closeout) | follow-up B-2-fix — add the missing `permissionKeyDescriptions['team.hierarchy.suspend'] = …` entry. ~3-5 LoC |
