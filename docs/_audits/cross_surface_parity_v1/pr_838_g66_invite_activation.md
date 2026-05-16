# Audit — PR #838 G66 invite-activation decorator (server-slice S1)

**Date:** 2026-05-16 · Branch `claude/g66-invited-user-activation-wiring` · base `master` (`19eed29d`, ancestor, not stacked) · MERGEABLE · 4 files (decorator, bootstrap, 2 tests).
**Independent orchestrator audit verdict: APPROVE-FOR-MERGE** — subject to mandatory explicit operator sign-off (auth-critical + proxy-touching; Q3 markers flag it).

## Pattern-B (independent, all CONFIRMED)
| Claim | Evidence |
|---|---|
| Bare `RepositoryAuthSessionLedgerWriter` now wrapped by `InvitedUserActivationLedgerWriter` at the production `authSessionLedgerWriter:` site | `proxy_bootstrap.dart:1308-1314`; delegate preserved |
| `InvitedUserActivationRepository(tenantWrapper)` uses the SAME `TenantTransactionWrapper` as sibling repos (`UsersRepository`/`AuthSessionsRepository`) | `proxy_bootstrap.dart:1313` vs `:800,821,868`; ctor matches `OperatorScopedRepository` positional arg |
| Q3 = catch `StateError` SPECIFICALLY → structured `warning` `auth.invite_activation.skipped` → continue to delegate (login succeeds) | `invited_user_activation_ledger_writer.dart:60-75` (narrow `on StateError catch`, no bare/Exception catch) |
| Genuine infra exception (non-StateError) propagates uncaught ⇒ login fails closed, no session row | `invited_user_activation_ledger_writer.dart:59-75`; repo throws `StateError` only for 4 data-integrity edges |
| Q3 operator-decision markers present | `invited_user_activation_ledger_writer.dart:44-45`; `proxy_bootstrap.dart:1297-1298` |
| Idempotent second login = no-op (repo `.skipped()` when status≠invited) | `invited_user_activation_repository.dart:55,62-65` |
| Single shared proxy path ⇒ fixes mobile AND operator-web; no surface branching | `proxy_bootstrap.dart:1305-1314`; zero conditionals in decorator |
| No scope creep: 4 files only; no magic-link/ToS/tracker/contract/CLAUDE.md edits; pass-through `recordRefresh`/`revoke*` | `git diff --stat`; decorator `:77-130` |
| Injectable `logger` defaults to real `log()`; prod passes nothing | `invited_user_activation_ledger_writer.dart:22-37`; `proxy_bootstrap.dart:1311-1313` |
| 5 new decorator tests + inverted bootstrap assertion genuinely assert (invited→active ordering, idempotent, StateError→succeeds+logged, infra→fails closed) | `test/services/auth/invited_user_activation_ledger_writer_test.dart:38-138`; `test/advisor_proxy_bootstrap_test.dart:188-191` |
| Base==master, not stacked, mergeable | merge-base ancestor true |

## Q3 vs operator-decided default
**Matches exactly:** narrow `StateError` catch → observable warning (never silent) → login continues; infra failures propagate/fail-closed. Still requires explicit operator sign-off at merge (auth-critical + proxy-touching gate; the in-code markers exist for this).

## Blockers
None.

## Nits (non-blocking)
1. Code comments reference `onboarding_server_slice_spec.md` which is an orchestrator-local uncommitted doc → dead pointer post-merge. Recommend committing the audit/spec docs OR trimming to just the `G66/Q3` marker. (Orchestrator note: audit docs in `docs/_audits/cross_surface_parity_v1/` are currently uncommitted coordination artifacts.)
2. Decorator logs `error.message` only, not the `StackTrace`. Acceptable for a by-design fail-open warning; a `StackTrace` field would aid forensics if these spike. Optional.

## Disposition
APPROVE-FOR-MERGE. Held per operator instruction ("wait for everything to land; audit as they come in"). Needs at merge: explicit operator Q3 sign-off ("data-integrity glitch → log + let login succeed; real DB failure → fail closed"). No code changes required to merge.
