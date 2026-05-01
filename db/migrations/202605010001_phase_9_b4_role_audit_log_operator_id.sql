-- Phase 9 slice B.4 - role_audit_log gains operator_id; indexes
-- re-keyed to lead with operator_id; RLS simplified.
--
-- Background. `role_audit_log` was created in
-- `202604250008_auth_schema_foundation.sql` without an operator_id
-- column. The 9.0Σ.b RLS policy filtered tenant access via subqueries
-- against `roles` / `user_roles`. CLAUDE.md "RLS performance discipline"
-- locks the rule that every B-tree index on an operator-scoped fact
-- table must lead with operator_id (or `(operator_id, location_id)`);
-- the subquery-style policy also planned poorly under RLS.
--
-- The simplified SELECT policy reads `operator_id IS NULL OR
-- operator_id = public.app_current_operator()`. That is safe ONLY if
-- a NULL operator_id genuinely means "global role mutation"
-- (`roles.operator_id IS NULL`) — never "we couldn't resolve the
-- source row". `role_audit_log.role_id` and `user_role_id` are not
-- FK-constrained, so a row with a non-null but dangling source id
-- would have been hidden from every tenant by the legacy subquery
-- policy and would otherwise become globally visible after the swap.
-- This slice closes that regression with a write gate (BEFORE
-- INSERT trigger), a shape gate (CHECK + VALIDATE), and a pre-swap
-- verification of all rows that pre-date the gates.
--
-- ─── ORDERING is load-bearing ────────────────────────────────────
-- Each block runs in an implicit per-statement transaction; the
-- migration MUST be applied without an enclosing `BEGIN; … COMMIT;`
-- wrapper because CONCURRENTLY index ops cannot run inside a
-- transaction. Live writers are not blocked between statements.
-- That means a step ordering that does backfill → verify → trigger
-- has a window during which a legacy writer (one that doesn't set
-- operator_id) can land a row with a dangling source id, slip past
-- both backfill and verify, and only become a problem after the
-- policy swap.
--
-- The order below installs the BEFORE INSERT trigger BEFORE the
-- backfill/verify window. From the moment CREATE TRIGGER returns,
-- every new INSERT is either auto-resolved (trigger sets
-- operator_id from roles / user_roles) or rejected (trigger raises
-- 23514). Backfill + verify then operate on a frozen set of
-- pre-trigger rows; nothing can sneak in behind them.
--
--   1. ADD COLUMN operator_id (nullable, instant metadata-only).
--   2. Trigger function + BEFORE INSERT trigger.
--      Closes the write gate. From this point on, no INSERT can
--      land with a NULL or unresolved operator_id.
--   3. CHECK constraint role_audit_log_source_not_null
--      (ADD … NOT VALID). Shape gate for future writes; pre-existing
--      rows are not yet validated. The trigger above already raises
--      on both-NULL inserts, so this CHECK is redundant for INSERTs
--      but matters for any future UPDATE path.
--   4. Backfill operator_id from the source mutation. user_roles
--      wins when set (its operator_id is NOT NULL); falls back to
--      roles. Idempotent via `where operator_id is null`. Resolves
--      every pre-trigger row whose source row exists.
--   5. VERIFY no regression-bearing pre-trigger rows remain.
--      Two classes: both-NULL (role_id AND user_role_id both NULL)
--      and unresolved-source (non-null source id with no matching
--      roles / user_roles row). Both were hidden by the legacy
--      subquery policy and would become globally visible under the
--      new operator_id-NULL-is-global policy. Raises EXCEPTION with
--      a diagnostic query for whichever class is detected first.
--   6. VALIDATE CONSTRAINT role_audit_log_source_not_null.
--      Re-checks the CHECK against every pre-existing row. By this
--      point the verify in step 5 has already raised on any
--      both-NULL row; this is belt-and-suspenders.
--   7. RLS policy swap. By now the write gate has been live since
--      step 2, the shape gate has been live since step 3, the
--      backfill has resolved every pre-trigger row that could be
--      resolved, and the verify + validate have refused to proceed
--      on any pre-trigger row that couldn't. The simplified
--      direct-operator_id SELECT policy can take effect without
--      regressing tenant isolation.
--   8. Replace indexes (CONCURRENTLY). Drop the three legacy
--      non-operator-leading indexes; create five operator-leading
--      replacements (tenant + global partials, mirroring
--      auth_events_audit). Out-of-band relative to the policy swap
--      because CONCURRENTLY can't run inside a transaction.
--
-- Re-applying is a no-op: every IF EXISTS / IF NOT EXISTS / WHERE
-- operator_id IS NULL guard is set up so subsequent runs neither
-- error nor duplicate work.
--
-- Hard rules carried into this slice:
--
--   * `public.app_current_operator()` wrapper (item 4); bare
--     `current_setting()` is forbidden.
--   * Repository pattern is the primary defense; RLS is the backup.
--     This migration only changes RLS, never bypasses it.
--   * Append-only grant shape preserved; INSERT policy unchanged;
--     UPDATE / DELETE remain revoked from service_role.

