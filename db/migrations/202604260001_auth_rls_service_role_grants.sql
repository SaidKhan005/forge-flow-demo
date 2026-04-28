-- Phase 9.2 live-closeout - auth RLS service_role table grants.
--
-- 202604260000 flips the auth-table RLS policies from service-role-only
-- stubs to per-tenant/per-user policies, but Postgres still requires
-- table-level privileges before a policy can allow a row. This migration
-- grants the minimum table privileges that match those policies:
--
--   * permission_keys: SELECT only (frozen catalog; writes are migration /
--     forge_admin BYPASSRLS paths, never tenant runtime).
--   * mutable auth tables: SELECT / INSERT / UPDATE / DELETE to service_role,
--     with row visibility constrained by the 202604260000 RLS policies.
--   * forge_admin: matching table privileges so SET LOCAL ROLE forge_admin
--     can actually use its BYPASSRLS attribute. Audit tables stay
--     INSERT / SELECT only for forge_admin too.
--   * audit tables: keep append-only shape from 9.0; INSERT / SELECT only,
--     UPDATE / DELETE explicitly revoked from both service_role and
--     forge_admin.

grant select on public.permission_keys to service_role;
grant select on public.permission_keys to forge_admin;

grant select, insert, update, delete on public.roles to service_role;
grant select, insert, update, delete on public.role_permissions to service_role;
grant select, insert, update, delete on public.user_roles to service_role;
grant select, insert, update, delete on public.auth_sessions to service_role;
grant select, insert, update, delete on public.mfa_factors to service_role;
grant select, insert, update, delete on public.tncs_acceptances to service_role;
grant select, insert, update, delete on public.password_history to service_role;
grant select, insert, update, delete on public.auth_invites to service_role;
grant select, insert, update, delete on public.external_identity_links to service_role;

grant select, insert, update, delete on public.roles to forge_admin;
grant select, insert, update, delete on public.role_permissions to forge_admin;
grant select, insert, update, delete on public.user_roles to forge_admin;
grant select, insert, update, delete on public.auth_sessions to forge_admin;
grant select, insert, update, delete on public.mfa_factors to forge_admin;
grant select, insert, update, delete on public.tncs_acceptances to forge_admin;
grant select, insert, update, delete on public.password_history to forge_admin;
grant select, insert, update, delete on public.auth_invites to forge_admin;
grant select, insert, update, delete on public.external_identity_links to forge_admin;

grant select, insert on public.auth_events_audit to service_role;
grant select, insert on public.role_audit_log to service_role;
revoke update, delete on public.auth_events_audit from service_role;
revoke update, delete on public.role_audit_log from service_role;

grant select, insert on public.auth_events_audit to forge_admin;
grant select, insert on public.role_audit_log to forge_admin;
revoke update, delete on public.auth_events_audit from forge_admin;
revoke update, delete on public.role_audit_log from forge_admin;

comment on table public.permission_keys is
  '9.0 frozen permission catalog. 9.2 grants service_role SELECT only; runtime writes require forge_admin/migration authority.';
comment on table public.auth_events_audit is
  '9.0 append-only auth event audit log. 9.2 service_role may INSERT/SELECT only; UPDATE/DELETE remain revoked.';
comment on table public.role_audit_log is
  '9.0 append-only role audit log. 9.2 service_role may INSERT/SELECT only; UPDATE/DELETE remain revoked.';
