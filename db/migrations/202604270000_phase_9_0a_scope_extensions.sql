-- Phase 9.0a - Multi-location scale-flow extensions.
--
-- Three small-but-cheap-now / expensive-later schema additions plus the
-- team.* permission key category needed by 9.10 operator-facing
-- Settings → Team UX. Runs anytime after 9.0 accepts; must run before
-- cutover.4 (production schema flexibility ends there).
--
-- Idempotent: safe to re-run on local + staging + Production1 (all
-- still empty of operator data, so backfill is near-zero).
--
-- Mirrors:
--   * lib/auth/permission_keys.dart (the constants + PermissionKeys.all)
--   * docs/contracts/auth_permission_key_catalog.md (operator-facing
--     description per key)

begin;

-- ─── user_roles.scope_type ────────────────────────────────────────────
--
-- Explicit "operator-wide" vs. "location" scope marker. Today the
-- convention is `location_id IS NULL` → operator-wide, fragile and
-- breaks indexing. Pattern matches Toast's group-vs-location grant
-- distinction and 7shifts' multi-location manager pattern.

alter table public.user_roles
  add column if not exists scope_type text;

update public.user_roles
   set scope_type = case
       when location_id is null then 'operator_wide'
       else 'location'
     end
 where scope_type is null;

alter table public.user_roles
  alter column scope_type set not null;

alter table public.user_roles
  drop constraint if exists user_roles_scope_type_check;

alter table public.user_roles
  add constraint user_roles_scope_type_check
  check (scope_type in ('operator_wide', 'location'));

-- Tenant-leading index for scope_type lookups; operator_id LEADS so
-- per-tenant RLS evaluation stays cheap.
create index if not exists user_roles_operator_scope_idx
  on public.user_roles (operator_id, scope_type, user_id);

-- ─── users.primary_location_id ────────────────────────────────────────
--
-- Denormalized default-context for operator-app greeting + default
-- filter on team / shift / variance screens. Saves a join on every
-- page load. Nullable while operator data is empty; trigger that
-- maintains it when user_roles changes is a follow-up — for now the
-- proxy writes it directly when the operator picks a default.

alter table public.users
  add column if not exists primary_location_id uuid null;

-- Composite FK rejects (operator_a, location_b) mismatches. NULL
-- primary_location_id passes (no FK applied) so single-location
-- operators don't need to set it explicitly.
alter table public.users
  drop constraint if exists users_primary_location_fk;

-- Note: users.operator_id was added in 11a.11c.x; if that column
-- doesn't exist this constraint is skipped. The proxy validates
-- the (operator_id, primary_location_id) pair at write time as
-- defense-in-depth.
do $$
begin
  if exists (
    select 1
      from information_schema.columns
     where table_schema = 'public'
       and table_name = 'users'
       and column_name = 'operator_id'
  ) then
    execute $sql$
      alter table public.users
        add constraint users_primary_location_fk
        foreign key (operator_id, primary_location_id)
        references public.locations(operator_id, location_id)
        on delete set null
    $sql$;
  end if;
end;
$$;

-- ─── operators.region ────────────────────────────────────────────────
--
-- Multi-region forward-compat. Most B2B SaaS evolve to regional
-- multi-tenancy; reserve column now even if single-region today.
-- Cheap to add empty; expensive to backfill later.

alter table public.operators
  add column if not exists region text null;

-- ─── team.* permission keys ──────────────────────────────────────────
--
-- New 'team' category for operator-facing Settings → Team UX (9.10).
-- Distinct from 'admin' which gates F&F-side admin paths. An
-- operator_owner can manage team without holding admin.* keys.

insert into public.permission_keys (key, category, description, requires_mfa, frozen)
values
  ('team.users.view', 'team',
   'View the operator''s user list.', false, true),
  ('team.users.invite', 'team',
   'Create invites for users in own operator.', false, true),
  ('team.users.deactivate', 'team',
   'Suspend a user in own operator.', false, true),
  ('team.users.reactivate', 'team',
   'Reactivate a suspended user in own operator.', false, true),
  ('team.users.soft_delete', 'team',
   'Soft-delete a user in own operator.', false, true),
  ('team.users.reset_password', 'team',
   'Admin-initiated password reset for a team member.', false, true),
  ('team.roles.view', 'team',
   'View the operator''s role list.', false, true),
  ('team.roles.create_custom', 'team',
   'Create operator-scoped custom role.', false, true),
  ('team.roles.assign', 'team',
   'Grant role to user within own operator.', false, true),
  ('team.roles.revoke', 'team',
   'Revoke role from user within own operator.', false, true),
  ('team.audit_log.view', 'team',
   'View audit log scoped to own operator.', false, true),
  ('team.session.force_logout', 'team',
   'Force-logout a user''s sessions within own operator.', false, true)
on conflict (key) do nothing;

-- ─── baseline role grants ────────────────────────────────────────────
--
-- super_admin already gets every key via the existing seed
-- cross-join. Operator_owner gets ALL team.* keys; operator_manager
-- gets the manager-tier subset (no custom role creation, no soft
-- delete).

-- operator_owner: all team.* keys
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'operator_owner'
   and r.is_seeded = true
   and r.operator_id is null
   and pk.category = 'team'
on conflict (role_id, permission_key) do nothing;

-- operator_manager: subset
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  cross join public.permission_keys pk
 where r.role_key = 'operator_manager'
   and r.is_seeded = true
   and r.operator_id is null
   and pk.key in (
     'team.users.view',
     'team.users.invite',
     'team.users.reactivate',
     'team.users.reset_password',
     'team.roles.view',
     'team.roles.assign',
     'team.roles.revoke',
     'team.audit_log.view',
     'team.session.force_logout'
   )
on conflict (role_id, permission_key) do nothing;

commit;
