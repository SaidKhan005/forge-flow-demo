-- Wave 2 RP-9 — Default Role Catalog admin permission keys.
--
-- Authority:
--   * docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md RP-9
--     ("Admin can edit Default-role permissions across F&F; this
--     itself is a permission"). Verification worker flagged that the
--     `default_role_catalog_admin_screen.dart` admin surface was
--     gated by role tier (`super_admin` write, `ff_support` read-only)
--     but not represented as a granular permission key in the catalog.
--   * docs/contracts/auth_permission_key_catalog.md `team.*` table —
--     this migration mirrors the two new rows
--     `team.roles.default_catalog.view` and
--     `team.roles.default_catalog.edit`.
--   * lib/auth/permission_keys.dart `teamRolesDefaultCatalogView` /
--     `teamRolesDefaultCatalogEdit` constants — the runtime resolver
--     iterates `PermissionKeys.all`; this migration keeps the seed in
--     lockstep with the Dart catalog mirror.
--   * tool/advisor_proxy/admin_default_role_catalog_routes.dart —
--     `kDefaultRoleCatalogAdminReadRoles` (super_admin + ff_support)
--     and `kDefaultRoleCatalogAdminWriteRoles` (super_admin) define
--     the role tiers this slice promotes to granular permission keys.
--   * CLAUDE.md HP #2 — demo parity. Both keys are global catalog
--     rows (operator_id IS NULL) so demo and production resolve to the
--     same seed without parallel `demo_*` tables.
--
-- Why this exists
-- ---------------
-- The F&F-internal Default Role Catalog admin surface lets a
-- `super_admin` publish a new template that every new operator's seeded
-- role set is minted from. `ff_support` lands on a read-only branch.
-- Before this slice the gate lived only in two places:
--   1. `tool/advisor_proxy/admin_default_role_catalog_routes.dart` role
--      tier sets (the proxy gate).
--   2. `lib/admin/admin_routes.dart` `_buildDefaultRoleCatalog`
--      builder (`session.roles.contains('super_admin')` decides the
--      `editingEnabled` flag).
-- Neither layer registered the gate as a granular permission key in
-- `public.permission_keys`, so the catalog mirror disagreed with the
-- runtime authority. This migration closes the gap by adding two
-- permission keys + baseline grants. The proxy + route layers continue
-- to enforce role-tier checks as defense-in-depth fallbacks.
--
-- Frozen + non-MFA: like every other `team.*` key at launch, neither
-- new key is MFA-required at the catalog level. The Default Role
-- Catalog admin route inherits the admin-console MFA freshness gate
-- through `AdminAuthSession.lastFreshAuthAt` — no per-key freshness
-- claim is needed here. The grant set stays narrow (super_admin only
-- for `edit`; super_admin + ff_support for `view`) so widening the
-- gate accidentally is not possible without an explicit code change.
--
-- HP #4 carve-out: this is F&F-internal admin scope. Do NOT widen the
-- baseline grants to operator-tier roles (`operator_owner`,
-- `operator_admin`, manager / supervisor / staff). Publishing a new
-- default catalog version affects every operator in the F&F
-- deployment, so the write gate is F&F super-admin-only by design.
--
-- CLAUDE.md compliance
-- --------------------
--   * Migrations are idempotent: ON CONFLICT DO NOTHING on both the
--     permission_keys insert and the role_permissions grants.
--   * Operator-scoped or admin-scoped? Permission keys are global
--     (see `db/migrations/202604250008_auth_schema_foundation.sql`).
--     `public.permission_keys` has no `operator_id`; the per-tenant
--     join lives in `public.user_roles` x `public.role_permissions`.
--   * R-1L / R-2L mirror columns (`product_label`, `category_label`,
--     `scope_kind`, `human_label`) are populated inline because this
--     migration runs after the R-1L schema-rewrite and R-2L human-label
--     backfill — leaving them NULL would trip the eventual NOT NULL
--     flip and the lint's HUMAN_LABEL_INVALID pass on the Dart side.
--   * After migration: `tool/migration_drift_scanner.dart --fix
--     --strict-docs` and `tool/migration_cutoff_lint.dart`.
--
-- Precedent
-- ---------
--   * `202605140000_w_3_self_profile_perm_key.sql` for the `team.*`
--     insert shape + baseline-grant cross-join. The W-3 slice ran
--     BEFORE the R-1L schema rewrite so it did not need to populate
--     the new metadata columns; this slice runs AFTER R-1L + R-2L and
--     fills them in the same migration.
--   * `202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql`
--     for the F&F-internal-only baseline grant pattern (super_admin
--     only; no operator-tier widening).

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- =================================================================
-- Step 1: permission key seed
-- =================================================================
--
-- Insert both keys. Both are operator-self-service in the `team.*`
-- category for catalog-grouping purposes (so the R-2L editor renders
-- them in the same product section as the other team.roles.* keys),
-- but the baseline grants below scope them to F&F-internal roles only.
-- `frozen = true` matches every other catalog row added since 9.0.

insert into public.permission_keys (
  key, category, description, requires_mfa, frozen,
  product_label, category_label, scope_kind, human_label
)
values
  (
    'team.roles.default_catalog.view',
    'team',
    'View the F&F Default Role Catalog template - read-only access to the seeded role set every new operator begins with. F&F super_admin + ff_support only.',
    false, true,
    'team', 'Team management', 'org_wide',
    'View the Default Role Catalog template'
  ),
  (
    'team.roles.default_catalog.edit',
    'team',
    'Edits the F&F Default Role Catalog template - adds, renames, or removes seeded roles for new operators. F&F super_admin only.',
    false, true,
    'team', 'Team management', 'org_wide',
    'Edit the Default Role Catalog template'
  )
on conflict (key) do nothing;

-- =================================================================
-- Step 2: implies graph backfill
-- =================================================================
--
-- The `edit` key implies the `view` key. Mirrors the R-1L view-required-
-- for-write pattern in the metadata catalog. The UPDATE is idempotent
-- because re-running the migration just re-writes the same array. We
-- use a guard on the current value to make the operation a true no-op
-- if the migration has already run on this database.

update public.permission_keys
   set implies = array['team.roles.default_catalog.view']
 where key = 'team.roles.default_catalog.edit'
   and (implies is null
        or not implies @> array['team.roles.default_catalog.view']);

-- =================================================================
-- Step 3: baseline role grants
-- =================================================================
--
-- Constraints (DO NOT WEAKEN without an explicit code change):
--   * `team.roles.default_catalog.view` -> super_admin + ff_support.
--     ff_support read-only branch of the admin route is the only
--     non-super_admin consumer.
--   * `team.roles.default_catalog.edit` -> super_admin ONLY.
--     Publishing a new default catalog version is a global F&F-
--     deployment-wide event. Widening to operator-tier roles would
--     let an operator owner overwrite the template every other
--     operator inherits from.
--
-- Note that the 9.0 foundation migration's `super_admin` cross-join
-- already grants every catalog row to super_admin, but THAT cross-join
-- ran once at seed time. New keys added after the seed need an
-- explicit super_admin grant so the "every catalog key" invariant
-- holds for the audit log + permission resolver.

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, 'team.roles.default_catalog.view', 'allow'
  from public.roles r
 where r.role_key in ('super_admin', 'ff_support')
   and r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, 'team.roles.default_catalog.edit', 'allow'
  from public.roles r
 where r.role_key = 'super_admin'
   and r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

commit;
