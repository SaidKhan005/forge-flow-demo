-- Admin hierarchy lifecycle/access hardening.
--
-- The lifecycle column core landed in
-- 202605082200_admin_hierarchy_lifecycle.sql. This follow-up carries the
-- non-superseded hardening:
--
--   * creator/updater audit stamps for hierarchy/user rows
--   * active-only org-unit path uniqueness after soft delete
--   * direct location/org-unit grant lookup indexes for repository guards
--   * user_effective_locations refresh logic for inactive hierarchy rows
--   * refresh triggers when suspended_at or deleted_at changes

begin;

create extension if not exists ltree;

alter table public.org_units
  add column if not exists created_by uuid null,
  add column if not exists updated_by uuid null,
  add column if not exists suspended_at timestamptz null,
  add column if not exists deleted_at timestamptz null;

comment on column public.org_units.created_by is
  'Admin hierarchy audit stamp: user id that created this org-unit row when known.';

comment on column public.org_units.updated_by is
  'Admin hierarchy audit stamp: user id that last changed this org-unit row when known.';

comment on column public.org_units.suspended_at is
  'Admin hierarchy lifecycle: when this org unit was suspended.';

comment on column public.org_units.deleted_at is
  'Admin hierarchy lifecycle: soft-delete time. Deleted org units are hidden from active hierarchy reads.';

alter table public.locations
  add column if not exists created_by uuid null,
  add column if not exists updated_by uuid null,
  add column if not exists suspended_at timestamptz null,
  add column if not exists deleted_at timestamptz null;

comment on column public.locations.created_by is
  'Admin hierarchy audit stamp: user id that created this location row when known.';

comment on column public.locations.updated_by is
  'Admin hierarchy audit stamp: user id that last changed this location row when known.';

comment on column public.locations.suspended_at is
  'Admin hierarchy lifecycle: when this location was suspended.';

comment on column public.locations.deleted_at is
  'Admin hierarchy lifecycle: soft-delete time. Deleted locations are hidden from active hierarchy reads.';

alter table public.users
  add column if not exists created_by uuid null,
  add column if not exists updated_by uuid null;

comment on column public.users.created_by is
  'Admin hierarchy audit stamp: user id that created or invited this user row when known.';

comment on column public.users.updated_by is
  'Admin hierarchy audit stamp: user id that last changed this user row when known.';

alter table public.org_units
  drop constraint if exists org_units_operator_id_path_key;

create unique index if not exists org_units_operator_path_active_uq
  on public.org_units (operator_id, path)
  where deleted_at is null;

create index if not exists org_units_operator_active_id_idx
  on public.org_units (operator_id, id)
  where deleted_at is null;

create index if not exists org_units_operator_parent_name_active_idx
  on public.org_units (operator_id, parent_id, lower(name))
  where deleted_at is null;

create index if not exists org_units_operator_suspended_idx
  on public.org_units (operator_id, suspended_at)
  where suspended_at is not null and deleted_at is null;

create index if not exists locations_operator_active_id_idx
  on public.locations (operator_id, location_id)
  where deleted_at is null;

create index if not exists locations_operator_suspended_idx
  on public.locations (operator_id, suspended_at)
  where suspended_at is not null and deleted_at is null;

create index if not exists user_roles_active_location_target_idx
  on public.user_roles (operator_id, location_id, user_id)
  where scope_type = 'location' and revoked_at is null;

create index if not exists user_roles_active_org_unit_target_idx
  on public.user_roles (operator_id, org_unit_id, user_id)
  where scope_type = 'org_unit' and revoked_at is null;

create index if not exists auth_invites_active_location_target_idx
  on public.auth_invites (operator_id, location_id, expires_at)
  where scope_type = 'location'
    and accepted_at is null
    and revoked_at is null;

create index if not exists auth_invites_active_org_unit_target_idx
  on public.auth_invites (operator_id, org_unit_id, expires_at)
  where scope_type = 'org_unit'
    and accepted_at is null
    and revoked_at is null;

create or replace function public.refresh_user_effective_locations(
  p_user_id uuid,
  p_operator_id uuid
)
returns void
language plpgsql
as $$
begin
  delete from public.user_effective_locations
   where user_id = p_user_id
     and operator_id = p_operator_id;

  insert into public.user_effective_locations (
    operator_id,
    user_id,
    location_id,
    source_user_role_id,
    source_scope_type,
    source_org_unit_id,
    source_location_id,
    computed_at
  )
  select distinct
    ur.operator_id,
    ur.user_id,
    loc.location_id,
    ur.user_role_id,
    ur.scope_type,
    ur.org_unit_id,
    ur.location_id,
    now()
  from public.user_roles ur
  join public.locations loc
    on loc.operator_id = ur.operator_id
   and loc.deleted_at is null
   and loc.suspended_at is null
   and not exists (
     select 1
       from public.org_units inactive_ancestor
      where inactive_ancestor.operator_id = loc.operator_id
        and (
          inactive_ancestor.deleted_at is not null
          or inactive_ancestor.suspended_at is not null
        )
        and loc.org_unit_path <@ inactive_ancestor.path
   )
  left join public.org_units ou
    on ou.operator_id = ur.operator_id
   and ou.id = ur.org_unit_id
   and ou.deleted_at is null
   and ou.suspended_at is null
  where ur.user_id = p_user_id
    and ur.operator_id = p_operator_id
    and ur.revoked_at is null
    and ur.valid_from <= now()
    and (ur.valid_until is null or ur.valid_until > now())
    and (
      ur.scope_type = 'operator_wide'
      or (ur.scope_type = 'location' and loc.location_id = ur.location_id)
      or (
        ur.scope_type = 'org_unit'
        and ou.id is not null
        and loc.org_unit_path <@ ou.path
      )
    );
end;
$$;

drop trigger if exists locations_update_refresh_effective_locations
  on public.locations;
create trigger locations_update_refresh_effective_locations
after update of parent_org_unit_id, org_unit_path, suspended_at, deleted_at
on public.locations
for each row execute function public.refresh_user_effective_locations_from_location();

drop trigger if exists org_units_update_refresh_effective_locations
  on public.org_units;
create trigger org_units_update_refresh_effective_locations
after update of parent_id, path, suspended_at, deleted_at
on public.org_units
for each row execute function public.refresh_user_effective_locations_from_org_unit();

select public.refresh_user_effective_locations_for_operator(op.operator_id)
  from public.operators op;

commit;
