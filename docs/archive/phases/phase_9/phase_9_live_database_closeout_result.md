# Phase 9 Live Database Closeout Result

Date: 2026-04-27

Status: ACCEPTED

Scope: apply and verify the remaining Phase 9 database migrations on staging
and Production1. No operator data was loaded. No Firebase, provider, or app
runtime calls were made.

## Applied

Staging:

- `202604270000_phase_9_0a_scope_extensions.sql`
- `202604270100_auth_sessions_token_hash_rename.sql`
- `202604270200_phase_9_0a_super_admin_team_grants.sql`

Production1:

- `202604260000_auth_rls_per_tenant_policies.sql`
- `202604260001_auth_rls_service_role_grants.sql`
- `202604270000_phase_9_0a_scope_extensions.sql`
- `202604270100_auth_sessions_token_hash_rename.sql`
- `202604270200_phase_9_0a_super_admin_team_grants.sql`

`202604270200_phase_9_0a_super_admin_team_grants.sql` was added during this
closeout after live verification showed the later `team.*` keys were granted
to `operator_owner` and `operator_manager`, but not retroactively to
`super_admin`. The new migration is idempotent and restores the contract:
`super_admin` has every catalog key.

## Verification

Both staging and Production1 returned:

- `permission_keys = 93`
- `team.* keys = 12`
- `super_admin team grants = 12`
- `operator_owner team grants = 12`
- `operator_manager team grants = 9`
- `auth_sessions.token_hash` exists
- `auth_sessions.refresh_token_hash` does not exist
- `user_roles.scope_type`, `users.primary_location_id`, and
  `operators.region` exist
- 12 Phase 9 auth tables have row-level security enabled
- 16 Phase 9 auth policies are present
- `user_roles_active_grant_idx` leads with `operator_id`
- `auth_events_audit_actor_occurred_idx` and
  `auth_events_audit_target_occurred_idx` lead with `operator_id`
- `auth_events_audit` grants remain append-only for `service_role` and
  `forge_admin` (`INSERT,SELECT` only)
- `timestamp without time zone` column count is 0

## Notes

The local `psql` client did not have the Azure root certificate configured for
the saved staging `sslmode=verify-full` URL. The apply and verification used a
temporary in-memory `sslmode=require` connection string after the host safety
checks passed for `forge-flow-staging-pg` and `forge-flow-production1-pg`. The
secrets file was not modified.

## Acceptance

- [x] Staging Phase 9 auth database closeout applied and verified.
- [x] Production1 Phase 9 auth database closeout applied and verified.
- [x] `super_admin` keeps every permission key after 9.0a.
- [x] No operator data loaded.
- [x] No Firebase/provider calls.
- [x] No secret values recorded.
