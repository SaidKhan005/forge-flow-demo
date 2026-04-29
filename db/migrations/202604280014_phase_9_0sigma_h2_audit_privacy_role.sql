-- Phase 9.0Σ.h2 — advisor-conversation audit-privacy permission gate
-- (parcel B46 in `phase_9_execution_backlog.md`, extends item 5 of
-- `phase_9_scalability_decisions_2026-04-27.md`).
--
-- B29 / 9.0Σ.h created the `advisor_conversation_log` table with the
-- column-level GRANT SELECT split (raw encrypted columns visible only
-- to the `audit_privacy` Postgres role) and the role itself. This
-- additive slice closes the missing app-layer half of the gate:
--
--   1. A frozen permission key (`admin.audit_privacy.read`) the
--      audit-read code path must hold to call the repository's
--      audit-read method. MFA-required so a stolen long-lived
--      session cannot be replayed against the raw advisor-content
--      surface.
--   2. Default role grants for the new key — only `super_admin` and
--      `ff_support` (the two seeded F&F-internal roles). The four
--      operator-tier roles (`operator_owner`, `operator_manager`,
--      `operator_supervisor`, `operator_staff`) deliberately do NOT
--      receive the key by default; raw advisor-conversation content
--      is F&F-internal until an operator explicitly grants it via
--      9.6's role-management surface.
--   3. A Postgres role-membership grant: `grant audit_privacy to
--      service_role`. This is the privilege the proxy needs so the
--      audit-read code path can issue `SET LOCAL ROLE audit_privacy`
--      on its already-pooled `service_role` connection. Without the
--      membership, `SET LOCAL ROLE audit_privacy` raises
--      "permission denied to set role". Granting `audit_privacy` TO
--      `service_role` (not the inverse) is the minimal privilege —
--      members of `service_role` may assume `audit_privacy` for the
--      lifetime of a single transaction; outside that transaction the
--      connection runs as plain `service_role` and can only read the
--      column-allowlisted metadata.
--
-- Hard rules carried from CLAUDE.md and the 4-27 lock:
--
--   * Permission keys are app-defined and frozen at code level. The
--     catalog seeded here mirrors `lib/auth/permission_keys.dart` and
--     `docs/contracts/auth_permission_key_catalog.md`. Operators may
--     not invent new keys at runtime.
--
--   * MFA-required keys carry `requires_mfa = true` in the seed and
--     in `PermissionKeys.requiresMfa`. The runtime resolver (9.6)
--     refuses to admit such a key unless the caller's session has a
--     fresh `auth_time` MFA assertion.
--
--   * The migration is additive only — it does NOT mutate
--     `202604280007_phase_9_0sigma_h_advisor_conversation_log.sql`.
--     Re-applying this migration is a no-op (`on conflict do nothing`
--     for catalog rows, `do $$` guards on role grants).
--
--   * No live database mutation. Live apply on staging + Production1
--     is queued under the Phase 9 live-mutation gate.

begin;

-- ─── Seed permission_keys.admin.audit_privacy.read ─────────────────
--
-- `admin.audit_privacy.read` is the runtime gate the proxy checks
-- before calling the audit-read repository method. The 9.0 catalog
-- seed in `202604250008_auth_schema_foundation.sql` did not have a
-- key for this surface (the audit-privacy split landed in 9.0Σ.h);
-- adding it here keeps the catalog frozen and auditable while the
-- audit-read path is being wired.
--
-- `requires_mfa = true` so a stolen refresh token cannot be replayed
-- against raw advisor content without a fresh MFA assertion. This
-- mirrors the posture used for `admin.users.erase_pii`,
-- `billing.subscription.manage`, etc.
--
-- `frozen = true` matches every other catalog row — the catalog is
-- a code-level contract, not a runtime-mutable table.

insert into public.permission_keys (
  key, category, description, requires_mfa, frozen
)
values
  (
    'admin.audit_privacy.read',
    'admin',
    'Read raw advisor conversation content (encrypted columns) under '
    'the audit-privacy access path. Every call writes an audit_logs '
    'provenance row capturing reader, reason, target, and records-read '
    'count. MFA required.',
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
-- ff_support is granted explicitly because the audit-read path is
-- F&F support's primary tool for investigating advisor incidents on
-- behalf of an operator (under the documented audit-privacy access
-- path with paired audit row). The pattern matches ff_support's
-- existing read-only audit-log access.
--
-- The four operator-tier roles (`operator_owner`, `operator_manager`,
-- `operator_supervisor`, `operator_staff`) are deliberately omitted.
-- Raw advisor-conversation content is F&F-internal at launch; an
-- operator who needs it must request it through F&F support OR have
-- a custom operator-scoped role explicitly grant the key via 9.6's
-- role-management surface.

insert into public.role_permissions (role_id, permission_key, effect)
select r.role_id, 'admin.audit_privacy.read', 'allow'
  from public.roles r
 where r.role_key in ('super_admin', 'ff_support')
   and r.is_seeded = true
   and r.operator_id is null
on conflict (role_id, permission_key) do nothing;

-- ─── Postgres role-membership grant ────────────────────────────────
--
-- `audit_privacy` was created NOLOGIN in 9.0Σ.h. The proxy's runtime
-- connection logs in as `service_role`; the audit-read code path
-- needs `SET LOCAL ROLE audit_privacy` to flip into the column-level
-- GRANT scope that admits `content_encrypted` / `content_iv` /
-- `content_key_ref`. Postgres requires the calling role to be a
-- member of the target role for `SET ROLE` to succeed. Without this
-- grant, `SET LOCAL ROLE audit_privacy` raises "permission denied to
-- set role".
--
-- The grant is membership only — `audit_privacy` remains NOLOGIN, so
-- nothing can connect as `audit_privacy` directly. Members of
-- `service_role` may assume the role for the lifetime of a single
-- transaction (`SET LOCAL ROLE`); the assumption is automatically
-- released at COMMIT/ROLLBACK so pooled connection reuse cannot leak
-- audit-privacy access into the next request.
--
-- The `do $$` guard makes the grant idempotent: PG raises an error if
-- the membership already exists, but `pg_auth_members` lookup avoids
-- the error on re-runs.

do $$
begin
  if not exists (
    select 1
      from pg_catalog.pg_auth_members am
      join pg_catalog.pg_roles r on r.oid = am.roleid
      join pg_catalog.pg_roles m on m.oid = am.member
     where r.rolname = 'audit_privacy'
       and m.rolname = 'service_role'
  ) then
    grant audit_privacy to service_role;
  end if;
end
$$;

commit;
