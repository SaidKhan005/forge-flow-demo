-- Phase 9.0Σ.b — rewrite existing auth-table RLS policies through the
-- wrapper functions defined in 202604280000.
--
-- This migration is the policy-side half of item 4 from
-- `phase_9_scalability_decisions_2026-04-27.md`. The 12 auth-table
-- per-tenant policies created in 202604260000 still read tenant
-- context via bare `current_setting('app.<name>', true)::uuid`; the
-- planner cannot fold those calls into the tenant-leading index
-- because `current_setting()` is not LEAKPROOF. Replacing the inline
-- reads with `app_current_operator()` / `app_current_actor_user()`
-- restores planner pushdown.
--
-- Behavioral parity — every policy here matches the predicate shape
-- the 202604260000 version had. No policy is widened, narrowed, or
-- renamed; the only change is the function call. Negative tests
-- (bogus tenant denied) and positive tests (forge_admin BYPASSRLS)
-- continue to pass without modification.
--
-- Drop+recreate inside a single migration file. The `db/migrations`
-- runner applies each file with `psql --single-transaction` (per the
-- 202604260000 header comment), so the tables are never policy-less
-- between statements. The drops use `if exists` for re-runnability.
--
-- Cloud-foundation tables (operators, locations, users,
-- operator_admins, usage_logs, usage_caps, proxy_requests,
-- feature_flags, fx_rates) keep their service-role-only "all true"
-- stubs from 11a.11c.1 and are intentionally untouched here — those
-- stubs do not read `app.*` GUCs at all, so wrapper conversion is a
-- no-op for them. The cloud-foundation RLS flip is queued as B10 in
-- the Phase 9 execution backlog and will land its policies through
-- the wrappers from creation, not via a second rewrite.
--
-- This migration is local framework only — no live mutation.

