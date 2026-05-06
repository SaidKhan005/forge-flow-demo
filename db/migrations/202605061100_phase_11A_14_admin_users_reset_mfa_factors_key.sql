-- Phase 11A.14 — additive permission-key catalog row for the F&F
-- admin "Reset member MFA" support action.
--
-- The 11A.14 Audited support actions surface ships an Actions panel
-- that exposes three F&F-admin support escalations: reset member MFA,
-- initiate password reset, and issue paired-approval erasure. The
-- second and third actions are gated on existing catalog keys
-- (`admin.users.reset_password`, `admin.users.erase_pii`); the first
-- needs a new key — `admin.users.reset_mfa_factors` — that the 9.0
-- foundation seed never carried because the admin-side reset-MFA
-- escalation path did not exist at 9.0 close.
--
-- The parity contract
-- (`docs/contracts/team_roles_hierarchy_console_parity_contract.md`)
-- pins the new key in two places: § Security (line 161) and the
-- Permission gate cheat sheet (line 208). The contract Anti-pattern
-- "If a slice prompt needs a new route, the parity contract is
-- incomplete — STOP and update this contract first" does NOT apply
-- here because the new entity is a permission key and the contract
-- already names it; this slice closes the catalog/code/migration
-- keep-in-sync rule (catalog § "Keep in sync" lines 24–37).
--
-- Hard rules carried from CLAUDE.md and the catalog contract:
--
--   * Permission keys are app-defined and frozen at code level. The
--     catalog seeded here mirrors `lib/auth/permission_keys.dart` and
--     `docs/contracts/auth_permission_key_catalog.md`. Operators may
--     not invent new keys at runtime.
--
--   * MFA-required keys carry `requires_mfa = true` in the seed and
--     in `PermissionKeys.requiresMfa`. The runtime resolver refuses
--     to admit such a key unless the caller's session has a fresh
--     `auth_time` MFA assertion. Reset-MFA is the highest-trust
--     account-recovery action; mirror the posture used for
--     `admin.users.erase_pii` / `admin.roles.edit_seeded`.
--
--   * The migration is additive only — single INSERT into
--     `permission_keys` with `on conflict (key) do nothing`, plus an
--     idempotent default role-grant insert for the two seeded F&F
--     internal roles (`super_admin`, `ff_support`). Re-applying the
--     migration is a no-op.
--
--   * No live database mutation. Live apply on staging + Production1
--     is queued under the Phase 9 live-mutation gate.

begin;

-- ─── Seed permission_keys.admin.users.reset_mfa_factors ────────────
--
-- `frozen = true` matches every other catalog row — the catalog is a
-- code-level contract, not a runtime-mutable table. Description copy
-- mirrors the parity contract § Security line 161 verbatim so the
-- catalog doc, the constants file, and this migration carry the same
-- text.

insert into public.permission_keys (
  key, category, description, requires_mfa, frozen
)
values
  (
    'admin.users.reset_mfa_factors',
    'admin',
    'Reset a member''s MFA factors from the F&F admin support path. '
    'Required for support-side account recovery when the member has '
    'lost access to their second factor. Paired with admin_reason on '
    'every call. MFA required.',
    true,
    true
  )
on conflict (key) do nothing;

-- ─── Default role grants (super_admin + ff_support only) ───────────
--
-- super_admin already gets every key via the cross-join seed in
-- `202604250008_auth_schema_foundation.sql`, but that seed runs once
-- at 9.0 apply time. A re-applied 9.0 migration would NOT re-add
-- newly-introduced catalog keys to super_admin; this slice adds the
-- explicit grant so super_admin's "every key" invariant stays true
-- even when the foundation migration was applied before this key
-- existed.
--
-- ff_support is granted explicitly because the support-side MFA reset
-- is exactly the escalation path ff_support owns (§ Security
-- "F&F admin (`11A.14` Actions panel)" line 161). The runtime
-- resolver still refuses to admit the key without an MFA-fresh token,
-- so granting it to ff_support does not weaken the gate.
--
-- The four operator-tier roles (`operator_owner`, `operator_manager`,
-- `operator_supervisor`, `operator_staff`) are deliberately omitted.
-- The operator-side equivalent is `team.users.reset_mfa` (the locked
-- 24-hour delayed-removal flow for own-operator members); the admin
-- key is F&F-internal.

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, 'admin.users.reset_mfa_factors', 'allow'
  from public.roles r
 where r.role_key in ('super_admin', 'ff_support')
   and r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

commit;
