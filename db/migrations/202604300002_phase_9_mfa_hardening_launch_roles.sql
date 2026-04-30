-- Phase 9 MFA hardening and launch account role enforcement.
--
-- Goals:
--   * Add a dedicated team.users.reset_mfa permission for delayed 2FA
--     removal/reset actions instead of piggybacking on password reset.
--   * Grant that permission to super_admin and operator_owner only.
--   * Make the launch smoke-account roles durable in database migrations:
--       - saidumarkhan005@gmail.com is the highest admin account.
--       - newoundlandlimited@gmail.com is a regular operator staff user.
--
-- This migration is idempotent. If either launch account is absent in a
-- non-production database, it emits a NOTICE and skips only the account
-- repair block; the permission catalog change still applies.

begin;

insert into public.permission_keys (
  key,
  category,
  description,
  requires_mfa,
  frozen
)
values (
  'team.users.reset_mfa',
  'team',
  'Start or cancel delayed authenticator-app removal for a team member after fresh authentication.',
  false,
  true
)
on conflict (key) do update
   set category = excluded.category,
       description = excluded.description,
       requires_mfa = excluded.requires_mfa,
       frozen = excluded.frozen,
       updated_at = now();

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, 'team.users.reset_mfa', 'allow'
  from public.roles r
 where r.operator_id is null
   and r.role_key in ('super_admin', 'operator_owner')
on conflict (role_id, permission_key) do update
   set effect = excluded.effect,
       updated_at = now();

do $$
declare
  admin_email constant text := 'saidumarkhan005@gmail.com';
  regular_email constant text := 'newoundlandlimited@gmail.com';

  admin_user_id uuid;
  regular_user_id uuid;
  regular_operator_id uuid;
  regular_location_id uuid;

  admin_role_id uuid;
  staff_role_id uuid;
  staff_scope text;

  regular_revoked integer := 0;
  regular_staff_inserted integer := 0;
  regular_admin_deleted integer := 0;
  regular_user_bumped integer := 0;
  admin_grant_inserted integer := 0;
  admin_operator_changed integer := 0;
  admin_user_bumped integer := 0;
