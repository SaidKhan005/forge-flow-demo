-- Admin Hierarchy UX cleanup - hierarchy lifecycle columns and gates.
--
-- Adds persisted suspend/delete state for Business Accounts hierarchy
-- management. The route layer gates lifecycle actions with the two
-- team.hierarchy.* permission keys seeded here.

begin;

alter table public.locations
  add column if not exists suspended_at timestamptz null,
  add column if not exists deleted_at timestamptz null;

alter table public.org_units
  add column if not exists suspended_at timestamptz null,
  add column if not exists deleted_at timestamptz null;

create index if not exists locations_operator_live_idx
  on public.locations (operator_id, parent_org_unit_id, lower(name))
  where deleted_at is null;

create index if not exists org_units_operator_live_idx
  on public.org_units (operator_id, parent_id, path)
  where deleted_at is null;

insert into public.permission_keys (
  key, category, description, requires_mfa, frozen
)
values
  (
    'team.hierarchy.suspend',
    'team',
    'Suspend or reactivate locations and hierarchy levels.',
    false,
    true
  ),
  (
    'team.hierarchy.delete',
    'team',
    'Delete locations and empty hierarchy levels.',
    false,
    true
  )
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  join public.permission_keys pk
    on pk.key in ('team.hierarchy.suspend', 'team.hierarchy.delete')
 where r.role_key in ('super_admin', 'operator_owner')
   and r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

commit;
