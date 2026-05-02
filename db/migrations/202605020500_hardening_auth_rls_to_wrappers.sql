-- HARD-F — defense-in-depth re-assert of wrapper-based auth RLS policies.
--
-- Re-applies the wrapper-function rewrite that 202604280001 already
-- landed for the 12 auth tables originally defined in 202604260000.
-- The rewrite drops + recreates each per-tenant / per-user policy so
-- bare `current_setting('app.<name>', true)::uuid` reads cannot creep
-- back onto these tables — for example after a hand-edit on staging
-- or after an out-of-band restore that resurrected the 9.2 shape.
--
-- All four wrapper functions
-- (`app_current_operator`, `app_current_location`, `app_current_actor_user`,
-- `app_acting_as_operator`) live in 202604280000_phase_9_0sigma_b_rls_wrappers.sql
-- and are frozen — this migration depends on them but never redefines
-- them.
--
-- Behavioral parity: every policy below matches the predicate shape the
-- 202604280001 rewrite uses. Append-only audit grants on
-- `auth_events_audit` and `role_audit_log` keep `with check (true)` on
-- INSERT so failed-tenant logins still write an audit row.
--
-- Idempotency posture (HARD-F hard constraint): every DROP uses `if
-- exists` and the migration runs in `psql --single-transaction` so the
-- tables are never policy-less between statements. Re-running this
-- migration is a no-op when 202604280001 has already been applied.
-- Running it on a database that somehow lost the 202604280001 rewrite
-- restores the wrapper-based policies in one atomic transaction.
--
-- Lint coverage: `tool/rls_policy_lint.dart` rejects any new migration
-- whose policy body reads `current_setting` directly against an `app.`
-- GUC. The two files that historically held the bare reads
-- (202604260000 and a hypothetical out-of-band rewrite) are listed in
-- `tool/rls_policy_lint_allowlist.txt`. Every policy below uses the
-- wrappers and therefore needs no allowlist entry.
--
-- Tables touched (16 policies across 12 tables, matching 202604280001):
--
--   public.permission_keys           — permission_keys_authenticated_select
--   public.roles                     — roles_per_tenant_select / _modify
--   public.role_permissions          — role_permissions_per_tenant_select / _modify
--   public.user_roles                — user_roles_per_tenant
--   public.auth_sessions             — auth_sessions_per_user
--   public.mfa_factors               — mfa_factors_per_user
--   public.tncs_acceptances          — tncs_acceptances_per_tenant
--   public.password_history          — password_history_per_user
--   public.auth_invites              — auth_invites_per_tenant
--   public.auth_events_audit         — auth_events_audit_per_tenant_select / _append_insert
--   public.role_audit_log            — role_audit_log_per_tenant_select / _append_insert
--   public.external_identity_links   — external_identity_links_per_tenant

-- ─── Drop existing policies ────────────────────────────────────────
--
-- Ordered by table for readability; the runner applies the whole
-- migration as one transaction so order does not matter for atomicity.

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

-- ─── permission_keys (global catalog) ──────────────────────────────

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

-- ─── auth_events_audit (per-tenant SELECT, append-only INSERT) ─────
--
-- The append INSERT keeps `with check (true)` so failed-login rows
-- still write even when tenant resolution failed. Narrowing this would
-- silently drop the very audit rows the security team relies on for
-- incident triage.

create policy "auth_events_audit_per_tenant_select"
  on public.auth_events_audit for select to service_role
  using (
    operator_id is not null
    and operator_id = public.app_current_operator()
  );

create policy "auth_events_audit_append_insert"
  on public.auth_events_audit for insert to service_role
  with check (true);

-- ─── role_audit_log (joined via role_id / user_role_id) ────────────

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

-- ─── Documentation comments (carried forward from 202604280001) ────
--
-- DROP POLICY removes the policy's comment along with the policy
-- object, so this re-assert must restore every COMMENT ON POLICY
-- statement that 202604280001 carried forward. Wording is wire-for-
-- wire identical to the rewrite so a database that applies HARD-F
-- after losing 202604280001 ends up with the same `\\dp+` output.
-- The HARD-F parity test compares the COMMENT ON POLICY set across
-- both files and fails if either side adds, removes, or rewords a
-- comment.

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