begin
  select u.user_id
    into admin_user_id
    from public.users u
   where lower(u.email) = admin_email
     and u.deleted_at is null
   limit 1;

  if admin_user_id is null then
    raise notice 'launch account role enforcement skipped: admin account % was not found',
      admin_email;
    return;
  end if;

  select u.user_id,
         u.operator_id,
         coalesce(u.primary_location_id, o.primary_location_id)
    into regular_user_id,
         regular_operator_id,
         regular_location_id
    from public.users u
    left join public.operators o on o.operator_id = u.operator_id
   where lower(u.email) = regular_email
     and u.deleted_at is null
   limit 1;

  if regular_user_id is null then
    raise notice 'launch account role enforcement skipped: regular account % was not found',
      regular_email;
    return;
  end if;

  if regular_operator_id is null then
    raise notice 'launch account role enforcement skipped: regular account % has no operator_id',
      regular_email;
    return;
  end if;

  select r.role_id
    into admin_role_id
    from public.roles r
   where r.operator_id is null
     and r.role_key = 'super_admin'
     and r.deleted_at is null
   limit 1;

  if admin_role_id is null then
    raise exception 'seeded role super_admin was not found';
  end if;

  select r.role_id
    into staff_role_id
    from public.roles r
   where r.operator_id is null
     and r.role_key = 'operator_staff'
     and r.deleted_at is null
   limit 1;

  if staff_role_id is null then
    raise exception 'seeded role operator_staff was not found';
  end if;

  staff_scope := case
    when regular_location_id is null then 'operator_wide'
    else 'location'
  end;

  update public.user_roles ur
     set revoked_at = now(),
         revoked_by = admin_user_id,
         reason = 'launch account role enforcement: regular account is not admin',
         updated_at = now()
    from public.roles r
   where ur.role_id = r.role_id
     and ur.user_id = regular_user_id
     and ur.revoked_at is null
     and r.role_key in (
       'super_admin',
       'ff_support',
       'operator_owner',
       'operator_manager',
       'operator_supervisor'
     );
  get diagnostics regular_revoked = row_count;

  with inserted as (
    insert into public.user_roles (
      user_role_id,
      user_id,
      role_id,
      operator_id,
      location_id,
      org_unit_id,
      scope_type,
      valid_from,
      valid_until,
      granted_by,
      reason,
      created_at,
      updated_at
    )
    select gen_random_uuid(),
           regular_user_id,
           staff_role_id,
           regular_operator_id,
           regular_location_id,
           null,
           staff_scope,
           now(),
           null,
           admin_user_id,
           'launch account role enforcement: regular account staff role',
           now(),
           now()
     where not exists (
       select 1
         from public.user_roles existing
        where existing.user_id = regular_user_id
          and existing.operator_id = regular_operator_id
          and existing.role_id = staff_role_id
          and existing.revoked_at is null
          and coalesce(
            existing.location_id,
            '00000000-0000-0000-0000-000000000000'::uuid
          ) = coalesce(
            regular_location_id,
            '00000000-0000-0000-0000-000000000000'::uuid
          )
     )
    returning 1
  )
  select count(*) into regular_staff_inserted from inserted;

  delete from public.operator_admins
   where user_id = regular_user_id;
  get diagnostics regular_admin_deleted = row_count;

  update public.users
     set primary_role_id = staff_role_id,
         roles_version = roles_version + 1,
         updated_at = now()
   where user_id = regular_user_id
     and (
       primary_role_id is distinct from staff_role_id
       or regular_revoked > 0
       or regular_staff_inserted > 0
       or regular_admin_deleted > 0
     );
  get diagnostics regular_user_bumped = row_count;

  with inserted as (
    insert into public.user_roles (
      user_role_id,
      user_id,
      role_id,
      operator_id,
      location_id,
      org_unit_id,
      scope_type,
      valid_from,
      valid_until,
      granted_by,
      reason,
      created_at,
      updated_at
    )
    select gen_random_uuid(),
           admin_user_id,
           admin_role_id,
           regular_operator_id,
           null,
           null,
           'operator_wide',
           now(),
           null,
           admin_user_id,
           'launch account role enforcement: highest admin account',
           now(),
           now()
     where not exists (
       select 1
         from public.user_roles existing
        where existing.user_id = admin_user_id
          and existing.operator_id = regular_operator_id
          and existing.role_id = admin_role_id
          and existing.location_id is null
          and existing.revoked_at is null
     )
    returning 1
  )
  select count(*) into admin_grant_inserted from inserted;

  with changed as (
    insert into public.operator_admins (
      user_id,
      operator_id,
      is_super_admin,
      scope_type,
      scope_location_id,
      valid_from,
      valid_until,
      created_at,
      updated_at
    )
    values (
      admin_user_id,
      regular_operator_id,
      true,
      'super_admin',
      null,
      now(),
      null,
      now(),
      now()
    )
    on conflict (user_id, operator_id) do update
       set is_super_admin = true,
           scope_type = 'super_admin',
           scope_location_id = null,
           valid_until = null,
           updated_at = now()
     where public.operator_admins.is_super_admin is distinct from true
        or public.operator_admins.scope_type is distinct from 'super_admin'
        or public.operator_admins.scope_location_id is not null
        or public.operator_admins.valid_until is not null
    returning 1
  )
  select count(*) into admin_operator_changed from changed;

  update public.users
     set primary_role_id = admin_role_id,
         roles_version = roles_version + 1,
         updated_at = now()
   where user_id = admin_user_id
     and (
       primary_role_id is distinct from admin_role_id
       or admin_grant_inserted > 0
       or admin_operator_changed > 0
     );
  get diagnostics admin_user_bumped = row_count;

  raise notice 'launch account roles enforced: admin %, regular %, operator %, admin grant inserts %, admin assignment changes %, regular admin revokes %, regular staff inserts %, regular admin deletes %, user bumps admin/regular %/%',
    admin_email,
    regular_email,
    regular_operator_id,
    admin_grant_inserted,
    admin_operator_changed,
    regular_revoked,
    regular_staff_inserted,
    regular_admin_deleted,
    admin_user_bumped,
    regular_user_bumped;
end
$$;

commit;
