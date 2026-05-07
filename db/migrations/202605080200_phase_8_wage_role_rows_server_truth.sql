-- Phase 8 mobile settings spine: server truth for wage role rows.
--
-- Admin/web wage source and role/job-code mapping settings affect mobile
-- labor calculations, so the operator-configured wage mix needs a
-- tenant-scoped Postgres source of truth. SQLite remains a mobile cache and
-- does not need to reuse the server UUID as its local integer id.
--
-- RLS posture:
--   * table is operator/location scoped from creation.
--   * hot-path B-tree indexes start with operator_id.
--   * policy bodies call app_current_operator() / app_current_location().

begin;

create extension if not exists pgcrypto;

create table if not exists public.wage_role_rows (
  wage_role_row_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  restaurant_id text not null
    check (length(btrim(restaurant_id)) between 1 and 128),
  role_name text not null
    check (
      length(btrim(role_name)) between 1 and 128
      and role_name = btrim(role_name)
    ),
  labor_bucket text not null
    check (labor_bucket in ('foh', 'boh', 'manager')),
  hourly_rate numeric(12, 4) not null
    check (hourly_rate >= 0 and hourly_rate <= 10000),
  weighted_hours numeric(12, 4) not null
    check (weighted_hours >= 0 and weighted_hours <= 10000),

  -- Optional mapping metadata from scheduling/labor systems. QuickBooks Time
  -- uses job codes; Humanity/Agendrix expose positions; manual rows can leave
  -- these null.
  job_code text
    check (
      job_code is null
      or (
        length(btrim(job_code)) between 1 and 128
        and job_code = btrim(job_code)
      )
    ),
  vendor_id text
    check (
      vendor_id is null
      or (
        length(btrim(vendor_id)) between 1 and 64
        and vendor_id = btrim(vendor_id)
      )
    ),
  vendor_role_id text
    check (
      vendor_role_id is null
      or (
        length(btrim(vendor_role_id)) between 1 and 128
        and vendor_role_id = btrim(vendor_role_id)
      )
    ),
  source text not null default 'operator_manual'
    check (source in (
      'operator_manual',
      'vendor_per_position',
      'admin_seed',
      'migration_seed'
    )),
  is_active boolean not null default true,
  effective_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text,

  constraint wage_role_rows_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.wage_role_rows is
  'Phase 8 mobile settings spine server truth for operator wage mix rows. '
  'Mobile reads this as cache input; local SQLite ids remain local.';

comment on column public.wage_role_rows.wage_role_row_id is
  'Server UUID for sync/audit identity. Mobile must not treat this as its '
  'SQLite integer id.';

create unique index if not exists wage_role_rows_role_unique_idx
  on public.wage_role_rows (
    operator_id,
    location_id,
    restaurant_id,
    role_name
  );

create index if not exists wage_role_rows_bucket_role_idx
  on public.wage_role_rows (
    operator_id,
    location_id,
    labor_bucket,
    role_name
  );

create index if not exists wage_role_rows_updated_idx
  on public.wage_role_rows (
    operator_id,
    location_id,
    updated_at desc,
    wage_role_row_id
  );

create index if not exists wage_role_rows_mapping_idx
  on public.wage_role_rows (
    operator_id,
    location_id,
    vendor_id,
    job_code
  )
  where vendor_id is not null or job_code is not null;

alter table public.wage_role_rows enable row level security;

drop policy if exists "wage_role_rows_per_tenant"
  on public.wage_role_rows;
create policy "wage_role_rows_per_tenant"
  on public.wage_role_rows for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.wage_role_rows from public;
grant select, insert, update on public.wage_role_rows to service_role;
grant select, insert, update on public.wage_role_rows to forge_admin;

commit;
