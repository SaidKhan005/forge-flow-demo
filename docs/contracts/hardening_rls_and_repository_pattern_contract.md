# Hardening — RLS & Repository Pattern Contract

Updated: 2026-05-02
Owner: HARD-F (data + RLS sprint)
Status: Active authority

## Why This Exists

Two defense-in-depth gaps remain after Phase 9 closeout: (1) the legacy
auth RLS policies in `db/migrations/202604260000_auth_rls_per_tenant_policies.sql`
still call `current_setting('app.operator_id', true)::uuid` inline, which
breaks planner pushdown — the wrapper functions from
`202604280000_phase_9_0sigma_b_rls_wrappers.sql` were never adopted
across auth tables; (2) 13 service files under `lib/services/auth/`,
`lib/services/mfa/`, and `lib/services/rollups/` import `package:postgres`
directly, bypassing the repository pattern that CLAUDE.md mandates as
the primary defense (RLS is the secondary).

Handoff between:

- `db/migrations/` — new policy migration on auth tables.
- `tool/rls_policy_lint.dart` — extend lint to forbid bare `current_setting`.
- `tool/postgres_import_lint.dart` — already exists; ensure it covers
  service layer.
- `lib/infrastructure/persistence/postgres/` — new auth/MFA/rollup
  repositories.
- `lib/services/auth/`, `lib/services/mfa/`, `lib/services/rollups/` —
  rewire callers.

Disagreement rule: this contract wins for wrapper-function adoption and
import-path discipline. CLAUDE.md "RLS UUID wrappers (item 4)" and
"Repository pattern (decided 2026-04-25)" are the originating guardrails
this contract enforces.

## In Scope

| Item | In | Out |
|------|-----|-----|
| Migrate auth RLS policies to wrapper functions | yes | rewriting wrapper definitions (frozen since 9.0Σ.b) |
| Lint: forbid bare `current_setting('app.*')` in policy bodies | yes | linting non-policy SQL |
| Extract auth/MFA/rollup repositories | yes | logic changes inside the queries |
| Rewire service-layer callers to use repositories | yes | renaming public APIs |
| Confirm `postgres_import_lint` covers `lib/services/` | yes | extending to `tool/` |

Out of scope: rewriting the wrapper functions themselves; redesigning
RLS policy semantics; migrating `auth_events_audit` to `audit_logs`
(Phase 11B / 9.8).

## Required — Auth RLS Wrapper Migration

New migration: `db/migrations/<timestamp>_hardening_auth_rls_to_wrappers.sql`.

For every `CREATE POLICY` in `202604260000_auth_rls_per_tenant_policies.sql`
that calls bare `current_setting('app.operator_id', true)::uuid` or
`current_setting('app.user_id', true)::uuid`, the new migration must:

1. `DROP POLICY <name> ON <table>;`
2. `CREATE POLICY <name> ON <table> ... USING (...) WITH CHECK (...);`
   using the wrapper functions from
   `202604280000_phase_9_0sigma_b_rls_wrappers.sql`:
   - `app_current_operator()` — replaces `current_setting('app.operator_id', true)::uuid`
   - `app_current_user()` — replaces `current_setting('app.user_id', true)::uuid`
   - (others as already defined)

Tables affected (verify by inspecting `202604260000`): minimally
`auth_sessions`, `auth_events_audit`, `mfa_factors`, `mfa_recovery_codes`,
`mfa_removal_requests`. Confirm the full list in the migration prelude
comment.

Migration is idempotent (uses `DROP POLICY IF EXISTS`, then `CREATE`).
RLS remains `enabled` on each affected table throughout — policies are
swapped, not disabled.

## Required — RLS Lint Extension

`tool/rls_policy_lint.dart` must add a rule:

- Scan every `db/migrations/*.sql` file for `CREATE POLICY` blocks.
- For each policy body (USING / WITH CHECK clauses), forbid any literal
  match of `current_setting('app.` (case-insensitive).
- Allowed: calls to `app_current_operator()`, `app_current_user()`,
  `app_current_location()`, `app_current_actor_kind()`.
- Error message: `RLS policy must call wrapper function, not bare current_setting (file:line)`.

The lint runs in CI (already wired). Failure blocks the build.

## Required — Repository Extraction

