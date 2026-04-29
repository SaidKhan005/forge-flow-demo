-- Phase 9 hierarchy access wiring.
--
-- The Phase 9 scalability decision lock added `org_units` as the operator
-- hierarchy foundation, but the auth/team grant path was still wired only for
-- operator-wide and direct-location scopes. This migration bridges that gap:
--
--   * locations attach to an org unit and carry a denormalized ltree path
--   * user_roles/auth_invites can target an org unit scope
--   * user_effective_locations materializes which locations each active grant
--     reaches, including org-unit inheritance
--
-- Idempotent and additive. Existing single-location/operator-wide rows are
-- backfilled to the operator root org unit and continue to behave exactly as
-- they did before this migration.

begin;

-- `org_units.path` already required ltree, but keep this file self-contained
-- for fresh local databases that apply only the tail migration during tests.
create extension if not exists ltree;

-- ---------------------------------------------------------------------------
-- Locations -> org_units
-- ---------------------------------------------------------------------------

alter table public.locations
  add column if not exists parent_org_unit_id uuid null;

alter table public.locations
  add column if not exists org_unit_path ltree null;

update public.locations loc
   set parent_org_unit_id = root.id,
       org_unit_path = root.path
  from public.org_units root
 where root.operator_id = loc.operator_id
   and root.parent_id is null
   and (loc.parent_org_unit_id is null or loc.org_unit_path is null);

alter table public.locations
  alter column parent_org_unit_id set not null;

alter table public.locations
  alter column org_unit_path set not null;

alter table public.locations
  drop constraint if exists locations_parent_org_unit_fk;

alter table public.locations
  add constraint locations_parent_org_unit_fk
  foreign key (operator_id, parent_org_unit_id)
  references public.org_units(operator_id, id);

create index if not exists locations_operator_parent_org_unit_idx
  on public.locations (operator_id, parent_org_unit_id);

create index if not exists locations_org_unit_path_gist_idx
  on public.locations using gist (org_unit_path);

create or replace function public.set_location_org_unit_path()
returns trigger
language plpgsql
as $$
declare
  selected_path ltree;
begin
  select ou.path
    into selected_path
    from public.org_units ou
   where ou.operator_id = new.operator_id
     and ou.id = new.parent_org_unit_id;

  if selected_path is null then
    raise exception
      'parent_org_unit_id % does not belong to operator_id %',
      new.parent_org_unit_id, new.operator_id
      using errcode = '23503';
  end if;

  new.org_unit_path := selected_path;
  return new;
end;
$$;

drop trigger if exists locations_set_org_unit_path on public.locations;
create trigger locations_set_org_unit_path
before insert or update of operator_id, parent_org_unit_id
on public.locations
for each row execute function public.set_location_org_unit_path();

comment on column public.locations.parent_org_unit_id is
  'Phase 9 hierarchy wiring. Physical location parent in org_units; same-operator composite FK.';

comment on column public.locations.org_unit_path is
  'Phase 9 hierarchy wiring. Denormalized org_units.path for subtree access checks and historical/reporting scope snapshots.';

-- ---------------------------------------------------------------------------
-- Role/invite scopes: operator_wide | org_unit | location
-- ---------------------------------------------------------------------------

alter table public.user_roles
  add column if not exists org_unit_id uuid null;

alter table public.user_roles
  drop constraint if exists user_roles_org_unit_fk;

alter table public.user_roles
  add constraint user_roles_org_unit_fk
  foreign key (operator_id, org_unit_id)
  references public.org_units(operator_id, id)
  on delete cascade;

alter table public.user_roles
  drop constraint if exists user_roles_scope_type_check;

alter table public.user_roles
  add constraint user_roles_scope_type_check
  check (scope_type in ('operator_wide', 'org_unit', 'location'));

alter table public.user_roles
  drop constraint if exists user_roles_scope_payload_check;

alter table public.user_roles
  add constraint user_roles_scope_payload_check
  check (
    (scope_type = 'operator_wide' and location_id is null and org_unit_id is null)
    or
    (scope_type = 'org_unit' and location_id is null and org_unit_id is not null)
    or
    (scope_type = 'location' and location_id is not null and org_unit_id is null)
  );

drop index if exists public.user_roles_active_grant_idx;