-- ─── 1. Add operator_id column ─────────────────────────────────────

alter table public.role_audit_log
  add column if not exists operator_id uuid null;

comment on column public.role_audit_log.operator_id is
  'Slice B.4 denormalized tenant key. Backfilled from '
  'user_roles.operator_id (user_role_id-keyed rows) or '
  'roles.operator_id (role_id-keyed rows). NULL only for global role '
  'mutations (roles.operator_id NULL). RLS reads filter directly on '
  'this column; no subquery into roles or user_roles. Append-only '
  'audit shape preserved.';

-- ─── 2. BEFORE INSERT trigger (write gate, installed FIRST) ───────
--
-- Closing the write gate before the backfill / verify window is
-- load-bearing. Live writers are not blocked between this
-- migration's statements; an ordering that put backfill or verify
-- before this trigger would let a legacy writer (one that does not
-- set operator_id) land a row with a dangling source id between
-- the verify and the trigger install, surviving every defense and
-- becoming globally visible after the policy swap.
--
-- From the moment the CREATE TRIGGER below returns, every INSERT
-- into role_audit_log either:
--   * Has its operator_id set authoritatively from
--     user_roles.operator_id or roles.operator_id, OR
--   * Is rejected with errcode 23514 because the source row is
--     missing or both source columns are NULL.
-- Caller-supplied NEW.operator_id is overwritten - operator_id has
-- no independent meaning, it is purely denormalized state.
--
-- IF FOUND distinguishes the two NULL-operator_id outcomes a future
-- writer could otherwise conflate:
--
--   FOUND = TRUE  + operator_id IS NULL  - row references a global
--                                          role; NULL is correct.
--   FOUND = FALSE + operator_id IS NULL  - source row is missing;
--                                          MUST raise so the bad
--                                          INSERT does not silently
--                                          land a globally-visible
--                                          row.
--
-- Trigger prefers user_role_id (whose user_roles.operator_id is NOT
-- NULL) when both source ids are set, matching the backfill's
-- COALESCE order in step 4.

create or replace function public.role_audit_log_resolve_operator_id()
returns trigger
language plpgsql
as $$
declare
  v_op uuid;
begin
  if new.user_role_id is not null then
    select ur.operator_id into v_op
      from public.user_roles ur
     where ur.user_role_id = new.user_role_id;
    if found then
      new.operator_id := v_op;
      return new;
    end if;
  end if;

  if new.role_id is not null then
    select r.operator_id into v_op
      from public.roles r
     where r.role_id = new.role_id;
    if found then
      new.operator_id := v_op;
      return new;
    end if;
  end if;

  raise exception
    'role_audit_log: source mutation does not reference an existing '
    'roles or user_roles row (role_id=%, user_role_id=%). NULL '
    'operator_id is reserved for legitimate global roles '
    '(roles.operator_id IS NULL); an unresolved source id paired '
    'with the simplified direct-operator_id SELECT policy would '
    'otherwise become globally visible.',
    new.role_id, new.user_role_id
    using errcode = '23514';
end;
$$;

