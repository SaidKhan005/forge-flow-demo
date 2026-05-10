# Hardening — RLS & Repository Pattern Contract

> **Status (2026-05-02):** Closed. Shipped commit `c4db50d` (PR #46) plus
> earlier repository-extraction commits that landed before HARD-F (the
> 13 service files were already free of `package:postgres` imports by
> the time HARD-F merged; HARD-F finished the wrapper-policy migration).
> Contract is retained as historical authority; no further implementation
> work owed.


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
- `tool/rls_policy_lint.dart` — exists (~251 LOC); forbids bare
  `current_setting('app.*')` inside `CREATE POLICY` bodies, with the
  superseded-migration allowlist at `tool/rls_policy_lint_allowlist.txt`.
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
   `202604280000_phase_9_0sigma_b_rls_wrappers.sql`. The four wrappers
   defined there (lines ~61-134, all `STABLE LEAKPROOF PARALLEL SAFE`)
   are:
   - `app_current_operator()` — reads `app.operator_id`; replaces
     `current_setting('app.operator_id', true)::uuid`.
   - `app_current_location()` — reads `app.location_id`.
   - `app_current_actor_user()` — reads `app.user_id`; replaces
     `current_setting('app.user_id', true)::uuid`.
   - `app_acting_as_operator()` — reads `app.acting_as_operator_id`
     (NULL until F&F internal cross-operator access lands).

Tables affected (verify by inspecting `202604260000`): minimally
`auth_sessions`, `auth_events_audit`, `mfa_factors`, `mfa_recovery_codes`,
`mfa_removal_requests`. Confirm the full list in the migration prelude
comment.

Migration is idempotent (uses `DROP POLICY IF EXISTS`, then `CREATE`).
RLS remains `enabled` on each affected table throughout — policies are
swapped, not disabled.

## Required — RLS Lint Extension

`tool/rls_policy_lint.dart` exists (~251 LOC) and is enforced via
`.github/workflows/ci.yml`. It already implements the rule:

- Scans every `db/migrations/*.sql` file for `CREATE POLICY` blocks
  (anchors on `CREATE POLICY ... ;` so plain prose comments referencing
  `current_setting('app.<name>', true)` do not produce false positives).
- For each policy body, forbids any literal match of
  `current_setting('app.` (case-insensitive).
- Allowed: calls to `app_current_operator()`, `app_current_location()`,
  `app_current_actor_user()`, `app_acting_as_operator()`.
- Files whose policies are definitively superseded by a later
  wrapper-using rewrite are listed in
  `tool/rls_policy_lint_allowlist.txt` (one filename per line, `#`
  comments allowed). The current allowlist supersedes
  `202604260000_auth_rls_per_tenant_policies.sql` via
  `202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql`.
- Diagnostic format: `<file>: policy "<name>" reads bare app.* GUC: <snippet>`.

Failure blocks the build.

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

- Extends `OperatorScopedRepository` (or system-scope variant for
  `gdpr_erasure_repository.dart` if inherently cross-tenant). The base
  class (see `lib/infrastructure/persistence/postgres/operator_scoped_repository.dart`)
  exposes exactly two execution paths: `withTenant(TenantContext, body)`
  for the normal path (runs body in a tx with `SET LOCAL
  app.operator_id / location_id / user_id`) and `withSystem(body, reason:)`
  for the audited admin-bypass path (`forge_admin BYPASSRLS`).
- Receives a `TenantTransactionWrapper`.
- Imports `package:postgres` (allowed in this directory).
- Exposes only domain-shaped methods; no `Connection` or `Statement`
  surfaces leak across the boundary.
- Sets `app.operator_id`, `app.location_id`, `app.user_id` via `SET LOCAL`
  in the transaction prelude.

Service-layer callers swap raw SQL execution for repository method calls.
Behavior is preserved — same result for same input.

### Sanctioned exception — `audit_logs_repository.dart` (defense-in-depth probe, PR [#424](https://github.com/SaidKhan005/forge-flow-demo/pull/424))

`lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart`
intentionally does NOT extend `OperatorScopedRepository`. Its
atomic-with-business-write contract requires that the audit row
commit in the same transaction as the change it audits — opening its
own `withTenant` wrapper would break that boundary. Instead, the
writer cross-checks the caller-supplied `operatorId` parameter
against `current_setting('app.operator_id', true)` BEFORE binding any
insert SQL and throws `AuditLogsTenantMismatchError` on disagreement.
When the GUC is unset (the `runAsSystem` admin path, where
`forge_admin BYPASSRLS` is the gate and a tenant-scope GUC wouldn't
make sense), the parameter is accepted as-is — those paths are
already audited via `app.bypass_rls_audit = 'system:<reason>'` on
the same transaction. This is the defense-in-depth equivalent of the
base-class enforcement.

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
- [ ] All repositories extend `OperatorScopedRepository` (or named
      cross-tenant variant) and inject session vars via `SET LOCAL`.
      Known exception: `audit_logs_repository.dart` (see "Known
      exception under remediation" above).
- [ ] `tool/postgres_import_lint.dart` covers `lib/services/`.
- [ ] Existing RLS isolation sweep test still passes.
- [ ] `dart analyze --fatal-infos` clean.
