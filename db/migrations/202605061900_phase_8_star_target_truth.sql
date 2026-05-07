-- Phase 8 star/target truth: selected stars, target cycles, profiles.
--
-- This migration is additive server truth for Doc 1 mobile core logic:
--
--   * selected_star_shift_decisions: append-only manager/admin select/clear
--     decisions. Recommendations are referenced as provenance, never stored
--     as manager-selected rows.
--   * target_cycles: server-owned locked target cycles.
--   * active_target_profiles: server projection of the active target cycle.
--   * target_profile_versions: immutable profile snapshots for closed-shift
--     provenance and mobile cache sync.
--   * star_target_audit_events: append-only audit ledger for later proxy
--     write paths.
--
-- RLS posture:
--   * every table is operator/location scoped.
--   * every hot-path B-tree index starts with operator_id.
--   * policies use wrapper functions, never bare current_setting().

begin;

create extension if not exists pgcrypto;

create table if not exists public.target_cycles (
  cycle_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  restaurant_id text not null
    check (length(trim(restaurant_id)) > 0),
  source text not null
    check (source in (
      'recommended',
      'manager_override',
      'admin_replacement'
    )),
  effective_start date not null,
  effective_end date not null,
  calibration_window_start date not null,
  calibration_window_end date not null,
  target_cplh numeric(12, 4) not null
    check (target_cplh >= 0),
  target_splh numeric(12, 4) not null
    check (target_splh >= 0),
  target_ppa numeric(12, 4) not null
    check (target_ppa >= 0),
  foh_wage numeric(12, 4) not null
    check (foh_wage >= 0),
  boh_wage numeric(12, 4) not null
    check (boh_wage >= 0),
  opz_floor_cplh numeric(12, 4) not null
    check (opz_floor_cplh >= 0),
  opz_ceiling_cplh numeric(12, 4) not null
    check (opz_ceiling_cplh >= opz_floor_cplh),
  manager_override_used boolean not null default false,
  manager_override_at timestamptz,
  manager_override_by_user_id uuid,
  admin_replaced_at timestamptz,
  admin_replaced_by_user_id uuid,
  supersedes_cycle_id uuid,
  selected_shift_count integer not null default 0
    check (selected_shift_count >= 0),
  selected_record_keys jsonb not null default '[]'::jsonb
    check (jsonb_typeof(selected_record_keys) = 'array'),
  selection_decision_ids jsonb not null default '[]'::jsonb
    check (jsonb_typeof(selection_decision_ids) = 'array'),
  replacement_reason text,
  idempotency_key text not null
    check (
      length(trim(idempotency_key)) between 1 and 200
    ),
  request_hash text not null
    check (length(trim(request_hash)) > 0),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deactivated_at timestamptz,

  unique (operator_id, cycle_id),
  constraint target_cycles_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint target_cycles_effective_window_check
    check (effective_end > effective_start),
  constraint target_cycles_calibration_window_check
    check (calibration_window_end >= calibration_window_start),
  constraint target_cycles_manager_override_metadata_check
    check (
      source <> 'manager_override'
      or (
        manager_override_used
        and manager_override_at is not null
      )
    ),
  constraint target_cycles_admin_replacement_metadata_check
    check (
      source <> 'admin_replacement'
      or admin_replaced_at is not null
    ),
  constraint target_cycles_idempotency_uq
    unique (operator_id, location_id, idempotency_key)
);

comment on table public.target_cycles is
  'Server-owned target cycle truth. Mobile target_cycles is a cache mirror.';

comment on column public.target_cycles.manager_override_used is
  'Server-side once-per-cycle guard. Manager overrides are denied when the '
  'currently active cycle already has this true.';

comment on column public.target_cycles.selected_record_keys is
  'Record keys used to build the cycle. Stored as provenance for mobile/cache '
  'sync; recommendation rows are not promoted into manager decisions.';

