-- Phase 9 live-closeout - auth-ops grants for cloud-foundation identity rows.
--
-- 9.2 granted the auth tables themselves (`user_roles`, `auth_invites`,
-- `auth_events_audit`, etc.) to `service_role` / `forge_admin`, but the
-- production Team invite path also writes the cloud-foundation `users` table:
-- Firebase Admin -> users -> user_roles -> auth_invites -> audit.
--
-- Keep this grant shape narrow. Tenant runtime can read / touch only the
-- `users` fields needed by login freshness and permission snapshots; system
-- auth-ops can create and lifecycle-update `users` through the audited
-- `forge_admin` BYPASSRLS path. Operator/location/admin tables remain
-- read-only to these runtime roles.

grant select on public.operators to service_role;
grant select on public.locations to service_role;
grant select on public.operator_admins to service_role;
grant select, update on public.users to service_role;

grant select on public.operators to forge_admin;
grant select on public.locations to forge_admin;
grant select on public.operator_admins to forge_admin;
grant select, insert, update, delete on public.users to forge_admin;

comment on table public.users is
  'Cloud-foundation user row. Phase 9 auth-ops grants service_role SELECT/UPDATE for tenant freshness paths and forge_admin DML for audited Team/user lifecycle operations.';