create unique index if not exists user_roles_active_grant_idx
  on public.user_roles (
    operator_id,
    user_id,
    role_id,
    scope_type,
    coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(org_unit_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where revoked_at is null;

create index if not exists user_roles_operator_org_unit_idx
  on public.user_roles (operator_id, org_unit_id, user_id)
  where scope_type = 'org_unit' and revoked_at is null;

alter table public.auth_invites
  add column if not exists scope_type text null;

alter table public.auth_invites
  add column if not exists org_unit_id uuid null;

update public.auth_invites
   set scope_type = case
     when location_id is null then 'operator_wide'
     else 'location'
   end
 where scope_type is null;

alter table public.auth_invites
  alter column scope_type set not null;

alter table public.auth_invites
  drop constraint if exists auth_invites_scope_type_check;

alter table public.auth_invites
  add constraint auth_invites_scope_type_check
  check (scope_type in ('operator_wide', 'org_unit', 'location'));

alter table public.auth_invites
  drop constraint if exists auth_invites_org_unit_fk;

alter table public.auth_invites
  add constraint auth_invites_org_unit_fk
  foreign key (operator_id, org_unit_id)
  references public.org_units(operator_id, id)
  on delete cascade;

alter table public.auth_invites
  drop constraint if exists auth_invites_scope_payload_check;

alter table public.auth_invites
  add constraint auth_invites_scope_payload_check
  check (
    (scope_type = 'operator_wide' and location_id is null and org_unit_id is null)
    or
    (scope_type = 'org_unit' and location_id is null and org_unit_id is not null)
    or
    (scope_type = 'location' and location_id is not null and org_unit_id is null)
  );

create index if not exists auth_invites_operator_org_unit_idx
  on public.auth_invites (operator_id, org_unit_id, expires_at)
  where scope_type = 'org_unit' and accepted_at is null and revoked_at is null;

comment on column public.user_roles.org_unit_id is
  'Phase 9 hierarchy wiring. Non-null only when scope_type = org_unit; grant inherits to descendant locations.';

comment on column public.auth_invites.org_unit_id is
  'Phase 9 hierarchy wiring. Non-null only when scope_type = org_unit; accepted invite creates an org-unit scoped grant.';

-- ---------------------------------------------------------------------------
-- Effective-location cache
-- ---------------------------------------------------------------------------

create table if not exists public.user_effective_locations (
  user_effective_location_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  location_id uuid not null,
  source_user_role_id uuid not null references public.user_roles(user_role_id)
    on delete cascade,
  source_scope_type text not null
    check (source_scope_type in ('operator_wide', 'org_unit', 'location')),
  source_org_unit_id uuid null,
  source_location_id uuid null,
  computed_at timestamptz not null default now(),
  unique (operator_id, user_id, location_id, source_user_role_id),
  constraint user_effective_locations_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint user_effective_locations_source_org_unit_fk
    foreign key (operator_id, source_org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint user_effective_locations_source_location_fk
    foreign key (operator_id, source_location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

create index if not exists user_effective_locations_lookup_idx
  on public.user_effective_locations (operator_id, user_id, location_id);

create index if not exists user_effective_locations_source_grant_idx
  on public.user_effective_locations (operator_id, source_user_role_id);

alter table public.user_effective_locations enable row level security;

drop policy if exists "user_effective_locations_per_tenant"
  on public.user_effective_locations;

create policy "user_effective_locations_per_tenant"
  on public.user_effective_locations for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

grant select, insert, update, delete on public.user_effective_locations to service_role;
grant select, insert, update, delete on public.user_effective_locations to forge_admin;

comment on table public.user_effective_locations is
  'Phase 9 hierarchy wiring. Materialized effective location cache keyed by source user_role grant so org-unit inheritance does not over-broaden unrelated roles.';

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
  left join public.org_units ou
    on ou.operator_id = ur.operator_id
   and ou.id = ur.org_unit_id
  where ur.user_id = p_user_id
    and ur.operator_id = p_operator_id
    and ur.revoked_at is null
    and ur.valid_from <= now()
    and (ur.valid_until is null or ur.valid_until > now())
    and (
      ur.scope_type = 'operator_wide'
      or (ur.scope_type = 'location' and loc.location_id = ur.location_id)
      or (ur.scope_type = 'org_unit' and loc.org_unit_path <@ ou.path)
    );
end;
$$;

create or replace function public.refresh_user_effective_locations_for_operator(
  p_operator_id uuid
)
returns void
language plpgsql
as $$
declare
  target_user uuid;
begin
  for target_user in
    select distinct user_id
      from public.user_roles
     where operator_id = p_operator_id
    union
    select distinct user_id
      from public.user_effective_locations
     where operator_id = p_operator_id
  loop
    perform public.refresh_user_effective_locations(target_user, p_operator_id);
  end loop;
end;
$$;

create or replace function public.refresh_user_effective_locations_from_user_role()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    perform public.refresh_user_effective_locations(
      old.user_id,
      old.operator_id
    );
    return old;
  end if;

  perform public.refresh_user_effective_locations(
    new.user_id,
    new.operator_id
  );
  return new;
end;
$$;

drop trigger if exists user_roles_refresh_effective_locations on public.user_roles;
create trigger user_roles_refresh_effective_locations
after insert or update or delete on public.user_roles
for each row execute function public.refresh_user_effective_locations_from_user_role();

create or replace function public.refresh_user_effective_locations_from_location()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    perform public.refresh_user_effective_locations_for_operator(old.operator_id);
    return old;
  end if;

  perform public.refresh_user_effective_locations_for_operator(
    new.operator_id
  );
  return new;
end;
$$;

drop trigger if exists locations_refresh_effective_locations on public.locations;
drop trigger if exists locations_insert_delete_refresh_effective_locations
  on public.locations;
drop trigger if exists locations_update_refresh_effective_locations
  on public.locations;

create trigger locations_insert_delete_refresh_effective_locations
after insert or delete
on public.locations
for each row execute function public.refresh_user_effective_locations_from_location();

create trigger locations_update_refresh_effective_locations
after update of parent_org_unit_id, org_unit_path
on public.locations
for each row execute function public.refresh_user_effective_locations_from_location();

create or replace function public.refresh_user_effective_locations_from_org_unit()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    perform public.refresh_user_effective_locations_for_operator(old.operator_id);
    return old;
  end if;

  perform public.refresh_user_effective_locations_for_operator(
    new.operator_id
  );
  return new;
end;
$$;

drop trigger if exists org_units_refresh_effective_locations on public.org_units;
drop trigger if exists org_units_delete_refresh_effective_locations
  on public.org_units;
drop trigger if exists org_units_update_refresh_effective_locations
  on public.org_units;

create trigger org_units_delete_refresh_effective_locations
after delete
on public.org_units
for each row execute function public.refresh_user_effective_locations_from_org_unit();

create trigger org_units_update_refresh_effective_locations
after update of parent_id, path
on public.org_units
for each row execute function public.refresh_user_effective_locations_from_org_unit();

select public.refresh_user_effective_locations_for_operator(op.operator_id)
  from public.operators op;

commit;
