-- Phase 9.0Σ.g (B28 in phase_9_execution_backlog.md / item 6 in
-- phase_9_scalability_decisions_2026-04-27.md) — usage_caps + usage_logs
-- two-slot key migration, step 1 of 3: ADD columns.
--
-- Source decision (lock 2026-04-27, item 6 "Decision C usage_caps two-slot
-- key"): `usage_caps` evolves to a logical key of
--
--   (billing_owner_org_unit_id, scoped_org_unit_id,
--    location_id, staff_id, workflow_id, usage_class)
--
-- where `billing_owner_org_unit_id` is who pays (the franchisee /
-- corporate / brand entity that the cap charges against) and
-- `scoped_org_unit_id` is where the cap applies (the same node, a
-- descendant brand, a region, etc.). Two slots in the key let the same
-- table model:
--
--   * company-wide caps (billing = scoped = corp root),
--   * brand or sub-org caps (billing = corp, scoped = a child node),
--   * location-specific caps (location_id pins down a single venue),
--   * staff or workflow caps (staff_id / workflow_id narrow further).
--
-- This slice is **online-friendly step 1 of 3**:
--
--   step a (this file):       ADD columns, all nullable.
--   step b (`..._b_backfill`): UPDATE existing rows so billing_owner +
--                              scoped point at each operator's root
--                              org_units row.
--   step c (`..._c_constraint_flip`): SET NOT NULL on the two
--                              org-unit columns, swap the primary key
--                              to a tenant-leading surrogate, attach
--                              the logical-key UNIQUE constraint, the
--                              org_units FKs, and the tenant-leading
--                              cap-vs-actual indexes.
--
-- Splitting the work across three migrations means the first two are
-- safe to apply ahead of any code change — existing reads/writes
-- against `usage_caps` and `usage_logs` keep working because the new
-- columns are nullable and the old key is intact. The constraint flip
-- only lands once the calling code (proxy upserts, accounting service,
-- usage repositories) has been taught the new shape; until then the
-- columns are dormant.
--
-- Hard constraints (block 2 of the slice prompt):
--   * Pre-assigned filenames `202604280006_a/b/c_*` — do not rename.
--   * No edits to applied migrations (`202604250*.sql`,
--     `202604280000_*.sql`, `202604280001_*.sql`, `202604280002_*.sql`,
--     `202604280003_*.sql`).
--   * No RLS policy bodies touched here — this slice is purely column
--     additions; existing service-role-all stubs from
--     202604250005 stay in place. Wrapper functions
--     (`public.app_current_operator()` etc.) are introduced in 9.0Σ.b
--     and used by the constraint-flip step's documentation only.
--   * No actor_kind, sp:-prefixed JWT, audit_logs, service principals,
--     or proxy hot-zone changes — those land in disjoint slices.
--
-- Idempotent: every ALTER uses `add column if not exists`.

begin;

-- ─── usage_caps (cap definitions) ──────────────────────────────────
--
-- Cap rows describe a budget: who pays + where it applies + which
-- usage class. The two new org-unit columns separate the billing
-- owner from the scoped applicability so a corporate parent can
-- centrally fund a sub-brand's caps without losing per-brand
-- attribution. Both columns are nullable in this step so the
-- existing rows (which carry no org-unit attribution yet) remain
-- valid until step b backfills them. `staff_id` and `workflow_id`
-- stay nullable forever — most caps are not pinned to a single
-- staff member or workflow.

alter table public.usage_caps
  add column if not exists billing_owner_org_unit_id uuid;

alter table public.usage_caps
  add column if not exists scoped_org_unit_id uuid;

alter table public.usage_caps
  add column if not exists staff_id uuid null;

alter table public.usage_caps
  add column if not exists workflow_id uuid null;

comment on column public.usage_caps.billing_owner_org_unit_id is
  'Phase 9.0Σ.g (item 6) — who pays. References '
  'org_units(operator_id, id) via the composite FK added in step c. '
  'For a corp-only operator this is the corp root; for a franchise '
  'it is the franchisee node that owns the spend. Nullable in step a; '
  'becomes NOT NULL after step c.';

comment on column public.usage_caps.scoped_org_unit_id is
  'Phase 9.0Σ.g (item 6) — where the cap applies. References '
  'org_units(operator_id, id). Combined with billing_owner_org_unit_id '
  'this lets one row describe a corp paying for a sub-brand''s usage. '
  'Nullable in step a; becomes NOT NULL after step c.';

comment on column public.usage_caps.staff_id is
  'Phase 9.0Σ.g (item 6) — optional axis. NULL = the cap applies '
  'across all staff at the scoped org/location. NOT NULL = a per-staff '
  'cap. Stays nullable forever; UNIQUE NULLS NOT DISTINCT in step c '
  'collapses NULL = NULL so two NULL-staff rows still conflict on the '
  'logical key.';

comment on column public.usage_caps.workflow_id is
  'Phase 9.0Σ.g (item 6) — optional axis. NULL = the cap applies '
  'across all workflows. NOT NULL = a per-workflow cap (Phase 12 '
  'workflow runtime). Stays nullable forever; UNIQUE NULLS NOT DISTINCT '
  'in step c handles the NULL = NULL identity case.';

-- ─── usage_logs (per-period rollup of actuals) ────────────────────
--
-- The same four axes land on `usage_logs` so cap-vs-actual
-- reconciliation joins on a single composite key in step c. Every
-- column is nullable in this step for the same reason as
-- `usage_caps`: existing rows have no attribution, and the
-- constraint flip waits for the backfill in step b.
--
-- usage_logs is range-partitioned on `period_start` (declared in
-- 202604250005). PG accepts `add column if not exists` on the
-- partitioned parent and propagates the change to every partition,
-- including `usage_logs_default`. No per-partition repeat needed.

alter table public.usage_logs
  add column if not exists billing_owner_org_unit_id uuid;

alter table public.usage_logs
  add column if not exists scoped_org_unit_id uuid;

alter table public.usage_logs
  add column if not exists staff_id uuid null;

alter table public.usage_logs
  add column if not exists workflow_id uuid null;

comment on column public.usage_logs.billing_owner_org_unit_id is
  'Phase 9.0Σ.g (item 6) — billing-owner axis mirrored from usage_caps '
  'so cap-vs-actual reconciliation joins on a single composite key. '
  'Nullable in step a; SET NOT NULL in step c.';

comment on column public.usage_logs.scoped_org_unit_id is
  'Phase 9.0Σ.g (item 6) — scoped-org axis mirrored from usage_caps. '
  'Nullable in step a; SET NOT NULL in step c.';

comment on column public.usage_logs.staff_id is
  'Phase 9.0Σ.g (item 6) — per-staff actuals attribution; NULL when '
  'the row covers all staff at the scoped org/location.';

comment on column public.usage_logs.workflow_id is
  'Phase 9.0Σ.g (item 6) — per-workflow actuals attribution; NULL when '
  'the row covers all workflows.';

commit;
