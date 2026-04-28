-- Phase 9.0a audit-fix - grant new team.* keys to super_admin.
--
-- 9.0 seeded super_admin with every permission key that existed at that time.
-- 9.0a added 12 team.* keys later, so the original cross-join seed cannot
-- pick them up retroactively. Keep the baseline role contract true: super_admin
-- has every key in the frozen catalog.
--
-- Idempotent: safe to re-run on local + staging + Production1.

begin;

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'super_admin'
   and r.operator_id is null
   and pk.category = 'team'
on conflict (role_id, permission_key) do nothing;

comment on table public.role_permissions is
  '9.0 role-to-permission grant table. 9.0a audit-fix grants newly added team.* keys to super_admin so the seeded super_admin role keeps every catalog key.';

commit;
