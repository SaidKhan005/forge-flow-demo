# Postgres repositories — scoping rules

Every repository in this folder picks one of three execution paths.
The default choice follows from the table's RLS policy and column
shape — not from how convenient the path is. A small set of legacy
auth tables intentionally pick the wider operator-scoped path for
audit-context reasons (called out below); new repositories should
follow the policy-driven default unless they have the same
audit-context requirement. Picking the wrong base will either
fail-closed (no rows visible) or, worse, silently bypass RLS. Either
is a bug.

## The three roles

### 1. `OperatorScopedRepository` — operator-scoped tables

Lives at `lib/infrastructure/persistence/postgres/operator_scoped_repository.dart`.

Use for any table whose RLS policy filters by `public.app_current_operator()`
(reads the `app.operator_id` GUC). The base injects
`(operator_id, location_id, optional user_id)` via `SET LOCAL` —
specifically `select set_config(..., true)` with parameter binding —
inside a transaction the wrapper opens. Audit marker: `'tenant'`.

API:
- `withTenant(TenantContext, body)` — the normal path. Operator +
  location are required; `userId` is optional for background jobs.
- `withSystem(body, reason: ...)` — the admin escape hatch. Skips
  tenant SET LOCAL, issues `set local role forge_admin` to engage
  `BYPASSRLS`, and audits via `app.bypass_rls_audit = 'system:<reason>'`.
  Reserved for `/v1/admin/*` and confirmed-safe background jobs that
  cannot be expressed as a tenant-scoped op.

Examples (tables with an `operator_id` column whose policy reads
`app_current_operator()`): `roles`, `user_roles`, `auth_invites`,
`tncs_acceptances`, `external_identity_links`, every operator-scoped
fact table.

Intentional exceptions on this base: `auth_sessions`, `mfa_factors`,
and `password_history` are per-user tables (no `operator_id` column;
RLS reads only `app_current_actor_user()`), but their repositories
extend `OperatorScopedRepository` and call `withTenant` with a full
`(operatorId, locationId, userId)` context. The proxy already has all
three values from the verified JWT, and setting them all keeps audit
triggers and surrounding auth flows in a consistent
operator-attributed shape. The extra `app.operator_id` /
`app.location_id` GUCs are no-ops for these tables' RLS — they are
wired this way for audit/UX consistency, not because the policy
requires it. Future per-user tables should pick `UserScopedRepository`
unless they have the same audit-context requirement.

### 2. `UserScopedRepository` — per-user tables (no `operator_id` column)

Lives at `lib/infrastructure/persistence/postgres/repositories/user_scoped_repository.dart`.

Use for any table whose RLS policy filters by
`public.app_current_actor_user()` (reads the `app.user_id` GUC) AND
that has no `operator_id` column to gate on. The base sets only
`app.user_id` transaction-locally via `select set_config(..., true)`
with parameter binding. Audit marker: `'user'`. **No
`set local role forge_admin` is issued** — the per-user RLS policy
itself admits the row.

API:
- `withUser(userId, body)` — the only path.

Why this is separate from `OperatorScopedRepository`:
- The table has no `operator_id` column, so a `TenantContext`
  (operator + location required) is the wrong shape.
- Routing through `withSystem` would silently engage `BYPASSRLS` and
  skip the per-user gate the migration carefully wrote — that is the
  drift `B39` corrected and that the bootstrap test in
  `test/advisor_proxy_bootstrap_test.dart` now prevents.

Examples: `recovery_code_attempts`. Future per-user tables (per-user
notifications, per-user device fingerprints, etc.) belong here too.

### 3. System / cross-tenant — `OperatorScopedRepository.withSystem`

There is no separate `SystemRepository` class today. The role is
filled by `OperatorScopedRepository.withSystem(reason: ...)`, which
elevates to `forge_admin` (BYPASSRLS) for the lifetime of one
transaction and audits via `app.bypass_rls_audit = 'system:<reason>'`.

Use only when the actor is not the row owner and the read/write
genuinely needs to cross tenants — the canonical example is the
"force logout all sessions for user X" admin path
(`AuthSessionsRepository.revokeAllSessionsForUserAsAdmin`). Anything
that could be expressed by a tenant- or user-scoped op MUST use the
narrower path so RLS stays the primary defense and BYPASSRLS stays a
deliberate, audited escape hatch.

Phase 9.6 audits every `withSystem` invocation through
`auth_events_audit`; the `reason` string is the attribution that
shows up in that audit row.

## Picking the right base — quick decision

1. Read the migration that creates the table. Look at its
   `create policy ...` line and its column list.
2. If the policy reads `public.app_current_operator()` (or
   `current_setting('app.operator_id', true)::uuid` in a pre-9.0Σ.b
   migration), or the table mixes operator + per-user fields (e.g.
   `tncs_acceptances`) → `OperatorScopedRepository`, use `withTenant`.
3. If the policy reads ONLY `public.app_current_actor_user()` and the
   table has no `operator_id` column → default to
   `UserScopedRepository` with `withUser`. This is the right pick for
   net-new per-user tables (notifications, device fingerprints, etc.).
4. Exception to (3): if the new table needs full operator-attributed
   audit context the way `auth_sessions` / `mfa_factors` /
   `password_history` do, follow their precedent and stay on
   `OperatorScopedRepository.withTenant`. The extra GUCs are
   harmless for the policy but useful for audit triggers. Make this
   choice deliberately and call it out in the repo's class doc; the
   default for everything else is `UserScopedRepository`.
5. If the operation cannot be expressed in either path because the
   actor is genuinely cross-tenant (admin force-logout, scheduled
   sweep that needs a global view) → `OperatorScopedRepository`,
   use `withSystem(reason: ...)`. Audit attribution is mandatory.

## Bootstrap wiring

The proxy holds two pools:
- `POSTGRES_URL` — the tenant/app pool. Connection string used by the
  app role; RLS is on, so per-row gating happens in Postgres.
- `POSTGRES_ADMIN_URL` — the admin/deployment pool. Holds
  `forge_admin` (BYPASSRLS). Reserved for `withSystem` flows and
  migrations.

Repositories that route through `withTenant` or `withUser` MUST be
constructed with the wrapper backed by `POSTGRES_URL`. Repositories
that route through `withSystem` should be constructed with the wrapper
backed by `POSTGRES_ADMIN_URL`. The bootstrap test in
`test/advisor_proxy_bootstrap_test.dart` pins this for
`PostgresRecoveryCodeAttemptStore` so the wiring cannot drift back
to admin without a red test.
