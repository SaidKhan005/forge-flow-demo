# Audit — PR #840 G4 / Fix #7 admin self-service MFA + password

**Date:** 2026-05-16 · Branch `claude/fix-g4-admin-self-mfa-password` @ `06149f46` · base `master` (not stacked) · MERGEABLE/CLEAN · 6 files (new `admin_security_gateway.dart`, `my_account_admin_screen.dart`, `main_admin.dart`, `admin_routes.dart`, 2 tests).
**Independent orchestrator audit verdict: APPROVE-FOR-MERGE** — operator merge approval required (auth-critical + proxy-adjacent).

## Pattern-B (independent, all 9 CONFIRMED)
- **Step-1 verdict A correct:** `team_roles_hierarchy_console_parity_contract.md:38,208,221` maps admin OWN-user security to existing `/v1/auth/mfa/*` + `/v1/auth/password/*`; `:id/*` is for other users; "no new backend routes". Proxy resolves actor from verified bearer (`advisor_proxy.dart:10416,10937-10952`) ⇒ admin token auto-targets admin.
- **Scope:** `tool/advisor_proxy/**` untouched; exactly 6 files (admin client + gateway + tests).
- **Gateway pattern:** `HttpAdminSecurityGateway` mirrors `HttpAdminSessionsGateway`; `_resolveAdminSecurityGateway` byte-mirrors `_resolveMembersAdminGateway`; `InMemory*` demo fallback wired via `AdminConsoleServicesScope`+`admin_routes.dart`; null gateway → legacy read-only note.
- **Idempotency:** one stable `actionKey` per enroll action reused across begin+confirm retries; no G60 fresh-key bug. Recovery unauthenticated by design (matches pre-bearer proxy handler) — not a leak (only emails on-file address).
- **Proxy contracts:** gateway paths/bodies match existing handlers (`advisor_proxy.dart:7259-7265,10435,10463,10902,10974,11002`); change-password still requires current password.
- **No regression:** `AdminAuthGate`, `kAdminConsoleRoles`, MFA-fresh gates, PR #831 sessions-ledger + G5 guard all byte-unchanged; no tracker/doc edits.
- **Autostash recovery complete:** new gateway file intact, imports resolve, `git grep` shows zero orphaned refs; recovery from dangling stash `b885aef6` consistent.
- **Tests real:** 11 gateway + 5 widget tests assert enroll→confirm, change-pw, recovery, stable-key, null→read-only, fail-closed. The 3 `roles_hierarchy_sessions_admin_screen_test.dart` failures are latent on master (file not in PR scope) — not a regression.
- **Base:** master, not stacked, mergeable.

## Blockers
None.

## Nits (non-blocking, cosmetic)
1. `_send` (listFactors, a read) sends no Idempotency-Key — correct (non-mutating).
2. Path constants duplicated as string literals (lib/ cannot import tool/) — pinned by tests; pre-existing convention.
3. `_clock()` has `// ignore: unused_element` — dead helper, cosmetic.

## Disposition
APPROVE-FOR-MERGE. Held per operator instruction. Requires explicit operator merge approval (auth-critical + proxy-adjacent) — no Q-style policy decision embedded (unlike #838's Q3).