create table if not exists public.selected_star_shift_decisions (
  decision_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  restaurant_id text not null
    check (length(trim(restaurant_id)) > 0),
  record_key text not null
    check (length(trim(record_key)) > 0),
  week_id text not null
    check (length(trim(week_id)) > 0),
  day_label text not null
    check (length(trim(day_label)) > 0),
  daypart text not null
    check (length(trim(daypart)) > 0),
  business_date date not null,
  service_period_key text,
  target_cycle_id uuid,

  decision_type text not null
    check (decision_type in (
      'manager_selected',
      'manager_cleared',
      'admin_selected',
      'admin_cleared'
    )),
  decision_source text not null
    check (decision_source in ('manager', 'admin')),
  actor_user_id uuid,
  decided_at timestamptz not null default now(),

  source_system text,
  source_shift_id text,
  source_shift_record_id text,
  covers integer
    check (covers is null or covers >= 0),
  cplh numeric(12, 4)
    check (cplh is null or cplh >= 0),
  splh numeric(12, 4)
    check (splh is null or splh >= 0),
  ppa numeric(12, 4)
    check (ppa is null or ppa >= 0),
  primary_lever_id text,
  actual_labor_pct numeric(12, 4),
  has_actual_labor_pct_truth boolean not null default false,
  recommendation_reference_id text,
  candidate_snapshot jsonb not null default '{}'::jsonb
    check (jsonb_typeof(candidate_snapshot) = 'object'),
  reason text,
  idempotency_key text not null
    check (
      length(trim(idempotency_key)) between 1 and 200
    ),
  request_hash text not null
    check (length(trim(request_hash)) > 0),
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint selected_star_shift_decisions_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint selected_star_shift_decisions_cycle_fk
    foreign key (operator_id, target_cycle_id)
    references public.target_cycles(operator_id, cycle_id)
    on delete restrict,
  constraint selected_star_shift_decisions_source_matches_type_check
    check (
      (
        decision_type like 'manager_%'
        and decision_source = 'manager'
      )
      or (
        decision_type like 'admin_%'
        and decision_source = 'admin'
      )
    ),
  constraint selected_star_shift_decisions_idempotency_uq
    unique (operator_id, location_id, idempotency_key)
);

comment on table public.selected_star_shift_decisions is
  'Append-only selected-star select/clear decisions. Recommendations remain '
  'separate candidate provenance and are never fabricated as manager rows.';

comment on column public.selected_star_shift_decisions.record_key is
  'Mobile cache key shape: week_id|day_label|daypart.';

comment on column public.selected_star_shift_decisions.recommendation_reference_id is
  'Optional pointer to the recommendation/candidate that the manager reviewed. '
  'Presence here does not make the row a recommendation.';