comment on function public.role_audit_log_resolve_operator_id() is
  'Slice B.4 write-side defense: BEFORE INSERT denormalization of '
  'role_audit_log.operator_id from the source mutation. Uses IF '
  'FOUND to distinguish a global-role NULL (legitimate) from a '
  'missing-source NULL (raises). Authoritative - caller-supplied '
  'NEW.operator_id is overwritten. Paired with the '
  'role_audit_log_source_not_null CHECK so the new '
  'direct-operator_id SELECT policy cannot regress to '
  'globally-visible rows.';

drop trigger if exists role_audit_log_resolve_operator_id_trg
  on public.role_audit_log;

create trigger role_audit_log_resolve_operator_id_trg
  before insert on public.role_audit_log
  for each row
  execute function public.role_audit_log_resolve_operator_id();

-- ─── 3. CHECK constraint role_audit_log_source_not_null ADD ────────
--
-- Shape gate. ADD … NOT VALID is metadata-only (no scan, no ACCESS
-- EXCLUSIVE lock); future writes are checked, pre-existing rows are
-- not yet validated. The trigger above already raises on both-NULL
-- inserts, so this CHECK is redundant for INSERTs but matters for
-- any future UPDATE path. The matching VALIDATE CONSTRAINT runs in
-- step 6, after backfill + verify have weeded out pre-existing
-- offenders.

alter table public.role_audit_log
  drop constraint if exists role_audit_log_source_not_null;
alter table public.role_audit_log
  add constraint role_audit_log_source_not_null
  check (role_id is not null or user_role_id is not null) not valid;

