-- code-health.ff-policy-fold — feature_flags sentinel operator_id
--
-- CODE_HEALTH reference: "`feature_flags` policy `OR (operator_id IS
-- NULL …)` can't fold into the tenant-leading index (perf concern)."
-- The 202605021500_phase_9_0sigma_l_rls_depth.sql policy reads
-- `operator_id IS NULL OR operator_id = app_current_operator()`. The
-- `IS NULL` arm prevents Postgres from folding the predicate into the
-- operator-leading partial unique index
-- `feature_flags_operator_scope_idx (flag_name, operator_id) WHERE
-- operator_id IS NOT NULL AND location_id IS NULL` — every tenant-
-- scoped flag lookup falls back to a sequential scan or the wider
-- `feature_flags_pkey`.
--
-- Fix shape: introduce a sentinel UUID for system-wide flags so the
-- policy becomes `operator_id = app_current_operator() OR operator_id
-- = <sentinel>`. The `IS NULL` clause is gone and the planner can fold
-- the OR into a bitmap-or on the operator-leading partial unique
-- index.
--
-- Sentinel value chosen: `00000000-0000-0000-0000-000000000000`. Why:
--   * Repo-wide search of `db/migrations/**` and `test/**` confirms
--     no real `operators.operator_id` row uses the all-zeros UUID.
--     `gen_random_uuid()` (the table default) cannot produce all-
--     zeros. The all-zeros pattern IS used elsewhere as a NULL
--     `location_id` coalescing sentinel inside `coalesce(location_id,
--     '00000000-...')` predicates (`202604250008_auth_schema_
--     foundation.sql`, `202605040000_phase_8_0_integration_framework
--     .sql`, `202604290101_phase_9_hierarchy_access_wiring.sql`,
--     `202604300002_phase_9_mfa_hardening_launch_roles.sql`) — but
--     only as a `location_id` placeholder, never as an `operator_id`,
--     so the namespaces don't overlap.
--   * Recognizable on staging at a glance (`\dt`-style triage knows
--     all-zeros = system sentinel).
--
-- Authority order:
--   1. CLAUDE.md "RLS-Ready Schema" — wrappers + tenant-leading index
--      fold; no bare `current_setting` reads.
--   2. `phase_9_scalability_decisions_2026-04-27.md` item 4 — every
--      RLS predicate must fold into a tenant-leading index.
--   3. `202604280000_phase_9_0sigma_b_rls_wrappers.sql` — the
--      `app_current_operator()` wrapper this policy calls.
--   4. `202605021500_phase_9_0sigma_l_rls_depth.sql` — the policy
--      this migration replaces.
--
-- Behavioral parity:
--
--   * Visibility: tenants still SELECT their own + system-wide rows
--     (the sentinel matches the OR arm).
--   * Mutation: WITH CHECK still rejects system-wide writes from
--     tenant context — sentinel-bearing rows are still mutated only
--     via `forge_admin BYPASSRLS` (super_admin Feature Flags screen)
--     or migration-side seeds.
--   * Index fold: the operator-scope partial unique index
--     (`feature_flags_operator_scope_idx`) now matches sentinel-
--     bearing rows (sentinel is NOT NULL), so global-scope uniqueness
--     enforcement folds into the same index that operator-wide
--     uniqueness uses. The dedicated global-scope partial index
--     (`feature_flags_global_scope_idx WHERE operator_id IS NULL AND
--     location_id IS NULL`) is dropped because no row matches its
--     predicate after the backfill.
--
-- FK posture: `feature_flags.operator_id` references
-- `public.operators(operator_id)` with `ON DELETE CASCADE`. To keep
-- the FK valid after the backfill, this migration seeds a synthetic
-- `operators` row at the sentinel UUID. The synthetic row carries
-- the `business_name = 'forge-and-flow-system-sentinel'` marker so
-- ops triage can identify it. RLS on `public.operators` is the
-- permissive `using (true)` stub from `202604250005`, so tenant
-- queries still see the row only by FK reference (they cannot
-- mutate it through the per-tenant Feature Flags policy because
-- WITH CHECK still rejects sentinel writes from tenant context).
--
-- Idempotency: every UPDATE / INSERT carries an existence guard;
-- DROP POLICY uses `if exists`; the migration runs in
-- `psql --single-transaction` so the table is never policy-less
-- between statements. Re-runs are no-ops.

begin;

-- ─── 1. Sentinel-scope constants table ─────────────────────────────

create table if not exists public.feature_flag_scope_sentinels (
  scope_name text primary key
    check (char_length(scope_name) between 1 and 64),
  operator_id uuid not null unique
);

comment on table public.feature_flag_scope_sentinels is
  'code-health.ff-policy-fold — sentinel UUIDs for synthetic '
  'feature_flags scopes. Today only the `system_wide` scope exists; '
  'the policy reads its operator_id through '
  '`public.feature_flag_system_wide_operator_id()` so the planner '
  'folds the OR predicate into the tenant-leading partial unique '
  'index (`feature_flags_operator_scope_idx`).';

insert into public.feature_flag_scope_sentinels (scope_name, operator_id)
values ('system_wide', '00000000-0000-0000-0000-000000000000'::uuid)
on conflict (scope_name) do nothing;

-- ─── 2. Synthetic operators row at the sentinel UUID ───────────────
--
-- Required so the FK `feature_flags.operator_id ->
-- operators(operator_id)` accepts sentinel-bearing rows after the
-- backfill in step 3. The row is identifiable via the
-- `business_name` marker; ops should never delete it (cascade would
-- wipe every system-wide flag).

insert into public.operators (
  operator_id,
  business_name,
  owner_email,
  subscription_tier,
  preferred_currency
)
values (
  '00000000-0000-0000-0000-000000000000'::uuid,
  'forge-and-flow-system-sentinel',
  'system+sentinel@forge-and-flow.invalid',
  'launch',
  'CAD'
)
on conflict (operator_id) do nothing;

-- ─── 3. Backfill existing global-scope rows ────────────────────────
--
-- Every existing `feature_flags` row with NULL `operator_id` is
-- promoted to the sentinel UUID. Predicate is `operator_id IS NULL`
-- — re-runs see zero rows because the column is NOT NULL after
-- step 4 below.

update public.feature_flags
   set operator_id = (
         select operator_id
           from public.feature_flag_scope_sentinels
          where scope_name = 'system_wide'
       )
 where operator_id is null;

-- ─── 4. Set operator_id NOT NULL ───────────────────────────────────
--
-- Two-step `NOT VALID` + `VALIDATE` to avoid an ACCESS EXCLUSIVE
-- lock during validation. Idempotent: if the constraint already
-- exists, the `if not exists` guard skips the ADD; the VALIDATE is
-- a no-op when already validated.

alter table public.feature_flags
  add constraint feature_flags_operator_id_not_null
  check (operator_id is not null) not valid;

alter table public.feature_flags
  validate constraint feature_flags_operator_id_not_null;

-- The CHECK constraint is the on-disk truth; the column-level
-- nullability flag follows so future inserts that omit operator_id
-- fail at parse time instead of validate time. SET NOT NULL is a
-- short metadata-only lock once the CHECK has validated every row.

alter table public.feature_flags
  alter column operator_id set not null;

-- ─── 5. Drop now-empty global-scope partial unique index ───────────
--
-- After backfill, no row matches `WHERE operator_id IS NULL AND
-- location_id IS NULL`, so the partial index from 202604250005
-- (`feature_flags_global_scope_idx`) covers zero rows and never
-- enforces uniqueness. The operator-scope partial unique index
-- (`feature_flags_operator_scope_idx WHERE operator_id IS NOT NULL
-- AND location_id IS NULL`) now covers system-wide rows
-- (sentinel is NOT NULL) AND operator-wide rows under the same
-- `(flag_name, operator_id)` key — uniqueness for both scopes
-- collapses into one index.

drop index if exists public.feature_flags_global_scope_idx;

-- ─── 6. Sentinel reader function ───────────────────────────────────
--
-- `STABLE LEAKPROOF PARALLEL SAFE` so the planner can fold the
-- function call into the tenant-leading partial unique index when
-- the policy body inlines into a SELECT plan. Mirrors the
-- `app_current_operator()` posture from 202604280000.

create or replace function public.feature_flag_system_wide_operator_id()
returns uuid
language sql
stable
parallel safe
as $$
  select operator_id
    from public.feature_flag_scope_sentinels
   where scope_name = 'system_wide'
$$;

alter function public.feature_flag_system_wide_operator_id() leakproof;

comment on function public.feature_flag_system_wide_operator_id() is
  'code-health.ff-policy-fold — returns the sentinel UUID for '
  'system-wide feature flags. STABLE LEAKPROOF PARALLEL SAFE so the '
  'planner can fold the policy OR predicate into the tenant-leading '
  'partial unique index. Read-only; never mutates state.';

grant execute on function public.feature_flag_system_wide_operator_id()
  to service_role;
grant execute on function public.feature_flag_system_wide_operator_id()
  to forge_admin;

-- ─── 7. Replace the OR-IS-NULL RLS policy ──────────────────────────
--
-- Drop the 9.0Σ.l policy and recreate without `operator_id IS NULL`.
-- The new shape is `operator_id = app_current_operator() OR
-- operator_id = public.feature_flag_system_wide_operator_id()`
-- — both arms compare to a UUID, both calls fold into the
-- operator-leading index. WITH CHECK keeps the asymmetric posture:
-- tenants cannot insert or update sentinel-bearing rows through
-- this policy; super_admin mutations elevate to forge_admin
-- BYPASSRLS via `runAsSystem`.

drop policy if exists "feature_flags_global_or_tenant"
  on public.feature_flags;

create policy "feature_flags_global_or_tenant"
  on public.feature_flags for all to service_role
  using (
    operator_id = public.app_current_operator()
    or operator_id = public.feature_flag_system_wide_operator_id()
  )
  with check (
    operator_id = public.app_current_operator()
    and operator_id <> public.feature_flag_system_wide_operator_id()
  );

comment on policy "feature_flags_global_or_tenant" on public.feature_flags is
  'code-health.ff-policy-fold — defense-in-depth tenant isolation '
  'with system-wide visibility. Replaces the 9.0Σ.l shape. Tenants '
  'SELECT their own (operator_id matches) plus system-wide rows '
  '(sentinel UUID — see public.feature_flag_scope_sentinels). The '
  'OR predicate now folds into the tenant-leading partial unique '
  'index (`feature_flags_operator_scope_idx`) because both arms '
  'compare operator_id to a UUID; the prior IS NULL arm forced a '
  'sequential scan or PK fallback. WITH CHECK is asymmetric: '
  'tenants cannot INSERT/UPDATE system-wide rows — that path '
  'elevates to forge_admin BYPASSRLS via runAsSystem (super_admin '
  'Feature Flags screen) or runs as the deployment role from '
  'migration seeds.';

commit;