-- ─── Drop the bare-current_setting auth policies ───────────────────
--
-- 12 tables × 1-2 policies each = 16 policies (matching the staging
-- closeout count in the execution backlog "Stale Findings Already
-- Resolved" section).

drop policy if exists "permission_keys_authenticated_select" on public.permission_keys;
drop policy if exists "roles_per_tenant_select" on public.roles;
drop policy if exists "roles_per_tenant_modify" on public.roles;
drop policy if exists "role_permissions_per_tenant_select" on public.role_permissions;
drop policy if exists "role_permissions_per_tenant_modify" on public.role_permissions;
drop policy if exists "user_roles_per_tenant" on public.user_roles;
drop policy if exists "auth_sessions_per_user" on public.auth_sessions;
drop policy if exists "mfa_factors_per_user" on public.mfa_factors;
drop policy if exists "tncs_acceptances_per_tenant" on public.tncs_acceptances;
drop policy if exists "password_history_per_user" on public.password_history;
drop policy if exists "auth_invites_per_tenant" on public.auth_invites;
drop policy if exists "auth_events_audit_per_tenant_select" on public.auth_events_audit;
drop policy if exists "auth_events_audit_append_insert" on public.auth_events_audit;
drop policy if exists "role_audit_log_per_tenant_select" on public.role_audit_log;
drop policy if exists "role_audit_log_append_insert" on public.role_audit_log;
drop policy if exists "external_identity_links_per_tenant" on public.external_identity_links;

-- ─── permission_keys ───────────────────────────────────────────────

create policy "permission_keys_authenticated_select"
  on public.permission_keys for select to service_role
  using (true);

-- ─── roles (operator_id NULLABLE) ──────────────────────────────────

create policy "roles_per_tenant_select"
  on public.roles for select to service_role
  using (
    operator_id is null
    or operator_id = public.app_current_operator()
  );

create policy "roles_per_tenant_modify"
  on public.roles for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

-- ─── role_permissions (joins roles for tenancy) ────────────────────

create policy "role_permissions_per_tenant_select"
  on public.role_permissions for select to service_role
  using (
    role_id in (
      select role_id from public.roles
      where operator_id is null
         or operator_id = public.app_current_operator()
    )
  );

create policy "role_permissions_per_tenant_modify"
  on public.role_permissions for all to service_role
  using (
    role_id in (
      select role_id from public.roles
      where operator_id = public.app_current_operator()
    )
  )
  with check (
    role_id in (
      select role_id from public.roles
      where operator_id = public.app_current_operator()
    )
  );

-- ─── user_roles ────────────────────────────────────────────────────

create policy "user_roles_per_tenant"
  on public.user_roles for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

-- ─── auth_sessions (per-user) ──────────────────────────────────────

create policy "auth_sessions_per_user"
  on public.auth_sessions for all to service_role
  using (user_id = public.app_current_actor_user())
  with check (user_id = public.app_current_actor_user());

-- ─── mfa_factors (per-user) ────────────────────────────────────────

create policy "mfa_factors_per_user"
  on public.mfa_factors for all to service_role
  using (user_id = public.app_current_actor_user())
  with check (user_id = public.app_current_actor_user());

-- ─── tncs_acceptances ──────────────────────────────────────────────

create policy "tncs_acceptances_per_tenant"
  on public.tncs_acceptances for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

-- ─── password_history (per-user) ───────────────────────────────────

create policy "password_history_per_user"
  on public.password_history for all to service_role
  using (user_id = public.app_current_actor_user())
  with check (user_id = public.app_current_actor_user());

-- ─── auth_invites ──────────────────────────────────────────────────

create policy "auth_invites_per_tenant"
  on public.auth_invites for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

-- ─── auth_events_audit (append-only grants preserved) ──────────────

create policy "auth_events_audit_per_tenant_select"
  on public.auth_events_audit for select to service_role
  using (
    operator_id is not null
    and operator_id = public.app_current_operator()
  );

create policy "auth_events_audit_append_insert"
  on public.auth_events_audit for insert to service_role
  with check (true);

-- ─── role_audit_log ────────────────────────────────────────────────

create policy "role_audit_log_per_tenant_select"
  on public.role_audit_log for select to service_role
  using (
    (
      role_id is not null
      and role_id in (
        select role_id from public.roles
        where operator_id is null
           or operator_id = public.app_current_operator()
      )
    )
    or (
      user_role_id is not null
      and user_role_id in (
        select user_role_id from public.user_roles
        where operator_id = public.app_current_operator()
      )
    )
  );

create policy "role_audit_log_append_insert"
  on public.role_audit_log for insert to service_role
  with check (true);

-- ─── external_identity_links ───────────────────────────────────────

create policy "external_identity_links_per_tenant"
  on public.external_identity_links for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

-- ─── Documentation comments (carried forward) ──────────────────────

comment on policy "permission_keys_authenticated_select" on public.permission_keys is
  'Phase 9.0Σ.b — wrapper-rewritten from 9.2. Any authenticated tenant request '
  'may read the frozen catalog. Catalog mutations are migration-owned; runtime '
  'writes are forge_admin only.';

comment on policy "roles_per_tenant_select" on public.roles is
  'Phase 9.0Σ.b — wrapper-rewritten from 9.2. Tenant sees seeded global roles '
  'plus their own custom roles. Reads operator context via app_current_operator().';

comment on policy "user_roles_per_tenant" on public.user_roles is
  'Phase 9.0Σ.b — wrapper-rewritten from 9.2. Tenant sees only their own role '
  'grants. Cross-tenant grant attempts fail at WITH CHECK.';

comment on policy "auth_sessions_per_user" on public.auth_sessions is
  'Phase 9.0Σ.b — wrapper-rewritten from 9.2. Users see only their own sessions. '
  'Force-logout-all-sessions admin path uses forge_admin BYPASSRLS.';

comment on policy "auth_events_audit_per_tenant_select" on public.auth_events_audit is
  'Phase 9.0Σ.b — wrapper-rewritten from 9.2. Tenants read their own audit rows. '
  'System events (operator_id IS NULL) are visible only via forge_admin BYPASSRLS.';
