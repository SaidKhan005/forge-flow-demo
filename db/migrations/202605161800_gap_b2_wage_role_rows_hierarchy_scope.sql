-- GAP B2 — hierarchy scope for wage_role_rows (HP #11 per-field
-- inheritance, wage slice only).
--
-- Authority anchors
-- -----------------
--   * CLAUDE.md HP #11 — every settings / pricing surface must show
--     selected scope, inherited source, and effective value. Wage
--     Authority (lib/operator_web/screens/wage_authority_screen.dart)
--     was hardcoded to Location scope because the table carried only
--     (operator_id, location_id) and inheritance could not be expressed.
--   * docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md
--     Gap 32 — known post-V1 follow-up; this migration closes the wage
--     slice. The other 4 HP #11 tables remain the broader B1 follow-up.
--   * Exemplar mirrored EXACTLY:
--     db/migrations/202605131550_benchmark_overrides_hierarchy.sql
--     (scope_type enum check + nullable org_unit_id + nullable
--     location_id + scope-aware payload check + operator_id-leading
--     index + RLS-ready posture).
--   * db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql
--     — the table this migration ADDITIVELY alters.
--
-- Why ADDITIVE ALTER (not a new table)
-- ------------------------------------
-- benchmark_overrides is a fresh temporal override table. wage_role_rows
-- already exists, already carries per-(operator, location, restaurant,
-- role) rows, and the proxy write path + mobile sync already read/write
-- it. Adding a parallel override table would fork the read seam and
-- break the existing natural-key contract. Instead we ADD three nullable
-- columns and DEFAULT scope_type to 'location' so every existing row,
-- and every existing proxy/mobile write that omits the new columns,
-- stays valid and keeps its current (Location-scoped) meaning. A
-- business- or org-unit-scoped wage row is a new row whose scope_type is
-- 'operator_wide' or 'org_unit' with location_id NULL; absence of a
-- lower-scope row = inherit (resolver in
-- lib/services/wage/wage_role_row_scope_resolver.dart).
--
-- CLAUDE.md compliance
-- --------------------
--   * RLS-ready: the existing wage_role_rows_per_tenant policy clamps to
--     app_current_operator() AND app_current_location(). operator_wide /
--     org_unit rows have NULL location_id, so this migration RELAXES the
--     policy to the benchmark_overrides posture (operator-only) so the
--     owner/admin editor can render the full inheritance tree. Location
--     authority stays enforced at the proxy by operator_owner /
--     operator_admin (kOperatorWriteRoles) exactly as today. HP #4
--     per-operator isolation is unchanged (still clamped to
--     app_current_operator()).
--   * Every new B-tree index leads with operator_id.
--   * Idempotent: `add column if not exists`, `drop ... if exists`
--     before re-create, guarded constraint adds.
--   * Composite FK to org_units mirrors the benchmark_overrides
--     (operator_id, org_unit_id) cross-tenant chain.

begin;

-- 1. Scope columns. Default scope_type = 'location' so every existing
--    row (and every proxy/mobile write that omits the column) keeps its
--    current Location-scoped meaning with zero behaviour change.
alter table public.wage_role_rows
  add column if not exists scope_type text not null default 'location';

alter table public.wage_role_rows
  add column if not exists org_unit_id uuid null;

-- inherited_from_scope_id is denormalized provenance: when a row is
-- materialised at a lower scope by copying a higher-scope value, this
-- records which scope it came from. NULL = the row carries its own
-- value at its own scope (set-here, not inherited).
alter table public.wage_role_rows
  add column if not exists inherited_from_scope_id uuid null;

comment on column public.wage_role_rows.scope_type is
  'GAP B2 HP #11 wage scope. operator_wide | org_unit | location. '
  'Operator-facing copy calls operator_wide "Business"; the wire value '
  'matches benchmark_overrides vocabulary. Defaults to location so '
  'legacy rows + omitting writers stay Location-scoped.';

comment on column public.wage_role_rows.org_unit_id is
  'Set only when scope_type = org_unit (the region/group this wage row '
  'is configured at). NULL for operator_wide + location scopes.';

comment on column public.wage_role_rows.inherited_from_scope_id is
  'Denormalized provenance. When a value was copied down from a higher '
  'scope, the scope id it came from; NULL when set at this row''s own '
  'scope. The runtime effective value is computed by '
  'WageRoleRowScopeResolver (lowest configured scope wins).';

-- 2. scope_type enum + scope payload checks (mirror benchmark_overrides
--    benchmark_overrides_scope_payload_ck EXACTLY: location_id present
--    only for location scope; org_unit_id present only for org_unit
--    scope; operator_wide carries neither).
alter table public.wage_role_rows
  drop constraint if exists wage_role_rows_scope_type_ck;
alter table public.wage_role_rows
  add constraint wage_role_rows_scope_type_ck
  check (scope_type in ('operator_wide', 'org_unit', 'location'));

alter table public.wage_role_rows
  drop constraint if exists wage_role_rows_scope_payload_ck;
alter table public.wage_role_rows
  add constraint wage_role_rows_scope_payload_ck
  check (
    (scope_type = 'operator_wide'
      and org_unit_id is null)
    or
    (scope_type = 'org_unit'
      and org_unit_id is not null)
    or
    (scope_type = 'location'
      and org_unit_id is null)
  );

-- 3. Composite FK to org_units, mirroring benchmark_overrides_org_unit_fk
--    (the (operator_id, org_unit_id) pair must point at an org unit
--    owned by the same operator).
alter table public.wage_role_rows
  drop constraint if exists wage_role_rows_org_unit_fk;
alter table public.wage_role_rows
  add constraint wage_role_rows_org_unit_fk
  foreign key (operator_id, org_unit_id)
  references public.org_units(operator_id, id)
  on delete cascade;

-- 4. Operator-leading scope index (RLS-ready rule: every fact-table
--    B-tree index leads with operator_id). Mirrors
--    benchmark_overrides_operator_scope_idx shape.
create index if not exists wage_role_rows_operator_scope_idx
  on public.wage_role_rows (
    operator_id,
    scope_type,
    org_unit_id,
    location_id,
    labor_bucket,
    role_name
  );

-- 5. RLS posture. The existing wage_role_rows_per_tenant policy clamps
--    to operator AND location. operator_wide / org_unit rows have NULL
--    location_id, so they would be invisible under that policy and the
--    owner/admin inheritance editor could not render them. Relax to the
--    benchmark_overrides per-tenant posture (operator-only) — location
--    authority stays enforced at the proxy by operator_owner /
--    operator_admin (kOperatorWriteRoles), exactly as today. HP #4
--    per-operator isolation is preserved (still app_current_operator()).
drop policy if exists "wage_role_rows_per_tenant"
  on public.wage_role_rows;
create policy "wage_role_rows_per_tenant"
  on public.wage_role_rows for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "wage_role_rows_per_tenant"
  on public.wage_role_rows is
  'GAP B2 per-tenant policy. Was operator AND location; relaxed to the '
  'benchmark_overrides posture (operator-only) so operator_wide + '
  'org_unit wage rows (location_id NULL) are visible to the owner/admin '
  'inheritance editor. Location authority is still enforced at the '
  'proxy by operator_owner/operator_admin (kOperatorWriteRoles). '
  'forge_admin BYPASSRLS handles audited cross-tenant support paths.';

commit;
