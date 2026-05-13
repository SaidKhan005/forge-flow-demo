-- B6 - benchmark override hierarchy.
--
-- Operator benchmark standards can be configured at the business,
-- org-unit, or location scope. The effective value for a location is:
-- location override, nearest ancestor org-unit override, operator-wide
-- override, then the existing target-cycle/baseline value. This migration
-- adds only the temporal override table; existing target_cycles and
-- active_target_profiles remain untouched.

begin;

create extension if not exists ltree;

create table if not exists public.benchmark_overrides (
  override_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scope_type text not null
    check (scope_type in ('operator_wide', 'org_unit', 'location')),
  org_unit_id uuid null,
  location_id uuid null,
  metric_key text not null
    check (metric_key in ('target_cplh', 'target_splh', 'target_ppa')),
  override_value numeric(12, 4) not null
    check (override_value > 0),
  effective_from timestamptz not null default now(),
  effective_until timestamptz null
    check (effective_until is null or effective_until > effective_from),
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint benchmark_overrides_scope_payload_ck
    check (
      (scope_type = 'operator_wide'
        and org_unit_id is null
        and location_id is null)
      or
      (scope_type = 'org_unit'
        and org_unit_id is not null
        and location_id is null)
      or
      (scope_type = 'location'
        and location_id is not null
        and org_unit_id is null)
    ),
  constraint benchmark_overrides_org_unit_fk
    foreign key (operator_id, org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint benchmark_overrides_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.benchmark_overrides is
  'B6 hierarchy-scoped benchmark override table. Stores temporal CPLH, SPLH, '
  'and PPA operator settings at operator_wide, org_unit, or location scope. '
  'Effective reads resolve lowest configured scope first.';

comment on column public.benchmark_overrides.scope_type is
  'operator_wide, org_unit, or location. Operator-facing copy may call '
  'operator_wide "Business", but the wire value matches existing role-scope '
  'vocabulary.';

create unique index if not exists benchmark_overrides_current_uq
  on public.benchmark_overrides (
    operator_id,
    metric_key,
    scope_type,
    coalesce(org_unit_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where effective_until is null;

create index if not exists benchmark_overrides_operator_scope_idx
  on public.benchmark_overrides (
    operator_id,
    scope_type,
    org_unit_id,
    location_id,
    metric_key,
    effective_from desc
  );

create index if not exists benchmark_overrides_operator_metric_current_idx
  on public.benchmark_overrides (
    operator_id,
    metric_key,
    effective_from desc
  )
  where effective_until is null;

alter table public.benchmark_overrides enable row level security;

drop policy if exists "benchmark_overrides_per_tenant"
  on public.benchmark_overrides;
create policy "benchmark_overrides_per_tenant"
  on public.benchmark_overrides for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "benchmark_overrides_per_tenant"
  on public.benchmark_overrides is
  'B6 per-tenant policy. Uses app_current_operator() wrapper so RLS planner '
  'pushdown can use operator-leading indexes. forge_admin BYPASSRLS handles '
  'audited cross-tenant support paths. This hierarchy table intentionally '
  'does not clamp every row to app_current_location(): operator_wide and '
  'org_unit rows have no location_id, and the owner/admin editor must render '
  'the full inheritance tree. Location authority is enforced at the proxy by '
  'operator_owner/operator_admin plus forgeflow.baseline.override permission.';

revoke all on public.benchmark_overrides from public;
grant select, insert, update on public.benchmark_overrides to service_role;
grant select, insert, update on public.benchmark_overrides to forge_admin;

drop trigger if exists benchmark_overrides_set_updated_at
  on public.benchmark_overrides;
create trigger benchmark_overrides_set_updated_at
before update on public.benchmark_overrides
for each row execute function public.cloud_foundation_set_updated_at();

commit;
