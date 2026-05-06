-- Phase 11W.5 — additive permission-key catalog row for the operator-
-- facing Audit Log CSV export action.
--
-- The 11W.5 Operator Web Audit Log screen
-- (`lib/operator_web/screens/audit_log_screen.dart`) gates its CSV
-- export action on `team.audit_log.export`, but the 9.0a foundation
-- seed only carried `team.audit_log.view` (read access). The export
-- key was referenced by the screen as `kAuditLogExportPermissionKey`
-- but never lived in `permission_keys.dart`, the seed migrations, or
-- the catalog contract — a phantom gate that always fell through to
-- the role-tier fallback. This slice closes the catalog/code/
-- migration keep-in-sync rule (catalog § "Keep in sync") so a real
-- session permission set can carry the key and the export action
-- gets honest authorization.
--
-- Hard rules carried from CLAUDE.md and the catalog contract:
--
--   * Permission keys are app-defined and frozen at code level. The
--     row seeded here mirrors `lib/auth/permission_keys.dart` and
--     `docs/contracts/auth_permission_key_catalog.md`.
--
--   * No MFA gate on `team.*` keys at launch (locked decision in the
--     catalog contract § team.*); export is admin-tier responsibility
--     but not high-trust-recovery. `requires_mfa = false` mirrors the
--     other team.* rows.
--
--   * Default grants seat the key on `operator_owner` AND
--     `operator_admin` only. Manager-tier and below do NOT receive
--     the export grant by default — pulling a full audit trail to
--     CSV is a senior-role action per the parity contract
--     (audit log § Permission gate cheat sheet). Operators can mint
--     custom roles that grant the key via the 9.6 admin endpoints.
--
--   * Migration is additive only — single INSERT into
--     `permission_keys` with `on conflict (key) do nothing`, plus
--     idempotent role-grant inserts. Re-applying the migration is a
--     no-op.
--
--   * No live database mutation. Live apply on staging + Production1
--     is queued under the Phase 9 live-mutation gate.

begin;

-- ─── Seed permission_keys.team.audit_log.export ────────────────────
--
-- `frozen = true` matches every other catalog row. Description copy
-- mirrors the catalog doc + `kPermissionExplainerDescriptions` so a
-- single source of truth carries the operator-facing wording.

insert into public.permission_keys (
  key, category, description, requires_mfa, frozen
)
values
  (
    'team.audit_log.export',
    'team',
    'View and export team audit log entries (CSV).',
    false,
    true
  )
on conflict (key) do nothing;

-- ─── Default role grants (operator_owner + operator_admin only) ────
--
-- `super_admin` already gets every key via the 9.0 cross-join seed
-- plus the 9.0a audit-fix migration's super_admin team.* sweep, but
-- those run once at apply time. A re-applied 9.0 migration would NOT
-- re-add this newly-introduced catalog key to super_admin; this slice
-- adds the explicit grant so super_admin's "every key" invariant
-- stays true.
--
-- `operator_owner` is the operator-self-service tier that owns audit
-- exports. `operator_admin` is the 11W.5 + 11A.14 admin-tier role
-- (parity contract § Audit Log Permission gate cheat sheet);
-- `operator_manager` and below do NOT receive the grant by default
-- because pulling a full audit trail to CSV is a senior-role action.

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, 'team.audit_log.export', 'allow'
  from public.roles r
 where r.role_key in (
         'super_admin',
         'operator_owner',
         'operator_admin'
       )
   and r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

commit;
