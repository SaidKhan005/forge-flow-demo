-- Phase 9.0Σ.l — RLS defense-in-depth on proxy_requests + feature_flags.
--
-- Closes the P1 gap from `docs/POST_HARDENING_FOLLOWUPS.md`: both tables
-- were created in `202604250005_advisor_cloud_foundation.sql` with RLS
-- ENABLED but only carried the permissive `*_service_role_all using
-- (true) with check (true)` stub policies the cloud-foundation drop
-- shipped. Today's posture is therefore application-layer only —
-- `OperatorScopedRepository` injects the tenant predicate, and the
-- service-role-only policies do not assert anything else. This slice
-- adds the database-side second layer.
--
-- Authority order:
--   1. CLAUDE.md "RLS-Ready Schema" — two-layer defense; repository is
--      primary, RLS is the backup.
--   2. `phase_9_scalability_decisions_2026-04-27.md` item 4 — RLS UUID
--      wrappers (every operator-scoped policy reads tenant context
--      through `app_current_operator()` + `app_current_location()` so
--      the planner can fold the predicate into the tenant-leading
--      index).
--   3. `phase_9_scalability_decisions_2026-04-27.md` RLS performance
--      discipline — every B-tree index leads with `operator_id`. The
--      `proxy_requests` indexes from `202604250007_advisor_rls_index_
--      hardening.sql` already comply (PK + the
--      `proxy_requests_operator_location_idempotency_key_key` UNIQUE
--      lead with `operator_id, location_id`); this migration does not
--      add or rewrite any index.
--   4. `202604280000_phase_9_0sigma_b_rls_wrappers.sql` — the wrapper
--      functions this migration calls.
--
-- Behavioral parity:
--
--   * proxy_requests: location-scoped — proxy writes carry both
--     operator_id and location_id (tenant transactions inject both
--     GUCs). Policy filters on `(operator_id, location_id)` so a
--     stray request whose location belongs to a different operator
--     cannot be read or written even if the application-layer scope
--     check is bypassed.
--
--   * feature_flags: three logical scopes (global / operator-wide /
--     location-scoped), enforced today by partial unique indexes from
--     202604250005. The policy mirrors that shape — global rows
--     (operator_id IS NULL) are visible to every tenant, operator/
--     location-scoped rows are visible only to their owning operator.
--     WITH CHECK is the asymmetric half: a tenant CANNOT insert or
--     update a global-scope row through this policy. Migration-side
--     seeds (the `audit_logs_cutover_enabled` and KMS rollout flags
--     in 202605010100 and 202605020200) run as the deployment role,
--     which owns the table and is therefore RLS-exempt; super-admin
--     mutations from the 11A.7 admin Feature Flags screen elevate to
--     `forge_admin BYPASSRLS` via `runAsSystem`. Net effect: tenants
--     read their own + global flags but can only mutate their own.
--
-- Idempotency: every DROP uses `if exists`; the file applies in one
-- transaction (`psql --single-transaction`), so the tables are never
-- policy-less between statements. Re-runs are no-ops.
--
-- Lint coverage: every CREATE POLICY body below reads tenant context
-- through wrapper functions, so `tool/rls_policy_lint.dart` does not
-- need an allowlist entry for this file.

-- ─── proxy_requests: drop permissive stub, add per-tenant policy ────

alter table public.proxy_requests enable row level security;

drop policy if exists "proxy_requests_service_role_all"
  on public.proxy_requests;

create policy "proxy_requests_tenant_isolation"
  on public.proxy_requests for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

comment on policy "proxy_requests_tenant_isolation" on public.proxy_requests is
  'Phase 9.0Σ.l — defense-in-depth tenant isolation. Replaces the '
  'permissive 11a.11c.1 service-role stub. Reads operator + location '
  'context via wrappers so the planner folds the predicate into the '
  'tenant-leading PK / idempotency-key UNIQUE index from 11a.11c.6. '
  'Application-layer OperatorScopedRepository remains the primary '
  'defense; this policy is the backup.';

-- proxy_requests already carries the GRANT SELECT, INSERT, UPDATE,
-- DELETE → service_role from `202604250005_advisor_cloud_foundation.sql`
-- (every cloud-foundation table receives the standard tenant-write
-- grant set there). Re-asserting them would no-op; omitted here for
-- the same reason 202604280001 did not re-assert auth-table grants.

-- ─── feature_flags: drop permissive stub, add tenant-or-global policy

alter table public.feature_flags enable row level security;

drop policy if exists "feature_flags_service_role_all"
  on public.feature_flags;

create policy "feature_flags_global_or_tenant"
  on public.feature_flags for all to service_role
  using (
    operator_id is null
    or operator_id = public.app_current_operator()
  )
  with check (
    operator_id is not null
    and operator_id = public.app_current_operator()
  );

comment on policy "feature_flags_global_or_tenant" on public.feature_flags is
  'Phase 9.0Σ.l — defense-in-depth tenant isolation with global '
  'visibility. Tenants SELECT their own (operator_id matches) plus '
  'global rows (operator_id IS NULL) so the proxy can read launch-'
  'wide kill switches. WITH CHECK is asymmetric: tenants cannot '
  'INSERT/UPDATE global-scope rows — that path elevates to '
  'forge_admin BYPASSRLS via runAsSystem (super_admin Feature Flags '
  'screen) or runs as the deployment role from migration seeds.';