-- ─── 4. Backfill ───────────────────────────────────────────────────
--
-- The trigger above is now active, so any new INSERT is gated.
-- Backfill operates on the frozen set of pre-trigger rows: every
-- row whose source row exists gets operator_id resolved here. Rows
-- whose source is dangling or both-NULL are left for step 5 to
-- catch.
--
-- The UPDATE deliberately does NOT filter on `operator_id IS NULL`.
-- The ADD COLUMN → CREATE TRIGGER window (steps 1 → 2) is small but
-- non-zero: between those two statements live writers see the new
-- column and could land a row with a non-null but misattributed
-- operator_id (e.g., copy-pasted from a different request, or
-- guessed by a writer that doesn't know operator_id is denormalized
-- from the source). Since operator_id has no independent meaning -
-- it is purely a denormalization of the source mutation's tenancy -
-- the backfill authoritatively rewrites every source-keyed row from
-- its resolved source. A row that had operator_id = wrong-tenant
-- before this step will have operator_id = right-tenant after it.
--
-- The rewrite is idempotent in result: re-applying the migration
-- recomputes the same value and writes it back; subsequent runs
-- emit the same row contents. role_audit_log is small (mutation
-- events, not per-request audit) so a full-table rewrite is cheap.
--
-- COALESCE prefers user_roles (its operator_id is NOT NULL) so a
-- row carrying both source ids resolves to the grant-mutation
-- tenant. Falls back to roles (which may be NULL for global /
-- F&F-defined roles - that NULL is the legitimate "globally
-- visible" signal). UPDATE does not fire the BEFORE INSERT trigger.
-- Both-NULL rows (no source) are skipped here and caught by the
-- verify in step 5.

update public.role_audit_log as ral
   set operator_id = coalesce(
     (select ur.operator_id
        from public.user_roles ur
       where ur.user_role_id = ral.user_role_id),
     (select r.operator_id
        from public.roles r
       where r.role_id = ral.role_id)
   )
 where ral.role_id is not null or ral.user_role_id is not null;

-- ─── 5. Verify no regression-bearing pre-trigger rows ──────────────
--
-- Two distinct classes of pre-trigger row would silently flip from
-- "hidden from every tenant" (legacy subquery policy) to "globally
-- visible" (new direct-operator_id policy) without intervention.
-- Both must be cleaned up BEFORE the policy swap; this DO block
-- raises EXCEPTION with a diagnostic query for whichever class is
-- detected first.
--
--   (a) BOTH-NULL rows.
--       role_id IS NULL AND user_role_id IS NULL. The legacy policy
--       failed both `role_id is not null` and `user_role_id is not
--       null` conjuncts, so the row was hidden. The simplified
--       policy treats operator_id NULL as globally visible. The
--       VALIDATE CONSTRAINT in step 6 catches these too, but this
--       DO block fails earlier with a friendly diagnostic query.
--
--   (b) UNRESOLVED-SOURCE rows.
--       role_id / user_role_id is non-null but does not match any
--       roles / user_roles row (the source columns carry no FK).
--       The legacy `IN (SELECT …)` probe returned no match → row
--       hidden. Backfill in step 4 left operator_id NULL because
--       `SELECT … INTO` returned zero rows; under the new policy
--       that NULL becomes globally visible.
--
-- Bounding: the trigger installed in step 2 prevents new rows of
-- either class from landing during the backfill / verify window.
-- This DO block therefore only deals with rows that pre-date the
-- trigger.
--
-- A row whose role_id resolves to a roles row with operator_id NULL
-- (a real global / F&F-defined role) is NOT unresolved - it is the
-- legitimate "globally visible" case the simplified policy
-- preserves. The verification distinguishes these two
-- NULL-operator_id outcomes by checking source-row existence, which
-- `SELECT operator_id INTO` alone cannot.

do $$
declare
  v_both_null bigint;
  v_unresolved bigint;
begin
  -- (a) Pre-existing both-NULL rows.
  select count(*) into v_both_null
    from public.role_audit_log
   where role_id is null
     and user_role_id is null;

  if v_both_null > 0 then
    raise exception
      'role_audit_log slice B.4: % pre-existing row(s) with both '
      'role_id AND user_role_id NULL. The legacy subquery RLS '
      'policy hid such rows (both `role_id is not null` and '
      '`user_role_id is not null` conjuncts failed); the new '
      'direct-operator_id policy treats operator_id NULL as '
      'globally visible. The NOT VALID CHECK below blocks future '
      'inserts but does not validate existing rows on its own. '
      'Investigate before re-applying. Diagnostic query: SELECT '
      'entry_id, change_type, changed_at, changed_by FROM '
      'public.role_audit_log WHERE role_id IS NULL AND '
      'user_role_id IS NULL;',
      v_both_null
      using errcode = '23514';
  end if;

  -- (b) Pre-existing unresolved-source rows.
  select count(*) into v_unresolved
    from public.role_audit_log as ral
   where ral.operator_id is null
     and (ral.role_id is not null or ral.user_role_id is not null)
     and (
       ral.role_id is null
       or not exists (
         select 1 from public.roles r where r.role_id = ral.role_id
       )
     )
     and (
       ral.user_role_id is null
       or not exists (
         select 1 from public.user_roles ur
          where ur.user_role_id = ral.user_role_id
       )
     );

  if v_unresolved > 0 then
    raise exception
      'role_audit_log slice B.4: % unresolved row(s) found '
      '(non-null role_id or user_role_id with no matching '
      'roles/user_roles row). The legacy subquery RLS policy hid '
      'such rows from every tenant; the new direct-operator_id '
      'policy would expose them as global. Investigate before '
      're-applying. Diagnostic query: SELECT entry_id, role_id, '
      'user_role_id, change_type, changed_at FROM '
      'public.role_audit_log AS ral WHERE ral.operator_id IS NULL '
      'AND (ral.role_id IS NOT NULL OR ral.user_role_id IS NOT '
      'NULL) AND (ral.role_id IS NULL OR NOT EXISTS (SELECT 1 '
      'FROM public.roles r WHERE r.role_id = ral.role_id)) AND '
      '(ral.user_role_id IS NULL OR NOT EXISTS (SELECT 1 FROM '
      'public.user_roles ur WHERE ur.user_role_id = '
      'ral.user_role_id));',
      v_unresolved
      using errcode = '23514';
  end if;
end$$;

-- ─── 6. VALIDATE CONSTRAINT (re-check pre-trigger rows) ────────────
--
-- The CHECK was added NOT VALID in step 3, so pre-existing rows are
-- still unvalidated at this point. The DO block in step 5 has just
-- raised on any both-NULL pre-trigger row, so this VALIDATE pass
-- is normally a no-op. Belt-and-suspenders: if a both-NULL row ever
-- slipped past the friendly DO block (a diagnostic-query mismatch,
-- a future edit drops the both-NULL conjunct), VALIDATE refuses to
-- complete and the migration aborts before the policy swap.
--
-- VALIDATE CONSTRAINT takes SHARE UPDATE EXCLUSIVE lock - concurrent
-- reads / writes are not blocked.

alter table public.role_audit_log
  validate constraint role_audit_log_source_not_null;

-- ─── 7. RLS policy swap ────────────────────────────────────────────
--
-- All defenses are now in place: backfilled column, write gate (step
-- 2 trigger), shape gate (step 3 CHECK + step 6 VALIDATE), and
-- pre-trigger row verification (step 5 DO block). The simplified
-- direct-operator_id SELECT policy is behavior-preserving because
-- operator_id is an authoritative denormalization of the source
-- mutation's tenancy. Wrapper `public.app_current_operator()` (item
-- 4) is used; bare `current_setting()` is forbidden.

