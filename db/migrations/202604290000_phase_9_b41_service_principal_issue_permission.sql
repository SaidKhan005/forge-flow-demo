-- Phase 9 B41 - service-principal JWT issuance permission key.
--
-- Adds the app-layer permission gate for POST
-- `/v1/admin/service-principals/{id}/jwt`. The foundation migration
-- now includes this row for fresh installs; this additive seed keeps
-- already-applied staging/Production1 databases in sync without
-- replaying the foundation migration.

begin;

insert into public.permission_keys (
  key, category, description, requires_mfa, frozen
)
values
  (
    'admin.service_principal.issue_token',
    'admin',
    'Issue short-lived service-principal JWTs for automation identities. '
    'MFA required.',
    true,
    true
  )
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, 'admin.service_principal.issue_token', 'allow'
  from public.roles r
 where r.role_key = 'super_admin'
   and r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

commit;
