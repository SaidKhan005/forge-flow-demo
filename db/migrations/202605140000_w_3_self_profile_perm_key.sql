-- Wave 2 W-3 — self-service profile editing permission key.
--
-- Authority:
--   * docs/_indices/WAVE_2_LEDGER.md Lane W row W-3 — self-service
--     profile write paths (debug.md:45-52, P-1 / P-2 / P-3, MO-6c/d).
--   * docs/contracts/auth_permission_key_catalog.md `team.*` table —
--     this migration mirrors the new row.
--   * lib/auth/permission_keys.dart `teamUsersSelfUpdate` constant —
--     the runtime resolver iterates `PermissionKeys.all`; this row
--     keeps the seed in lockstep.
--
-- Why this exists
-- ---------------
-- The customer "My Account" surface (operator-web and admin) ships
-- editable display name + email fields in W-3. The proxy route
-- `PATCH /v1/auth/self/profile` gates on this new self-edit key.
-- The slice deliberately AVOIDS widening `team.users.invite` (which
-- gates admin-editing-someone-else) — self-edit is a distinct gate.
-- Every signed-in operator role gets this key by default because
-- anyone with a sign-in can update their own profile.
--
-- Frozen + non-MFA: per the catalog doc, no `team.*` key is flagged
-- MFA-required at the catalog level today. Route-level freshness for
-- email change is layered on top via the existing fresh-MFA window
-- the security section already enforces.
--
-- CLAUDE.md compliance
-- --------------------
--   * Migrations are idempotent: ON CONFLICT DO NOTHING on both the
--     permission_keys insert and the role_permissions grants.
--   * Operator-scoped or admin-scoped? Permission keys are global
--     (see `db/migrations/202604250008_auth_schema_foundation.sql`).
--     `public.permission_keys` has no operator_id; the per-tenant
--     join lives in `public.user_roles` × `public.role_permissions`.
--   * After migration: `tool/migration_drift_scanner.dart --fix --strict-docs`
--     and `tool/migration_cutoff_lint.dart`.
--
-- Precedent: 202604270000_phase_9_0a_scope_extensions.sql for the
-- `team.*` insert shape + baseline-grant cross-join.

begin;

-- ─── permission key seed ─────────────────────────────────────────────

insert into public.permission_keys (key, category, description, requires_mfa, frozen)
values
  ('team.users.self_update', 'team',
   'Change your own display name or email from My Account. Distinct from team.users.invite which gates editing someone else.',
   false, true)
on conflict (key) do nothing;

-- ─── baseline role grants ────────────────────────────────────────────
--
-- super_admin already inherits every key via the 9.0 seed cross-join.
-- The non-super seeded roles get this key explicitly because self-edit
-- is universal at launch: anyone with a sign-in can manage their own
-- profile. operator_supervisor and operator_staff are added here too;
-- they are intentionally NOT in `team.users.invite` because admin-
-- editing-someone-else stays a senior-role action.

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, 'team.users.self_update', 'allow'
  from public.roles r
 where r.role_key in (
     'operator_owner',
     'operator_admin',
     'operator_manager',
     'operator_supervisor',
     'operator_staff'
   )
   and r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

-- super_admin: ensure the global admin keeps the "every catalog key"
-- invariant. The 9.0 seed cross-join only ran once; new keys added
-- after the seed need an explicit grant.
insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, 'team.users.self_update', 'allow'
  from public.roles r
 where r.role_key = 'super_admin'
   and r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

commit;