drop policy if exists "role_audit_log_per_tenant_select"
  on public.role_audit_log;

create policy "role_audit_log_per_tenant_select"
  on public.role_audit_log for select to service_role
  using (
    operator_id is null
    or operator_id = public.app_current_operator()
  );

-- The append_insert policy is unchanged; service_role retains
-- INSERT-only authority, UPDATE / DELETE remain revoked. The
-- BEFORE INSERT trigger from step 2 closes the "writer-supplied
-- operator_id NULL" / "missing-source-row" gaps; the CHECK +
-- VALIDATE pair (steps 3 and 6) closes the "both source columns
-- NULL" gap. Documented here so future readers see the full
-- role_audit_log policy + write-defense surface without spelunking
-- 202604280001.

-- ─── 8. Replace indexes (CONCURRENTLY) ─────────────────────────────
--
-- Drop the three legacy indexes; create five operator-leading
-- replacements (tenant partials lead with operator_id; global
-- partials are exempt via `where operator_id is null`). CONCURRENTLY
-- everywhere so live writers are not blocked by an exclusive lock.
-- This block runs after the policy swap because CONCURRENTLY DDL
-- cannot share an enclosing transaction with the policy update;
-- correctness of the policy does not depend on which indexes are
-- in place.

drop index concurrently if exists public.role_audit_log_role_changed_idx;
drop index concurrently if exists public.role_audit_log_user_role_changed_idx;
drop index concurrently if exists public.role_audit_log_changed_at_idx;

-- Per-tenant role-mutation lookup. Operator-leading; covers
-- `(operator_id, role_id, changed_at desc)` reads from the audit
-- viewer.
create index concurrently if not exists role_audit_log_operator_role_changed_idx
  on public.role_audit_log (operator_id, role_id, changed_at desc)
  where operator_id is not null and role_id is not null;

-- Per-tenant grant-mutation lookup. user_role_id-keyed audit rows
-- always carry a non-null operator_id (because user_roles.operator_id
-- is NOT NULL), so the partial predicate is just user_role_id.
-- The index still leads with operator_id for RLS pushdown.
create index concurrently if not exists role_audit_log_operator_user_role_changed_idx
  on public.role_audit_log (operator_id, user_role_id, changed_at desc)
  where operator_id is not null and user_role_id is not null;

-- Global role-mutation lookup (operator_id IS NULL). Partial-NULL
-- exempt from the index-leading-column lint: rows have no tenant, so
-- leading with operator_id provides no value.
create index concurrently if not exists role_audit_log_global_role_changed_idx
  on public.role_audit_log (role_id, changed_at desc)
  where operator_id is null and role_id is not null;

-- Per-tenant time-window scan. Replaces the legacy
-- `role_audit_log_changed_at_idx` for tenant rows.
create index concurrently if not exists role_audit_log_operator_changed_idx
  on public.role_audit_log (operator_id, changed_at desc)
  where operator_id is not null;

-- Global time-window scan. Replaces the legacy
-- `role_audit_log_changed_at_idx` for global rows. Partial-NULL
-- exempt.
create index concurrently if not exists role_audit_log_global_changed_idx
  on public.role_audit_log (changed_at desc)
  where operator_id is null;