create table if not exists public.active_target_profiles (
  target_profile_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  restaurant_id text not null
    check (length(trim(restaurant_id)) > 0),
  target_cycle_id uuid not null,
  target_profile_version_id uuid not null,
  source_type text not null
    check (source_type in (
      'cycle_recommended',
      'cycle_manager_override',
      'cycle_admin_replacement'
    )),
  target_cplh numeric(12, 4) not null
    check (target_cplh >= 0),
  target_splh numeric(12, 4) not null
    check (target_splh >= 0),
  target_ppa numeric(12, 4) not null
    check (target_ppa >= 0),
  foh_wage numeric(12, 4) not null
    check (foh_wage >= 0),
  boh_wage numeric(12, 4) not null
    check (boh_wage >= 0),
  opz_floor_cplh numeric(12, 4) not null
    check (opz_floor_cplh >= 0),
  opz_ceiling_cplh numeric(12, 4) not null
    check (opz_ceiling_cplh >= opz_floor_cplh),
  theoretical_foh_labor_pct numeric(12, 4) not null,
  theoretical_boh_labor_pct numeric(12, 4) not null,
  theoretical_labor_pct numeric(12, 4) not null,
  built_at timestamptz not null,
  projection_source text not null default 'server_target_cycle'
    check (projection_source = 'server_target_cycle'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (operator_id, target_profile_id),
  constraint active_target_profiles_restaurant_uq
    unique (operator_id, location_id, restaurant_id),
  constraint active_target_profiles_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint active_target_profiles_cycle_fk
    foreign key (operator_id, target_cycle_id)
    references public.target_cycles(operator_id, cycle_id)
    on delete restrict
);

comment on table public.active_target_profiles is
  'Current server projection of the active target cycle. Mobile '
  'active_target_profiles is a cache mirror, not the owner.';

create table if not exists public.target_profile_versions (
  target_profile_version_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  target_profile_id uuid not null,
  restaurant_id text not null
    check (length(trim(restaurant_id)) > 0),
  target_cycle_id uuid not null,
  source_type text not null
    check (source_type in (
      'cycle_recommended',
      'cycle_manager_override',
      'cycle_admin_replacement'
    )),
  target_cplh numeric(12, 4) not null
    check (target_cplh >= 0),
  target_splh numeric(12, 4) not null
    check (target_splh >= 0),
  target_ppa numeric(12, 4) not null
    check (target_ppa >= 0),
  foh_wage numeric(12, 4) not null
    check (foh_wage >= 0),
  boh_wage numeric(12, 4) not null
    check (boh_wage >= 0),
  opz_floor_cplh numeric(12, 4) not null
    check (opz_floor_cplh >= 0),
  opz_ceiling_cplh numeric(12, 4) not null
    check (opz_ceiling_cplh >= opz_floor_cplh),
  theoretical_foh_labor_pct numeric(12, 4) not null,
  theoretical_boh_labor_pct numeric(12, 4) not null,
  theoretical_labor_pct numeric(12, 4) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (operator_id, location_id, target_profile_version_id),
  constraint target_profile_versions_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint target_profile_versions_profile_fk
    foreign key (operator_id, target_profile_id)
    references public.active_target_profiles(operator_id, target_profile_id)
    on delete restrict,
  constraint target_profile_versions_cycle_fk
    foreign key (operator_id, target_cycle_id)
    references public.target_cycles(operator_id, cycle_id)
    on delete restrict
);

comment on table public.target_profile_versions is
  'Immutable target profile snapshots for closed-shift target provenance and '
  'mobile cache sync.';

create table if not exists public.star_target_audit_events (
  audit_event_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  event_type text not null
    check (event_type in (
      'selected_star_selected',
      'selected_star_cleared',
      'target_cycle_created',
      'target_cycle_replaced',
      'target_cycle_deactivated',
      'active_target_profile_projected',
      'target_profile_version_created'
    )),
  entity_table text not null
    check (entity_table in (
      'selected_star_shift_decisions',
      'target_cycles',
      'active_target_profiles',
      'target_profile_versions'
    )),
  entity_id uuid not null,
  actor_kind text not null
    check (actor_kind in ('operator_user', 'forge_admin', 'system')),
  actor_user_id uuid,
  reason text not null
    check (length(trim(reason)) > 0),
  idempotency_key text,
  before_snapshot jsonb
    check (
      before_snapshot is null
      or jsonb_typeof(before_snapshot) = 'object'
    ),
  after_snapshot jsonb
    check (
      after_snapshot is null
      or jsonb_typeof(after_snapshot) = 'object'
    ),
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now(),

  constraint star_target_audit_events_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.star_target_audit_events is
  'Append-only audit ledger for selected-star and target/profile mutations.';

drop trigger if exists target_cycles_set_updated_at
  on public.target_cycles;
create trigger target_cycles_set_updated_at
before update on public.target_cycles
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists selected_star_shift_decisions_set_updated_at
  on public.selected_star_shift_decisions;
create trigger selected_star_shift_decisions_set_updated_at
before update on public.selected_star_shift_decisions
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists active_target_profiles_set_updated_at
  on public.active_target_profiles;
create trigger active_target_profiles_set_updated_at
before update on public.active_target_profiles
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists target_profile_versions_set_updated_at
  on public.target_profile_versions;
create trigger target_profile_versions_set_updated_at
before update on public.target_profile_versions
for each row execute function public.cloud_foundation_set_updated_at();

-- Operator-leading indexes. B-tree indexes must lead with operator_id so RLS
-- predicates fold into index probes.
create unique index if not exists target_cycles_active_restaurant_uq
  on public.target_cycles (
    operator_id,
    location_id,
    restaurant_id
  )
  where deactivated_at is null;

create index if not exists target_cycles_effective_idx
  on public.target_cycles (
    operator_id,
    location_id,
    effective_start desc,
    cycle_id
  );

create index if not exists target_cycles_updated_idx
  on public.target_cycles (
    operator_id,
    location_id,
    updated_at desc,
    cycle_id
  );

create index if not exists selected_star_shift_decisions_record_idx
  on public.selected_star_shift_decisions (
    operator_id,
    location_id,
    restaurant_id,
    record_key,
    decided_at desc,
    decision_id
  );

create index if not exists selected_star_shift_decisions_cycle_idx
  on public.selected_star_shift_decisions (
    operator_id,
    location_id,
    target_cycle_id,
    decided_at desc
  )
  where target_cycle_id is not null;

create index if not exists selected_star_shift_decisions_updated_idx
  on public.selected_star_shift_decisions (
    operator_id,
    location_id,
    updated_at desc,
    decision_id
  );

create index if not exists active_target_profiles_updated_idx
  on public.active_target_profiles (
    operator_id,
    location_id,
    updated_at desc,
    target_profile_id
  );

create index if not exists active_target_profiles_cycle_idx
  on public.active_target_profiles (
    operator_id,
    location_id,
    target_cycle_id
  );

create index if not exists target_profile_versions_updated_idx
  on public.target_profile_versions (
    operator_id,
    location_id,
    updated_at desc,
    target_profile_version_id
  );

create index if not exists target_profile_versions_profile_idx
  on public.target_profile_versions (
    operator_id,
    location_id,
    target_profile_id,
    created_at desc
  );

create index if not exists star_target_audit_events_created_idx
  on public.star_target_audit_events (
    operator_id,
    location_id,
    created_at desc,
    audit_event_id
  );

create index if not exists star_target_audit_events_entity_idx
  on public.star_target_audit_events (
    operator_id,
    location_id,
    entity_table,
    entity_id,
    created_at desc
  );

alter table public.target_cycles enable row level security;
alter table public.selected_star_shift_decisions enable row level security;
alter table public.active_target_profiles enable row level security;
alter table public.target_profile_versions enable row level security;
alter table public.star_target_audit_events enable row level security;

drop policy if exists "target_cycles_per_tenant_location"
  on public.target_cycles;
create policy "target_cycles_per_tenant_location"
  on public.target_cycles for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "selected_star_shift_decisions_per_tenant_location"
  on public.selected_star_shift_decisions;
create policy "selected_star_shift_decisions_per_tenant_location"
  on public.selected_star_shift_decisions for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "active_target_profiles_per_tenant_location"
  on public.active_target_profiles;
create policy "active_target_profiles_per_tenant_location"
  on public.active_target_profiles for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "target_profile_versions_per_tenant_location"
  on public.target_profile_versions;
create policy "target_profile_versions_per_tenant_location"
  on public.target_profile_versions for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "star_target_audit_events_per_tenant_location"
  on public.star_target_audit_events;
create policy "star_target_audit_events_per_tenant_location"
  on public.star_target_audit_events for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.target_cycles from public;
revoke all on public.selected_star_shift_decisions from public;
revoke all on public.active_target_profiles from public;
revoke all on public.target_profile_versions from public;
revoke all on public.star_target_audit_events from public;

grant select, insert, update on public.target_cycles to service_role;
grant select, insert, update on public.target_cycles to forge_admin;

grant select, insert on public.selected_star_shift_decisions to service_role;
grant select, insert on public.selected_star_shift_decisions to forge_admin;

grant select, insert, update on public.active_target_profiles to service_role;
grant select, insert, update on public.active_target_profiles to forge_admin;

grant select, insert on public.target_profile_versions to service_role;
grant select, insert on public.target_profile_versions to forge_admin;

grant select, insert on public.star_target_audit_events to service_role;
grant select, insert on public.star_target_audit_events to forge_admin;

commit;
