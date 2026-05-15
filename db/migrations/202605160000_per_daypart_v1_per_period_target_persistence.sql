-- Per-Daypart Targets V1 — Slice 1
--
-- Per-period data layer foundation. Three additive surfaces:
--
--   * `public.target_cycle_dayparts` — one row per (cycle, service_period).
--     Carries per-period CPLH/SPLH/PPA + OPZ band + cover_count (the
--     per-period candidate cover total at compute time, used for
--     cover-weighted whole-day pool rollup inside the cycle write path).
--
--   * `public.weekly_plan_snapshot_day_dayparts` — one row per
--     (snapshot, business_date, service_period). Carries per-(day,
--     period) demand-derived values stamped at lock time: forecast
--     covers + sales + required FOH/BOH hours + theoretical FOH/BOH
--     dollars (wages stay whole-day per Design Rule 5).
--
--   * `public.weekly_plan_snapshots.wage_at_lock_time_json` (JSONB) —
--     audit checks comparing locked dollar values against wages must
--     compare against THIS column, not against `ActiveTargetProfile`
--     current wages (Design Rule 8).
--
--   * Per-shift per-period target stamp columns on `public.shift_records`
--     (`daypart_target_cplh` etc.) — closed-truth retains the stamp
--     from its close time per Promise 2.
--
-- RLS posture (per
-- `docs/contracts/hardening_rls_and_repository_pattern_contract.md`):
--   * every new operator-scoped table carries `(operator_id, location_id)`.
--   * every hot-path B-tree index leads with `(operator_id, location_id)`.
--   * policies use the four sanctioned wrapper functions
--     (`app_current_operator()`, `app_current_location()`); bare
--     `current_setting('app.*')` is forbidden.
--   * tables `ENABLE ROW LEVEL SECURITY`; `service_role` + `forge_admin`
--     receive least-privilege grants.

begin;

create extension if not exists pgcrypto;

