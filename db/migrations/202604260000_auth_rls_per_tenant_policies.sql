-- Phase 9.2 - Auth RLS per-tenant policy flip + forge_admin BYPASSRLS role.
--
-- Flips the 9.0 service-role-only RLS stubs on the auth surface to
-- per-tenant policies that read tenant context from
-- `current_setting('app.operator_id', true)::uuid` and (for per-user
-- tables) `current_setting('app.user_id', true)::uuid`. The proxy
-- injects these via `select set_config(..., true)` inside every
-- tenant-scoped transaction (see
-- `lib/infrastructure/persistence/postgres/tenant_transaction.dart`).
--
-- Admin paths under `/v1/admin/*` use the new `forge_admin` role,
-- which carries the `BYPASSRLS` attribute and is granted to
-- `service_role` so the proxy can `SET LOCAL ROLE forge_admin`
-- inside the system-scope transaction. Every BYPASSRLS use writes a
-- `gdpr_erasure` / role-change / audit row in 9.6+.
--
-- This migration intentionally covers ONLY the 12 Phase 9 auth
-- tables. The cloud-foundation tables (operators, locations, users,
-- operator_admins, usage_logs, usage_caps, proxy_requests,
-- feature_flags) carry the same service-role-only stubs from 11a
-- and are queued for a follow-up RLS flip — see Phase 9 checkpoint.
-- The corpus tables (advisor_ingestion_runs, advisor_source_*,
-- advisor_graph_*) stay F&F-global until 11b.1 introduces per-
-- operator corpus scoping and are intentionally untouched here.
--
-- Hard rules carried into this slice:
--
--   1. `SET LOCAL` (transaction-scoped) tenant injection — never
--      session-scoped `SET`. The repository pattern wrapper enforces
--      this in Dart.
--   2. RLS performance discipline — every operator-scoped index
--      already leads with `operator_id`; this migration only adds
--      policies, never indexes.
--   3. Append-only audit shape preserved — `auth_events_audit` /
--      `role_audit_log` UPDATE+DELETE grants stay revoked. Per-tenant
--      SELECT layered on top.
--   4. Repository pattern is the primary defense; RLS is the backup.
--      The proxy still goes through OperatorScopedRepository on every
--      call.
--
-- This migration does NOT seed any operator data, does NOT call any
-- live provider, and does NOT depend on `pgmq` (not exposed by Azure
-- Flexible Server, see CLAUDE.md "Proxy & API Conventions").

-- ─── forge_admin role with BYPASSRLS ────────────────────────────────
--
-- Created LOGIN-less + BYPASSRLS so it can only be entered via
-- `SET ROLE forge_admin` from a connection authenticated as
-- service_role. service_role itself stays NOLOGIN (the proxy connects
-- as a Postgres user that has been granted service_role; the same
-- user is also granted forge_admin via the GRANT below so SET ROLE
-- forge_admin succeeds).
--
-- The `do $$ ... $$` block makes this idempotent. ALTER ROLE after
-- the conditional CREATE keeps re-runs safe even if the role already
-- existed without the BYPASSRLS attribute.
do $$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'forge_admin') then
    create role forge_admin nologin bypassrls;
  end if;
end$$;

alter role forge_admin nologin bypassrls;

grant forge_admin to service_role;

comment on role forge_admin is
  'Phase 9.2 - admin BYPASSRLS escape hatch. Granted to service_role so '
  'the proxy can SET LOCAL ROLE forge_admin inside /v1/admin/* paths. '
  'Every transaction that elevates to forge_admin must audit through '
  'auth_events_audit (Phase 9.6 enforces).';

-- ─── Drop 9.0 service-role-only policy stubs ────────────────────────
--
-- Single transaction (psql --single-transaction) means the drop +
-- create pair below is atomic — the tables are never policy-less
-- between statements.

