-- B5.b - additive permission-key catalog rows for operator settings.
--
-- Seeds the two settings keys that were previously hand-typed by
-- Operator Web screens:
--
--   * account.configure
--   * business_timing.configure
--
-- The rows mirror docs/contracts/auth_permission_key_catalog.md and
-- lib/auth/permission_keys.dart. The migration is additive and
-- idempotent: catalog inserts use ON CONFLICT (key) DO NOTHING and
-- grant inserts use ON CONFLICT (role_id, permission_key) DO NOTHING.
--
-- Grant posture:
--
--   * super_admin gets both keys explicitly so the seeded role keeps
--     the "every catalog key" invariant for keys added after 9.0.
--   * operator_owner and operator_admin (when seeded) get both keys
--     because the account and business-timing write surfaces are
--     owner/admin-owned in the current Operator Web screens and
--     operator-scoped write routes.
--   * operator_manager, operator_supervisor, operator_staff, and
--     ff_support do not receive these configure grants by default.
--
-- Neither key requires MFA at the catalog level. Future route-level
-- freshness gates can be added without changing the grantable key.

begin;

insert into public.permission_keys (
  key, category, description, requires_mfa, frozen
)
values
  (
    'account.configure',
    'account',
    'Configure operator business account identity, locale, currency, '
    'business-week, rollover-hour, and logo settings.',
    false,
    true
  ),
  (
    'business_timing.configure',
    'business_timing',
    'Configure effective-dated business timing profiles, rollover-hour, '
    'week-start, and service periods.',
    false,
    true
  )
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, grants.permission_key, 'allow'
  from public.roles r
  join (
    values
      ('super_admin', 'account.configure'),
      ('operator_owner', 'account.configure'),
      ('operator_admin', 'account.configure'),
      ('super_admin', 'business_timing.configure'),
      ('operator_owner', 'business_timing.configure'),
      ('operator_admin', 'business_timing.configure')
  ) as grants(role_key, permission_key)
    on grants.role_key = r.role_key
 where r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

commit;