-- ── target_cycle_dayparts ────────────────────────────────────────────────
create table if not exists public.target_cycle_dayparts (
  cycle_id uuid not null,
  operator_id uuid not null,
  location_id uuid not null,
  service_period_id text not null
    check (length(trim(service_period_id)) > 0),

  target_cplh numeric(12, 4) not null
    check (target_cplh >= 0),
  target_splh numeric(12, 4) not null
    check (target_splh >= 0),
  target_ppa numeric(12, 4) not null
    check (target_ppa >= 0),
  opz_floor_cplh numeric(12, 4) not null
    check (opz_floor_cplh >= 0),
  opz_ceiling_cplh numeric(12, 4) not null
    check (opz_ceiling_cplh >= opz_floor_cplh),
  cover_count integer not null
    check (cover_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  primary key (cycle_id, service_period_id),
  constraint target_cycle_dayparts_cycle_fk
    foreign key (operator_id, cycle_id)
    references public.target_cycles(operator_id, cycle_id)
    on delete cascade,
  constraint target_cycle_dayparts_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.target_cycle_dayparts is
  'Per-(cycle, service_period) locked target standards. Parent target_cycles '
  'row stores cover-weighted whole-day pool fields as a derived rollup cache; '
  'pool is recomputed from these per-period rows inside the cycle write path.';

comment on column public.target_cycle_dayparts.cover_count is
  'Per-period candidate cover total at compute time, used for the '
  'cover-weighted whole-day pool rollup.';

-- Operator-leading index per RLS pattern. Composite includes cycle_id last
-- so target_cycle range queries by (operator_id, location_id, cycle_id)
-- and per-cycle-period lookups by (operator_id, location_id, cycle_id,
-- service_period_id) both probe by index.
create index if not exists target_cycle_dayparts_cycle_idx
  on public.target_cycle_dayparts (
    operator_id,
    location_id,
    cycle_id,
    service_period_id
  );

alter table public.target_cycle_dayparts enable row level security;

drop policy if exists "target_cycle_dayparts_per_tenant_location"
  on public.target_cycle_dayparts;
create policy "target_cycle_dayparts_per_tenant_location"
  on public.target_cycle_dayparts for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.target_cycle_dayparts from public;
grant select, insert, update, delete on public.target_cycle_dayparts to service_role;
grant select, insert, update, delete on public.target_cycle_dayparts to forge_admin;

drop trigger if exists target_cycle_dayparts_set_updated_at
  on public.target_cycle_dayparts;
create trigger target_cycle_dayparts_set_updated_at
before update on public.target_cycle_dayparts
for each row execute function public.cloud_foundation_set_updated_at();

-- ── weekly_plan_snapshot_day_dayparts ────────────────────────────────────
create table if not exists public.weekly_plan_snapshot_day_dayparts (
  snapshot_id uuid not null,
  operator_id uuid not null,
  location_id uuid not null,
  business_date date not null,
  service_period_id text not null
    check (length(trim(service_period_id)) > 0),

  forecast_covers integer not null
    check (forecast_covers >= 0),
  forecast_sales numeric(14, 4) not null
    check (forecast_sales >= 0),
  required_foh_hours numeric(12, 4) not null
    check (required_foh_hours >= 0),
  required_boh_hours numeric(12, 4) not null
    check (required_boh_hours >= 0),
  theoretical_foh_dollars numeric(14, 4) not null
    check (theoretical_foh_dollars >= 0),
  theoretical_boh_dollars numeric(14, 4) not null
    check (theoretical_boh_dollars >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  primary key (snapshot_id, business_date, service_period_id),
  constraint weekly_plan_snapshot_day_dayparts_snapshot_fk
    foreign key (operator_id, snapshot_id)
    references public.weekly_plan_snapshots(operator_id, snapshot_id)
    on delete cascade,
  constraint weekly_plan_snapshot_day_dayparts_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.weekly_plan_snapshot_day_dayparts is
  'Per-(snapshot, business_date, service_period) demand-derived values '
  'stamped at weekly plan lock time. Per Design Rule 5 wages stay '
  'whole-day; per-period theoretical dollars use whole-day wages × '
  'per-period required hours.';

create index if not exists weekly_plan_snapshot_day_dayparts_snapshot_idx
  on public.weekly_plan_snapshot_day_dayparts (
    operator_id,
    location_id,
    snapshot_id,
    business_date
  );

alter table public.weekly_plan_snapshot_day_dayparts enable row level security;

drop policy if exists "weekly_plan_snapshot_day_dayparts_per_tenant_location"
  on public.weekly_plan_snapshot_day_dayparts;
create policy "weekly_plan_snapshot_day_dayparts_per_tenant_location"
  on public.weekly_plan_snapshot_day_dayparts for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.weekly_plan_snapshot_day_dayparts from public;
grant select, insert, update, delete on public.weekly_plan_snapshot_day_dayparts to service_role;
grant select, insert, update, delete on public.weekly_plan_snapshot_day_dayparts to forge_admin;

drop trigger if exists weekly_plan_snapshot_day_dayparts_set_updated_at
  on public.weekly_plan_snapshot_day_dayparts;
create trigger weekly_plan_snapshot_day_dayparts_set_updated_at
before update on public.weekly_plan_snapshot_day_dayparts
for each row execute function public.cloud_foundation_set_updated_at();

-- ── weekly_plan_snapshots.wage_at_lock_time_json ─────────────────────────
-- Audit checks for locked dollar values compare against this column,
-- never `ActiveTargetProfile` current wages. Nullable for backward
-- compatibility with existing rows; new writes always populate.
alter table public.weekly_plan_snapshots
  add column if not exists wage_at_lock_time_json jsonb;

comment on column public.weekly_plan_snapshots.wage_at_lock_time_json is
  'JSON stamp of {"foh_wage", "boh_wage", "blended_wage"} at lock time. '
  'Audit checks comparing locked dollar values must reference this column '
  '(Design Rule 8), not ActiveTargetProfile current wages.';

-- ── shift_records per-shift per-period target stamp columns ─────────────
-- Closed-truth retains the stamp from its close time per Promise 2.
-- Demo reseed populates the columns on regenerate. All additive +
-- nullable for backward compatibility with rows that pre-date V1.
alter table public.shift_records
  add column if not exists daypart_target_cplh numeric(12, 4),
  add column if not exists daypart_target_splh numeric(12, 4),
  add column if not exists daypart_target_ppa numeric(12, 4),
  add column if not exists daypart_opz_floor_cplh numeric(12, 4),
  add column if not exists daypart_opz_ceiling_cplh numeric(12, 4);

comment on column public.shift_records.daypart_target_cplh is
  'Per-shift per-period locked target CPLH at close time. Promise 2: '
  'closed truth retains its stamp.';
comment on column public.shift_records.daypart_target_splh is
  'Per-shift per-period locked target SPLH at close time.';
comment on column public.shift_records.daypart_target_ppa is
  'Per-shift per-period locked target PPA at close time.';
comment on column public.shift_records.daypart_opz_floor_cplh is
  'Per-shift per-period locked OPZ floor CPLH at close time.';
comment on column public.shift_records.daypart_opz_ceiling_cplh is
  'Per-shift per-period locked OPZ ceiling CPLH at close time.';

commit;