drop policy if exists "permission_keys_service_role_all" on public.permission_keys;
drop policy if exists "roles_service_role_all" on public.roles;
drop policy if exists "role_permissions_service_role_all" on public.role_permissions;
drop policy if exists "user_roles_service_role_all" on public.user_roles;
drop policy if exists "auth_sessions_service_role_all" on public.auth_sessions;
drop policy if exists "mfa_factors_service_role_all" on public.mfa_factors;
drop policy if exists "tncs_acceptances_service_role_all" on public.tncs_acceptances;
drop policy if exists "password_history_service_role_all" on public.password_history;
drop policy if exists "auth_invites_service_role_all" on public.auth_invites;
drop policy if exists "auth_events_audit_service_role_append_only" on public.auth_events_audit;
drop policy if exists "auth_events_audit_service_role_select" on public.auth_events_audit;
drop policy if exists "role_audit_log_service_role_append_only" on public.role_audit_log;
drop policy if exists "role_audit_log_service_role_select" on public.role_audit_log;
drop policy if exists "external_identity_links_service_role_all" on public.external_identity_links;

-- ─── permission_keys (global catalog, no operator_id) ───────────────
--
-- Catalog rows are not tenant data; any authenticated tenant request
-- may read the catalog (the Flutter clients render permission names
-- via 9.9). Writes are forge_admin-only because the catalog is frozen
-- at code level (see auth_permission_key_catalog.md authority order).

create policy "permission_keys_authenticated_select"
  on public.permission_keys for select to service_role
  using (true);

-- INSERT/UPDATE/DELETE are intentionally NOT granted to service_role.
-- The migration owns catalog seeding; runtime mutation happens only
-- via forge_admin role (BYPASSRLS), and even then only the migration
-- path mutates the frozen catalog.

-- ─── roles (operator_id NULLABLE — global + operator-scoped) ────────
--
-- Global seeded roles (operator_id IS NULL) are visible to every
-- tenant so the resolver in 9.6 can grant them. Operator-scoped
-- custom roles are visible only to the owning operator.

create policy "roles_per_tenant_select"
  on public.roles for select to service_role
  using (
    operator_id is null
    or operator_id = current_setting('app.operator_id', true)::uuid
  );

create policy "roles_per_tenant_modify"
  on public.roles for all to service_role
  using (operator_id = current_setting('app.operator_id', true)::uuid)
  with check (operator_id = current_setting('app.operator_id', true)::uuid);

-- ─── role_permissions (no operator_id; joins roles for tenancy) ─────
--
-- The bundle definitions belong to a role; tenancy follows the role.
-- The subquery is the standard PG pattern for derived RLS — slower
-- than a direct operator_id column, but `role_permissions` rows are
-- low cardinality (~80 keys × ~6 roles = ~500) and the query
-- planner caches the lookup across the policy evaluation.

create policy "role_permissions_per_tenant_select"
  on public.role_permissions for select to service_role
  using (
    role_id in (
      select role_id from public.roles
      where operator_id is null
         or operator_id = current_setting('app.operator_id', true)::uuid
    )
  );

create policy "role_permissions_per_tenant_modify"
  on public.role_permissions for all to service_role
  using (
    role_id in (
      select role_id from public.roles
      where operator_id = current_setting('app.operator_id', true)::uuid
    )
  )
  with check (
    role_id in (
      select role_id from public.roles
      where operator_id = current_setting('app.operator_id', true)::uuid
    )
  );

-- ─── user_roles (operator_id NOT NULL) ──────────────────────────────

create policy "user_roles_per_tenant"
  on public.user_roles for all to service_role
  using (operator_id = current_setting('app.operator_id', true)::uuid)
  with check (operator_id = current_setting('app.operator_id', true)::uuid);

-- ─── auth_sessions (per-user; no operator_id) ───────────────────────
--
-- Sessions are per-user. A given Phase 9.3 request only ever needs to
-- read or revoke its own session row, so the policy filters on
-- `user_id = current_setting('app.user_id')`. Admin paths under
-- `/v1/admin/auth/users/{id}/force-logout` use forge_admin.

create policy "auth_sessions_per_user"
  on public.auth_sessions for all to service_role
  using (user_id = current_setting('app.user_id', true)::uuid)
  with check (user_id = current_setting('app.user_id', true)::uuid);

-- ─── mfa_factors (per-user; no operator_id) ─────────────────────────

