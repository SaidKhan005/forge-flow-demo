-- Phase 9.0Σ.g (B28 / item 6) — usage_caps + usage_logs two-slot key
-- migration, step 2 of 3: BACKFILL.
--
-- Step a (`..._a_add`) added the four new columns nullable. This file
-- resolves each operator's root `org_units` row (the one created by
-- 202604280002 with `parent_id IS NULL`) and writes its UUID into
-- `billing_owner_org_unit_id` and `scoped_org_unit_id` on every
-- existing `usage_caps` and `usage_logs` row that does not yet carry
-- those values.
--
-- The single-root-per-operator invariant is enforced in
-- 202604280002 by:
--
--   * the partial unique index `org_units_one_root_per_operator_uq`
--     (covers the (operator_id, parent_id IS NULL) lookup), and
--   * the backfill block in 202604280002 itself (every operator
--     already has exactly one root after that migration applies).
--
-- Both guarantees mean the subqueries below resolve to exactly one
-- row per operator. If a row pre-dates 202604280002 — impossible
-- under the locked migration order, but defensive — the UPDATE
-- skips it (no matching root row → no FROM match → no UPDATE).
--
-- `staff_id` and `workflow_id` are explicitly NOT touched here. The
-- locked design keeps them nullable forever (most caps and most log
-- rows are not pinned to a single staff member or workflow); the
-- step-c UNIQUE NULLS NOT DISTINCT collapses NULL = NULL so the
-- logical-key uniqueness still holds.
--
-- Idempotence: each UPDATE filters on
-- `billing_owner_org_unit_id IS NULL OR scoped_org_unit_id IS NULL`
-- so a re-run is a no-op once the rows are populated. The partial
-- predicate also lets the backfill run before step c without
-- racing the SET NOT NULL — once every row has a non-NULL value,
-- the UPDATE matches nothing on subsequent runs.
--
-- Hard constraints (block 2 of the slice prompt):
--   * No edits to applied migrations.
--   * No RLS policy bodies touched.
--   * No actor_kind, sp:-prefixed JWT, audit_logs, service principals,
--     or proxy hot-zone changes.
--   * No `forge_admin` RLS policy added.
--
-- This migration is local framework only — no live database mutation.

begin;

-- ─── usage_caps backfill ───────────────────────────────────────────
--
-- Existing rows are pinned to the operator's root because no finer
-- attribution exists yet (the operator never carried org-unit context
-- before 9.0Σ.c). After backfill, every row's billing owner and scoped
-- org collapse to the same node — the corp root — which is consistent
-- with how the legacy `(operator_id, location_id, usage_class)` PK
-- modeled the cap surface. New rows that need finer attribution
-- (sub-brand caps, regional caps) flow from the proxy admin path
-- once usage_*.dart catches up; this backfill exists strictly to
-- make the existing rows compatible with the step-c constraint flip.

update public.usage_caps as caps
   set billing_owner_org_unit_id = root.id,
       scoped_org_unit_id = root.id
  from public.org_units as root
 where root.operator_id = caps.operator_id
   and root.parent_id is null
   and (
        caps.billing_owner_org_unit_id is null
     or caps.scoped_org_unit_id is null
   );

-- ─── usage_logs backfill ───────────────────────────────────────────
--
-- Same shape as the cap backfill. usage_logs is partitioned on
-- `period_start`; UPDATE on the partitioned parent fans out to every
-- partition (including `usage_logs_default`). The
-- `(operator_id, location_id, usage_class, period_start, ...)` PK on
-- 202604250006 already keeps each (operator, period, telemetry-tuple)
-- row unique, so two log rows for the same operator can never collide
-- on the cap-shape attribution after backfill — they still differ on
-- the telemetry dims that step c keeps in the rollup-identity UNIQUE.

update public.usage_logs as logs
   set billing_owner_org_unit_id = root.id,
       scoped_org_unit_id = root.id
  from public.org_units as root
 where root.operator_id = logs.operator_id
   and root.parent_id is null
   and (
        logs.billing_owner_org_unit_id is null
     or logs.scoped_org_unit_id is null
   );

commit;
