-- Slice E (2026-05-23) — additive permission-key catalog rows for the
-- F&F-internal "Business accounts" admin hierarchy mutations.
--
-- The F&F admin "Business accounts" console mutates operator hierarchy
-- (org-units + locations). This slice seeds five NEW frozen permission
-- keys that a LATER slice will use to gate those admin-side mutations:
--
--   admin.hierarchy.create   — create org-units / locations
--   admin.hierarchy.move     — move nodes within the tree
--   admin.hierarchy.rename   — rename nodes
--   admin.hierarchy.suspend  — suspend / reactivate nodes  (MFA)
--   admin.hierarchy.delete   — delete nodes / empty locations (MFA)
--
-- DORMANT at this slice. The keys are present in `PermissionKeys.all`
-- (set membership satisfies the orphan lint), seeded here, and granted
-- to `super_admin` + `ff_support`, but NO gateway/screen consumes them
-- yet — wiring the "Business accounts" admin path to these keys is a
-- separate follow-up slice. Seeding a key ahead of its consumer is safe:
-- an ungated key changes no behaviour until a gate checks it.
--
-- These are DISTINCT from the existing operator-self-service
-- `team.hierarchy.suspend` / `team.hierarchy.delete` keys (seeded by
-- `202605082200_admin_hierarchy_lifecycle.sql`), which gate an operator
-- managing their OWN hierarchy and default-grant to
-- `super_admin` + `operator_owner`. The new `admin.hierarchy.*` keys
-- gate the F&F-INTERNAL cross-operator admin path and default-grant to
-- `super_admin` + `ff_support` only — NOT operator-tier roles.
--
-- MFA decision (operator-authorized): `admin.hierarchy.suspend` and
-- `admin.hierarchy.delete` carry `requires_mfa = true` (destructive
-- admin posture; mirrors `admin.users.erase_pii` /
-- `admin.users.reset_mfa_factors`). `admin.hierarchy.create`,
-- `admin.hierarchy.move`, and `admin.hierarchy.rename` carry
-- `requires_mfa = false` (additive / reversible structural edits). The
-- runtime resolver refuses to admit an MFA-flagged key unless the
-- caller's session has a fresh `auth_time` MFA assertion, so granting
-- suspend/delete to a role does not weaken the gate.
--
-- Hard rules carried from CLAUDE.md and the catalog contract
-- (`docs/contracts/auth_permission_key_catalog.md`):
--
--   * Permission keys are app-defined and frozen at code level. The
--     catalog seeded here mirrors `lib/auth/permission_keys.dart`,
--     `lib/auth/permission_key_metadata.dart`, and the catalog contract
--     doc. Descriptions below byte-match the catalog doc rows. Operators
--     may not invent new keys at runtime; `frozen = true` on every row.
--
--   * Additive only — a single INSERT into `permission_keys` with
--     `on conflict (key) do nothing`, plus an idempotent default
--     role-grant insert for the two seeded F&F-internal roles. Re-
--     applying the migration is a no-op.
--
--   * No live database mutation here. Live apply on staging + Production1
--     is queued under the Phase 9 live-mutation gate.

begin;

-- ─── Seed the five admin.hierarchy.* permission keys ───────────────
--
-- `frozen = true` matches every other catalog row — the catalog is a
-- code-level contract, not a runtime-mutable table. `requires_mfa` per
-- the MFA decision above: true for suspend/delete, false for the
-- additive create/move/rename edits.

insert into public.permission_keys (
  key, category, description, requires_mfa, frozen
)
values
  (
    'admin.hierarchy.create',
    'admin',
    'Create operator hierarchy nodes (org-units and locations) from the '
    'F&F admin "Business accounts" console.',
    false,
    true
  ),
  (
    'admin.hierarchy.move',
    'admin',
    'Move operator hierarchy nodes (org-units and locations) within the '
    'tree from the F&F admin "Business accounts" console.',
    false,
    true
  ),
  (
    'admin.hierarchy.rename',
    'admin',
    'Rename operator hierarchy nodes (org-units and locations) from the '
    'F&F admin "Business accounts" console.',
    false,
    true
  ),
  (
    'admin.hierarchy.suspend',
    'admin',
    'Suspend or reactivate operator hierarchy nodes (org-units and '
    'locations) from the F&F admin "Business accounts" console. MFA '
    'required.',
    true,
    true
  ),
  (
    'admin.hierarchy.delete',
    'admin',
    'Delete operator hierarchy nodes (org-units and empty locations) from '
    'the F&F admin "Business accounts" console. MFA required.',
    true,
    true
  )
on conflict (key) do nothing;

-- ─── Default role grants (super_admin + ff_support only) ───────────
--
-- super_admin already gets every key via the cross-join seed in
-- `202604250008_auth_schema_foundation.sql`, but that seed runs once at
-- 9.0 apply time. A re-applied 9.0 migration would NOT re-add newly-
-- introduced catalog keys to super_admin; this explicit grant keeps
-- super_admin's "every key" invariant true even when the foundation
-- migration was applied before these keys existed.
--
-- ff_support is granted explicitly because cross-operator hierarchy
-- administration from the "Business accounts" console is an F&F-internal
-- support action ff_support owns. The runtime resolver still refuses to
-- admit the two MFA-flagged keys (suspend/delete) without an MFA-fresh
-- token, so granting them to ff_support does not weaken the gate.
--
-- Operator-tier roles are deliberately omitted. The operator-side
-- equivalent for an operator managing its OWN hierarchy is the
-- `team.hierarchy.*` key family; the `admin.hierarchy.*` keys are
-- F&F-internal cross-operator administration.

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, pk.key, 'allow'
  from public.roles r
  join public.permission_keys pk
    on pk.key in (
      'admin.hierarchy.create',
      'admin.hierarchy.move',
      'admin.hierarchy.rename',
      'admin.hierarchy.suspend',
      'admin.hierarchy.delete'
    )
 where r.role_key in ('super_admin', 'ff_support')
   and r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

commit;
