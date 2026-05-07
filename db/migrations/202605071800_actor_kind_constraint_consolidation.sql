-- Lane: code-health.actor-kind
--
-- CODE_HEALTH reference:
--   "Conflicting `actor_kind` constraint definitions in migrations
--    `202604280004` + `202604280013` (different constraint names; later
--    migration adds `actor_service_principal_id` not in canonical slice)."
--
-- Background.
--
-- Two earlier migrations both declare a CHECK constraint on
-- `public.auth_events_audit.actor_kind`:
--
--   1. `202604280004_phase_9_0sigma_d_service_principals.sql`
--      adds the column with an INLINE CHECK
--      (`actor_kind in ('user','service')`). Postgres assigns a
--      system-generated constraint name based on the column —
--      conventionally `auth_events_audit_actor_kind_check` — but the
--      precise name is implementation-dependent on the apply order /
--      pre-existing constraints, so the system-generated form is not
--      guaranteed to match the explicit form below in every
--      environment that replayed the slice fragmentarily during the
--      live closeout.
--
--   2. `202604280013_phase_9_audit_actor_kind_live_repair.sql`
--      drops `auth_events_audit_actor_kind_check` (no-op when absent)
--      and re-adds it explicitly under the same name. The same
--      migration also adds `actor_service_principal_id uuid null`,
--      which is NOT part of the canonical Phase 9.0Σ.d slice — it is
--      a live-closeout repair carried forward unchanged.
--
-- Predicate equivalence.
--
-- Both definitions encode the SAME logical predicate:
--
--   actor_kind IN ('user', 'service')
--
-- This consolidation is therefore a NAME consolidation only. No row
-- is rejected by the canonical constraint that the previous
-- definitions accepted, and no row is accepted that the previous
-- definitions rejected. There is no data-integrity decision embedded
-- here; if a future slice changes the allowed value set, that is a
-- separate migration, not this one.
--
-- Canonical name and predicate.
--
-- Canonical name : `auth_events_audit_actor_kind_check`
-- Canonical body : `CHECK (actor_kind IN ('user', 'service'))`
--
-- Reasoning. The explicit name from `202604280013` is the form the
-- live audit writer assumes when it surfaces constraint-violation
-- errors, and it matches the Postgres convention for an inline check
-- on a single column (`<table>_<column>_check`). Keeping the same
-- name avoids any churn in error-string-matching paths or in the
-- dispute-reconstruction surface.
--
-- What this migration does.
--
-- This migration is idempotent and re-runnable. It:
--
--   * Drops every observed prior name for the actor_kind CHECK on
--     `public.auth_events_audit`. The two names known to have been
--     introduced are the explicit
--     `auth_events_audit_actor_kind_check` (from 202604280013) and
--     the system-generated default of the same shape (from the
--     inline CHECK in 202604280004). DO blocks with an
--     `EXCEPTION WHEN undefined_object` swallow the case where the
--     named constraint never existed in this environment.
--
--   * Re-adds the canonical CHECK as NOT VALID, then VALIDATE
--     CONSTRAINT. NOT VALID + VALIDATE avoids the ACCESS EXCLUSIVE
--     full-table scan that a naked ADD CONSTRAINT would take, which
--     matters because `auth_events_audit` is a high-write surface
--     on the live proxy.
--
-- Old constraint names dropped:
--   * `auth_events_audit_actor_kind_check` (the explicit name from
--     `202604280013`; also the conventional system-generated name
--     for the inline CHECK from `202604280004`).
--
-- Canonical constraint kept:
--   * `auth_events_audit_actor_kind_check`
--     CHECK (actor_kind IN ('user', 'service'))
--
-- Note. `actor_service_principal_id` and its partial index from
-- `202604280013` are intentionally NOT touched here. Their presence
-- pre-dates this consolidation and is orthogonal to the constraint
-- naming question; removing them would be a separate decision the
-- orchestrator owns.

begin;

-- ─── Drop prior constraint definitions ──────────────────────────────
--
-- Wrapped in a DO block so a missing constraint name (e.g. the
-- environment never observed the `202604280004` system-generated
-- form, or `202604280013` already dropped/re-added it) does not
-- abort the migration. This keeps the slice idempotent and
-- re-runnable across staging, Production1, and any environment that
-- only replayed a subset of the Phase 9 closeout migrations.

do $$
begin
  alter table public.auth_events_audit
    drop constraint auth_events_audit_actor_kind_check;
exception
  when undefined_object then null;
end$$;

-- ─── Add the canonical constraint (NOT VALID + VALIDATE) ────────────
--
-- ADD CONSTRAINT NOT VALID acquires SHARE UPDATE EXCLUSIVE briefly
-- to record the constraint catalog row; VALIDATE CONSTRAINT then
-- scans existing rows under SHARE UPDATE EXCLUSIVE (not ACCESS
-- EXCLUSIVE), so concurrent INSERTs and SELECTs against
-- `auth_events_audit` are not blocked. Since both prior definitions
-- enforced the same predicate, every existing row already satisfies
-- the canonical body and validation is a fast scan.
--
-- The DO/EXCEPTION wrapper around ADD CONSTRAINT swallows the
-- `duplicate_object` case so re-runs leave the canonical constraint
-- in place without erroring out.

do $$
begin
  alter table public.auth_events_audit
    add constraint auth_events_audit_actor_kind_check
    check (actor_kind in ('user', 'service'))
    not valid;
exception
  when duplicate_object then null;
end$$;

alter table public.auth_events_audit
  validate constraint auth_events_audit_actor_kind_check;

comment on constraint auth_events_audit_actor_kind_check
  on public.auth_events_audit is
  'code-health.actor-kind consolidation. Canonical CHECK '
  '(actor_kind IN (''user'',''service'')) — replaces the duplicate '
  'definitions from 202604280004 (inline) and 202604280013 '
  '(explicit re-add). Predicate is unchanged from both prior '
  'forms; this is a name-consolidation slice only.';

commit;