create policy "mfa_factors_per_user"
  on public.mfa_factors for all to service_role
  using (user_id = current_setting('app.user_id', true)::uuid)
  with check (user_id = current_setting('app.user_id', true)::uuid);

-- ─── tncs_acceptances (operator_id NOT NULL) ────────────────────────

create policy "tncs_acceptances_per_tenant"
  on public.tncs_acceptances for all to service_role
  using (operator_id = current_setting('app.operator_id', true)::uuid)
  with check (operator_id = current_setting('app.operator_id', true)::uuid);

-- ─── password_history (per-user; no operator_id) ────────────────────

create policy "password_history_per_user"
  on public.password_history for all to service_role
  using (user_id = current_setting('app.user_id', true)::uuid)
  with check (user_id = current_setting('app.user_id', true)::uuid);

-- ─── auth_invites (operator_id NOT NULL) ────────────────────────────

create policy "auth_invites_per_tenant"
  on public.auth_invites for all to service_role
  using (operator_id = current_setting('app.operator_id', true)::uuid)
  with check (operator_id = current_setting('app.operator_id', true)::uuid);

-- ─── auth_events_audit (operator_id NULLABLE; append-only grants) ───
--
-- Per-tenant SELECT for tenant-scoped events; system events
-- (operator_id IS NULL) are visible only via forge_admin BYPASSRLS.
-- INSERT must remain open to service_role for every login/logout
-- regardless of tenant context — even logins that fail tenant
-- resolution write a row. The append-only grant shape (UPDATE/DELETE
-- revoked from service_role) is unchanged from 9.0.

create policy "auth_events_audit_per_tenant_select"
  on public.auth_events_audit for select to service_role
  using (
    operator_id is not null
    and operator_id = current_setting('app.operator_id', true)::uuid
  );

create policy "auth_events_audit_append_insert"
  on public.auth_events_audit for insert to service_role
  with check (true);

-- ─── role_audit_log (no operator_id; joined via role_id/user_role_id) ─
--
-- Rows belong to either a role mutation (role_id set) or a grant
-- mutation (user_role_id set). Tenant filtering follows whichever is
-- non-null.

create policy "role_audit_log_per_tenant_select"
  on public.role_audit_log for select to service_role
  using (
    (
      role_id is not null
      and role_id in (
        select role_id from public.roles
        where operator_id is null
           or operator_id = current_setting('app.operator_id', true)::uuid
      )
    )
    or (
      user_role_id is not null
      and user_role_id in (
        select user_role_id from public.user_roles
        where operator_id = current_setting('app.operator_id', true)::uuid
      )
    )
  );

create policy "role_audit_log_append_insert"
  on public.role_audit_log for insert to service_role
  with check (true);

-- ─── external_identity_links (operator_id NOT NULL) ─────────────────

create policy "external_identity_links_per_tenant"
  on public.external_identity_links for all to service_role
  using (operator_id = current_setting('app.operator_id', true)::uuid)
  with check (operator_id = current_setting('app.operator_id', true)::uuid);

-- ─── Documentation comments ─────────────────────────────────────────

comment on policy "permission_keys_authenticated_select" on public.permission_keys is
  'Phase 9.2 - any authenticated tenant request may read the frozen catalog. '
  'Catalog mutations are migration-owned; runtime writes are forge_admin only.';

comment on policy "roles_per_tenant_select" on public.roles is
  'Phase 9.2 - tenant sees seeded global roles plus their own custom roles. '
  'See auth_permission_key_catalog.md for the seeded role list.';

comment on policy "user_roles_per_tenant" on public.user_roles is
  'Phase 9.2 - tenant sees only their own role grants. '
  'Cross-tenant grant attempts fail at WITH CHECK.';

comment on policy "auth_sessions_per_user" on public.auth_sessions is
  'Phase 9.2 - users see only their own sessions. Force-logout-all-sessions '
  'admin path uses forge_admin BYPASSRLS.';

comment on policy "auth_events_audit_per_tenant_select" on public.auth_events_audit is
  'Phase 9.2 - tenants read their own audit rows. System events '
  '(operator_id IS NULL) are visible only via forge_admin BYPASSRLS, which '
  'is itself audited.';
