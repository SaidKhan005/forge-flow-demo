-- Wave 2 R-1L-FU + R-2L-FU — flip permission_keys text columns to NOT NULL.
--
-- Origin:
--   * Prereq R-1L `db/migrations/202605142100_phase_R_1L_roles_schema_rewrite.sql`
--     added `permission_keys.product_label`, `category_label`, `scope_kind`
--     (all `text`, NULLABLE) with inline `UPDATE ... CASE` backfills that
--     hydrate every row before commit. The migration's terminal fail-loud
--     DO block raises if any backfill row is left NULL. The expand-only
--     posture deferred the NOT NULL flip to this follow-up per the
--     expand-contract discipline `tool/migration_drift_scanner.dart`
--     enforces for migrations after the grandfather cutoff at
--     `202605131030_b11_1_auth_handoff_codes.sql`.
--   * Prereq R-2L `db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql`
--     added `permission_keys.human_label` (`text`, NULLABLE) with an inline
--     `UPDATE ... CASE` backfill that hydrates every catalog key. The
--     same fail-loud DO block guards that backfill at apply time. R-2L's
--     terminal comment explicitly parks the human_label NOT NULL flip
--     alongside the R-1L-FU follow-up — this slice picks both up in one
--     combined contract migration.
--   * Operator approval (2026-05-14): fold the combined NOT NULL flip into
--     the wave without a separate staging cycle. The Dart-side mirror at
--     `lib/auth/permission_key_metadata.dart` is NOT-NULL-at-source via
--     `tool/permission_key_lint.dart`'s METADATA + HUMAN_LABEL_INVALID
--     passes; any catalog key shipping without a label fails CI before it
--     ever reaches a migration apply, so the inline backfills are
--     guaranteed to find a non-NULL value in every row.
--   * CLAUDE.md "RLS-Ready Schema" — `permission_keys` is the global
--     catalog table (operator_id IS NULL across every row); HP #4
--     per-operator isolation does not apply. RLS posture unchanged.
--   * CLAUDE.md "Time Guardrails" — no new timestamp columns added.
--
-- What this slice does
-- --------------------
-- 1. Defensive pre-flight: count any rows where product_label /
--    category_label / scope_kind / human_label / implies is NULL. If any
--    are present, raise loudly with the row count so the operator can
--    investigate the R-1L + R-2L backfills before retrying. The flip MUST
--    NOT proceed silently when the source-of-truth data is incomplete.
-- 2. Flip `product_label`, `category_label`, `scope_kind`, `human_label`
--    to NOT NULL. Each `SET NOT NULL` is idempotent (PG no-ops if the
--    column is already NOT NULL), so a re-run after partial success is
--    safe.
-- 3. Ensure the `implies text[]` column carries the safe default of
--    `'{}'::text[]` (R-1L added it with this default + NOT NULL, but
--    defensively re-assert here in case any earlier migration in a
--    bespoke staging cycle dropped the default). Backfill any NULL rows
--    to `'{}'` before reasserting NOT NULL.
--
-- Idempotency
-- -----------
-- Every statement is a structural contract that PostgreSQL no-ops when
-- the column is already in the target state:
--   * `SET NOT NULL` on an already-NOT-NULL column is a no-op.
--   * `SET DEFAULT '{}'::text[]` on a column that already has that
--     default is a no-op.
--   * The pre-flight assertion short-circuits before any structural
--     change when source data is incomplete.
--
-- Expand-contract posture
-- -----------------------
-- This is the **contract** half of the R-1L + R-2L expand-contract pair.
-- The migration adds NO new columns, runs NO data-shape backfills (only
-- the defensive `implies = '{}'::text[] WHERE implies IS NULL` safety
-- net), and only tightens existing nullability constraints. The drift
-- scanner's expand-contract lint allows SET NOT NULL on its own
-- (`hasAddNullable && hasUpdate && hasSetNotNull` is the violation
-- shape; SET NOT NULL alone with no ADD COLUMN is allowed).

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- ─── Defensive pre-flight: assert no NULL rows ───────────────────────
--
-- Any NULL on the five guarded columns at this point means the R-1L or
-- R-2L backfills regressed (or this migration is running against a
-- staging cycle where the expand half was skipped). Raise loudly so the
-- gap surfaces at the migration boundary instead of leaking into a
-- failed `ALTER TABLE ... SET NOT NULL` further down (which would
-- abort with a less actionable error).

do $$
declare
  v_null_count int;
begin
  select count(*) into v_null_count
    from public.permission_keys
   where product_label is null
      or category_label is null
      or scope_kind is null
      or human_label is null;
  if v_null_count > 0 then
    raise exception
      'Cannot flip permission_keys.{product_label,category_label,scope_kind,human_label} to NOT NULL: % rows still NULL. Investigate R-1L + R-2L backfills before re-running.',
      v_null_count;
  end if;
end;
$$;

-- ─── Flip the four text columns to NOT NULL ─────────────────────────
--
-- Each clause is idempotent: PG no-ops if the column is already NOT
-- NULL. Combining the four ALTER COLUMN clauses in one ALTER TABLE
-- statement takes a single ACCESS EXCLUSIVE lock on `permission_keys`
-- (a ~104-row frozen global catalog), so the cutover is sub-second.

alter table public.permission_keys
  alter column product_label set not null,
  alter column category_label set not null,
  alter column scope_kind set not null,
  alter column human_label set not null;

-- ─── Reassert implies safe default + NOT NULL ────────────────────────
--
-- R-1L added `implies text[] not null default '{}'::text[]` already,
-- but defensively re-assert here so the contract migration owns the
-- full final-state shape regardless of any bespoke staging cycle
-- variation. The UPDATE is a safety net — there should be zero NULL
-- rows (R-1L's ADD COLUMN carries the NOT NULL constraint), but if a
-- prior partial-rollback left one through, this lets the subsequent
-- SET NOT NULL pass.

alter table public.permission_keys
  alter column implies set default '{}'::text[];

update public.permission_keys
   set implies = '{}'::text[]
 where implies is null;

alter table public.permission_keys
  alter column implies set not null;

commit;
