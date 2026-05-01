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
| `test/phase_9_0sigma_f_audit_chain_e2e_test.dart` | New `audit_logs receives auth-event family` group fails by design pending B.2 (auth-event fan-out into hash-chained `audit_logs`). Two boundaries are exercised — B.2 must close BOTH or production traffic stays uncovered: (1) the **repository boundary** — login, MFA enroll, and password change drive the real `AuthEventsAuditRepository.insertEvent` (the seam every user-facing auth gateway shares); (2) the **B41 gateway boundary** — the service-principal token-issue scenario drives the real `PostgresServicePrincipalJwtIssuanceGateway.issue(...)`, which writes `insert into public.auth_events_audit` directly via raw SQL through `PostgresExecutor` (NOT through the repository). A recording pool watches for `insert into audit_logs`. Today neither boundary fans out, so the chain store stays empty and every scenario surfaces the missing wire-up. Closes when B.2 hooks both. | 2026-04-30 | B.2 |
