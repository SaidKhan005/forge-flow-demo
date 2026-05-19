-- Wage Role Rows hierarchy scope refresh.
--
-- Schema-touching risk:
--   * Adds hierarchy scope columns to public.wage_role_rows.
--   * Allows location_id to be NULL only for business/org-unit scoped rows.
--   * Relaxes the wage_role_rows RLS policy from operator+location to
--     operator-only so operator owners can read/write higher-scope wage rows.
--
-- This intentionally reuses the unmerged PR #836 direction, but fixes two
-- live-path gaps from that closed branch:
--   * The prior migration described NULL location_id rows without dropping the
--     NOT NULL constraint.
--   * The uniqueness/upsert path still only targeted location rows.

begin;

alter table public.wage_role_rows
  add column if not exists scope_type text not null default 'location';

alter table public.wage_role_rows
  add column if not exists org_unit_id uuid null;

alter table public.wage_role_rows
  add column if not exists inherited_from_scope_id uuid null;

-- Higher-scope rows do not belong to one location. Existing rows keep their
-- location payload and the CHECK below still requires location_id for
-- location-scoped rows.
alter table public.wage_role_rows
  alter column location_id drop not null;

comment on column public.wage_role_rows.scope_type is
  'Hierarchy scope for wage authority rows: operator_wide, org_unit, or '
  'location. Operator-facing copy displays operator_wide as Business.';

comment on column public.wage_role_rows.org_unit_id is
  'Set only when scope_type = org_unit. Null for operator_wide and location.';

comment on column public.wage_role_rows.inherited_from_scope_id is
  'Optional provenance for materialized inherited values. Null means the row '
  'is set at its own scope.';

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
    (
      scope_type = 'operator_wide'
      and org_unit_id is null
      and location_id is null
    )
    or
    (
      scope_type = 'org_unit'
      and org_unit_id is not null
      and location_id is null
    )
    or
    (
      scope_type = 'location'
      and org_unit_id is null
      and location_id is not null
    )
  );

alter table public.wage_role_rows
  drop constraint if exists wage_role_rows_operator_fk;

alter table public.wage_role_rows
  add constraint wage_role_rows_operator_fk
  foreign key (operator_id)
  references public.operators(operator_id)
  on delete cascade;

alter table public.wage_role_rows
  drop constraint if exists wage_role_rows_org_unit_fk;

alter table public.wage_role_rows
  add constraint wage_role_rows_org_unit_fk
  foreign key (operator_id, org_unit_id)
  references public.org_units(operator_id, id)
  on delete cascade;

-- Null-safe uniqueness for upsert across every scope. The original
-- location-only unique index remains in place for legacy callers; this index
-- is the hierarchy-aware conflict target used by the refreshed repository.
create unique index if not exists wage_role_rows_scope_role_unique_idx
  on public.wage_role_rows (
    operator_id,
    scope_type,
    coalesce(org_unit_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
    restaurant_id,
    role_name
  );

create index if not exists wage_role_rows_operator_scope_idx
  on public.wage_role_rows (
    operator_id,
    scope_type,
    org_unit_id,
    location_id,
    labor_bucket,
    role_name,
    updated_at desc
  );

drop policy if exists "wage_role_rows_per_tenant"
  on public.wage_role_rows;

create policy "wage_role_rows_per_tenant"
  on public.wage_role_rows for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "wage_role_rows_per_tenant"
  on public.wage_role_rows is
  'Operator-only tenant policy so business and org-unit wage rows can be '
  'read by the operator owner hierarchy editor. Per-operator isolation still '
  'uses app_current_operator(); proxy role checks control who may mutate.';

commit;