For each of these 13 source files, raw `import 'package:postgres'` MUST be
removed and replaced with a repository call:

```
lib/services/auth/gdpr_erasure_service.dart
lib/services/auth/invited_user_activation_ledger_writer.dart
lib/services/auth/password_reset_confirm_gateway.dart
lib/services/auth/password_reset_request_gateway.dart
lib/services/auth/repository_account_info_gateway.dart
lib/services/auth/repository_auth_operations_gateway.dart
lib/services/auth/repository_auth_session_ledger_writer.dart
lib/services/auth/repository_password_change_gateway.dart
lib/services/auth/repository_password_history_check.dart
lib/services/mfa/mfa_operations_gateway.dart
lib/services/mfa/mfa_recovery_request_gateway.dart
lib/services/mfa/mfa_removal_worker.dart
lib/services/rollups/rollup_models.dart
lib/services/rollups/rollup_worker.dart
```

New repositories under `lib/infrastructure/persistence/postgres/`:

- `auth_session_repository.dart` (wraps session writes/reads)
- `auth_event_audit_repository.dart` (already exists per Phase 9; verify and reuse)
- `password_reset_repository.dart`
- `password_history_repository.dart`
- `gdpr_erasure_repository.dart`
- `invited_user_activation_repository.dart`
- `mfa_factor_repository.dart`
- `mfa_recovery_repository.dart`
- `mfa_removal_repository.dart`
- `rollup_repository.dart`

Each repository:

- Extends `OperatorScopedRepository<T>` (or system-scope variant for
  `gdpr_erasure_repository.dart` if inherently cross-tenant).
- Receives a `TenantTransactionWrapper`.
- Imports `package:postgres` (allowed in this directory).
- Exposes only domain-shaped methods; no `Connection` or `Statement`
  surfaces leak across the boundary.
- Sets `app.operator_id`, `app.location_id`, `app.user_id` via `SET LOCAL`
  in the transaction prelude.

Service-layer callers swap raw SQL execution for repository method calls.
Behavior is preserved — same result for same input.

## Required — Lint Coverage

`tool/postgres_import_lint.dart` (existing) must report violations for
imports of `package:postgres` anywhere outside:

- `lib/infrastructure/persistence/postgres/`
- `tool/advisor_proxy/`
- `test/`

If the lint already covers this surface, this contract item is a
verification-only acceptance check.

## Out of Scope

- Migrating `auth_events_audit` writers to `audit_logs` (Phase 11B / 9.8).
- Rewriting the wrapper functions themselves.
- Adding RLS to tables that don't already have it.
- Repository pattern for non-auth/MFA/rollup services that already
  comply.

## Test Surface

- `db/migrations/<timestamp>_hardening_auth_rls_to_wrappers.sql` applied
  to fresh test DB; existing policy-coverage test
  (`test/phase_9_0sigma_rls_isolation_sweep_test.dart`) still passes —
  asserting wrapper adoption did not break tenant isolation.
- New test
  `test/phase_9_0sigma_b_rls_wrapper_lint_test.dart` (or extension to
  existing) asserts the lint catches a synthetic bare-`current_setting`
  policy body.
- `Grep "import 'package:postgres'" lib/services/` returns zero hits
  after the change.
- `Grep "current_setting('app\\.").*$" db/migrations/` returns zero hits
  outside the wrapper-definition file
  (`202604280000_phase_9_0sigma_b_rls_wrappers.sql` itself).
- All affected unit/integration/live-binding tests for auth + MFA +
  rollups still pass.
- `dart analyze --fatal-infos` clean.

## Codex Acceptance

- [ ] New migration drops + recreates all bare-`current_setting` auth
      policies as wrapper-based.
- [ ] `tool/rls_policy_lint.dart` rejects bare `current_setting('app.*')`
      in any new migration.
- [ ] All 13 listed service files no longer import `package:postgres`.
- [ ] New repositories exist under `lib/infrastructure/persistence/postgres/`.
- [ ] All repositories extend `OperatorScopedRepository<T>` (or named
      cross-tenant variant) and inject session vars via `SET LOCAL`.
- [ ] `tool/postgres_import_lint.dart` covers `lib/services/`.
- [ ] Existing RLS isolation sweep test still passes.
- [ ] `dart analyze --fatal-infos` clean.
