-- Phase 8 weekly plan server truth: snapshots and forecast context.
--
-- Additive Doc 1 Lane 0 server truth for weekly plan snapshots. Mobile
-- SQLite remains a cache mirror; Postgres owns the locked weekly plan and the
-- explainable forecast context that produced it.
--
-- RLS posture:
--   * every table is operator/location scoped.
--   * every hot-path B-tree index starts with operator_id.
--   * policies use wrapper functions, never bare current_setting().

begin;

create extension if not exists pgcrypto;

create table if not exists public.forecast_contexts (
  forecast_context_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  restaurant_id text not null
    check (length(trim(restaurant_id)) > 0),
  anchor_business_date date not null,

  baseline_total_covers integer not null
    check (baseline_total_covers >= 0),
  baseline_weekly_avg_covers integer not null
    check (baseline_weekly_avg_covers >= 0),
  baseline_weeks_represented numeric(12, 4) not null
    check (baseline_weeks_represented >= 0),
  recent_three_week_total_covers integer
    check (
      recent_three_week_total_covers is null
      or recent_three_week_total_covers >= 0
    ),
  recent_three_week_weekly_avg_covers integer
    check (
      recent_three_week_weekly_avg_covers is null
      or recent_three_week_weekly_avg_covers >= 0
    ),
  recent_trend_delta_covers integer,
  resolved_weekly_forecast_covers integer not null
    check (resolved_weekly_forecast_covers >= 0),

  target_ppa numeric(12, 4) not null
    check (target_ppa >= 0),
  forecast_sales numeric(14, 4) not null
    check (forecast_sales >= 0),
  required_foh_hours numeric(12, 4) not null
    check (required_foh_hours >= 0),
  required_boh_hours numeric(12, 4) not null
    check (required_boh_hours >= 0),
  theoretical_labor_dollars numeric(14, 4) not null
    check (theoretical_labor_dollars >= 0),

  covers_source text not null
    check (length(trim(covers_source)) > 0),
  sales_source text not null
    check (length(trim(sales_source)) > 0),
  target_cycle_id uuid,
  target_profile_id uuid,
  context_status text not null default 'open'
    check (context_status in ('open', 'closed')),
  built_at timestamptz not null,
  closed_at timestamptz,
  idempotency_key text not null
    check (length(trim(idempotency_key)) between 1 and 200),
  request_hash text not null
    check (length(trim(request_hash)) > 0),
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (operator_id, forecast_context_id),
  constraint forecast_contexts_anchor_uq
    unique (
      operator_id,
      location_id,
      restaurant_id,
      anchor_business_date
    ),
  constraint forecast_contexts_idempotency_uq
    unique (operator_id, location_id, idempotency_key),
  constraint forecast_contexts_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint forecast_contexts_target_cycle_fk
    foreign key (operator_id, target_cycle_id)
    references public.target_cycles(operator_id, cycle_id)
    on delete restrict,
  constraint forecast_contexts_target_profile_fk
    foreign key (operator_id, target_profile_id)
    references public.active_target_profiles(operator_id, target_profile_id)
    on delete restrict,
  constraint forecast_contexts_closed_status_check
    check (
      (context_status = 'closed' and closed_at is not null)
      or (context_status = 'open' and closed_at is null)
    )
);

comment on table public.forecast_contexts is
  'Server-owned explainable forecast context for weekly plan creation. '
  'Closed contexts are immutable; mobile demand context remains a cache/read '
  'model.';

comment on column public.forecast_contexts.anchor_business_date is
  'Business-date anchor used for the 60-day baseline and 21-day trend windows.';

comment on column public.forecast_contexts.theoretical_labor_dollars is
  'Total theoretical labor dollars implied by the forecast and active target '
  'profile.';

create table if not exists public.weekly_plan_snapshots (
  snapshot_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  restaurant_id text not null
    check (length(trim(restaurant_id)) > 0),
  week_start_date date not null,
  week_end_date date not null,
  week_key text not null
    check (length(trim(week_key)) > 0),
  target_cycle_id uuid not null,
  forecast_context_id uuid,

  forecast_covers integer not null
    check (forecast_covers >= 0),
  forecast_sales numeric(14, 4) not null
    check (forecast_sales >= 0),
  required_foh_hours numeric(12, 4) not null
    check (required_foh_hours >= 0),
  required_boh_hours numeric(12, 4) not null
    check (required_boh_hours >= 0),
  theoretical_foh_labor_dollars numeric(14, 4) not null
    check (theoretical_foh_labor_dollars >= 0),
  theoretical_boh_labor_dollars numeric(14, 4) not null
    check (theoretical_boh_labor_dollars >= 0),
  covers_source text not null
    check (length(trim(covers_source)) > 0),
  sales_source text not null
    check (length(trim(sales_source)) > 0),

  snapshot_status text not null default 'active'
    check (snapshot_status in ('active', 'superseded', 'unlocked')),
  source text not null
    check (source in (
      'server_lock',
      'server_replace',
      'admin_replacement',
      'system_bootstrap'
    )),
  generated_at timestamptz not null,
  locked_at timestamptz not null,
  superseded_at timestamptz,
  superseded_by_snapshot_id uuid,
  supersedes_snapshot_id uuid,
  unlocked_at timestamptz,
  unlocked_by_user_id uuid,
  replacement_reason text,
  idempotency_key text not null
    check (length(trim(idempotency_key)) between 1 and 200),
  request_hash text not null
    check (length(trim(request_hash)) > 0),
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (operator_id, snapshot_id),
  constraint weekly_plan_snapshots_week_span_check
    check (week_end_date > week_start_date),
  constraint weekly_plan_snapshots_status_metadata_check
    check (
      (
        snapshot_status = 'active'
        and superseded_at is null
        and unlocked_at is null
      )
      or (
        snapshot_status = 'superseded'
        and superseded_at is not null
      )
      or (
        snapshot_status = 'unlocked'
        and unlocked_at is not null
      )
    ),
  constraint weekly_plan_snapshots_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint weekly_plan_snapshots_target_cycle_fk
    foreign key (operator_id, target_cycle_id)
    references public.target_cycles(operator_id, cycle_id)
    on delete restrict,
  constraint weekly_plan_snapshots_forecast_context_fk
    foreign key (operator_id, forecast_context_id)
    references public.forecast_contexts(operator_id, forecast_context_id)
    on delete restrict,
  constraint weekly_plan_snapshots_supersedes_fk
    foreign key (operator_id, supersedes_snapshot_id)
    references public.weekly_plan_snapshots(operator_id, snapshot_id)
    on delete restrict,
  constraint weekly_plan_snapshots_superseded_by_fk
    foreign key (operator_id, superseded_by_snapshot_id)
    references public.weekly_plan_snapshots(operator_id, snapshot_id)
    on delete restrict,
  constraint weekly_plan_snapshots_idempotency_uq
    unique (operator_id, location_id, idempotency_key)
);

comment on table public.weekly_plan_snapshots is
  'Server-owned locked weekly plan truth. Prior active rows are superseded, '
  'not deleted, when a manager/admin replaces the week in force.';

comment on column public.weekly_plan_snapshots.target_cycle_id is
  'Target cycle that produced the weekly plan. RESTRICT FK forbids deleting '
  'target cycles while snapshots reference them.';

create table if not exists public.weekly_plan_snapshot_days (
  snapshot_day_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  snapshot_id uuid not null,
  restaurant_id text not null
    check (length(trim(restaurant_id)) > 0),
  day_index integer not null
    check (day_index between 0 and 6),
  day_label text not null
    check (length(trim(day_label)) > 0),
  business_date date not null,
  forecast_covers integer not null
    check (forecast_covers >= 0),
  forecast_sales numeric(14, 4) not null
    check (forecast_sales >= 0),
  required_foh_hours numeric(12, 4) not null
    check (required_foh_hours >= 0),
  required_boh_hours numeric(12, 4) not null
    check (required_boh_hours >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint weekly_plan_snapshot_days_snapshot_fk
    foreign key (operator_id, snapshot_id)
    references public.weekly_plan_snapshots(operator_id, snapshot_id)
    on delete cascade,
  constraint weekly_plan_snapshot_days_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint weekly_plan_snapshot_days_position_uq
    unique (operator_id, location_id, snapshot_id, day_index),
  constraint weekly_plan_snapshot_days_date_uq
    unique (operator_id, location_id, snapshot_id, business_date)
);

comment on table public.weekly_plan_snapshot_days is
  'Optional day-level breakdown for a locked weekly plan snapshot. The weekly '
  'row remains the sync root.';

create table if not exists public.weekly_plan_audit_events (
  audit_event_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  event_type text not null
    check (event_type in (
      'weekly_plan_locked',
      'weekly_plan_replaced',
      'weekly_plan_unlocked',
      'forecast_context_written'
    )),
  entity_table text not null
    check (entity_table in (
      'weekly_plan_snapshots',
      'forecast_contexts'
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

  constraint weekly_plan_audit_events_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint weekly_plan_audit_events_idempotency_uq
    unique (operator_id, location_id, event_type, idempotency_key)
);

comment on table public.weekly_plan_audit_events is
  'Append-only audit ledger for weekly plan lock, replace, unlock, and '
  'forecast context writes.';

create or replace function public.forecast_contexts_prevent_closed_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' and old.closed_at is not null then
    raise exception 'closed forecast_contexts rows are immutable';
  end if;

  if tg_op = 'UPDATE' and old.closed_at is not null then
    raise exception 'closed forecast_contexts rows are immutable';
  end if;

  return new;
end;
$$;

drop trigger if exists forecast_contexts_prevent_closed_mutation
  on public.forecast_contexts;
create trigger forecast_contexts_prevent_closed_mutation
before update or delete on public.forecast_contexts
for each row execute function public.forecast_contexts_prevent_closed_mutation();

drop trigger if exists forecast_contexts_set_updated_at
  on public.forecast_contexts;
create trigger forecast_contexts_set_updated_at
before update on public.forecast_contexts
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists weekly_plan_snapshots_set_updated_at
  on public.weekly_plan_snapshots;
create trigger weekly_plan_snapshots_set_updated_at
before update on public.weekly_plan_snapshots
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists weekly_plan_snapshot_days_set_updated_at
  on public.weekly_plan_snapshot_days;
create trigger weekly_plan_snapshot_days_set_updated_at
before update on public.weekly_plan_snapshot_days
for each row execute function public.cloud_foundation_set_updated_at();

-- Operator-leading indexes. B-tree indexes must lead with operator_id so RLS
-- predicates fold into index probes.
create index if not exists forecast_contexts_anchor_idx
  on public.forecast_contexts (
    operator_id,
    location_id,
    restaurant_id,
    anchor_business_date desc
  );

create index if not exists forecast_contexts_updated_idx
  on public.forecast_contexts (
    operator_id,
    location_id,
    updated_at desc,
    forecast_context_id
  );

create index if not exists forecast_contexts_target_cycle_idx
  on public.forecast_contexts (
    operator_id,
    location_id,
    target_cycle_id
  )
  where target_cycle_id is not null;

create unique index if not exists weekly_plan_snapshots_active_week_uq
  on public.weekly_plan_snapshots (
    operator_id,
    location_id,
    restaurant_id,
    week_start_date
  )
  where snapshot_status = 'active';

create index if not exists weekly_plan_snapshots_week_idx
  on public.weekly_plan_snapshots (
    operator_id,
    location_id,
    restaurant_id,
    week_start_date desc,
    snapshot_id
  );

create index if not exists weekly_plan_snapshots_updated_idx
  on public.weekly_plan_snapshots (
    operator_id,
    location_id,
    updated_at desc,
    snapshot_id
  );

create index if not exists weekly_plan_snapshots_target_cycle_idx
  on public.weekly_plan_snapshots (
    operator_id,
    location_id,
    target_cycle_id
  );

create index if not exists weekly_plan_snapshot_days_snapshot_idx
  on public.weekly_plan_snapshot_days (
    operator_id,
    location_id,
    snapshot_id,
    day_index
  );

create index if not exists weekly_plan_snapshot_days_business_date_idx
  on public.weekly_plan_snapshot_days (
    operator_id,
    location_id,
    restaurant_id,
    business_date
  );

create index if not exists weekly_plan_audit_events_created_idx
  on public.weekly_plan_audit_events (
    operator_id,
    location_id,
    created_at desc,
    audit_event_id
  );

create index if not exists weekly_plan_audit_events_entity_idx
  on public.weekly_plan_audit_events (
    operator_id,
    location_id,
    entity_table,
    entity_id,
    created_at desc
  );

alter table public.forecast_contexts enable row level security;
alter table public.weekly_plan_snapshots enable row level security;
alter table public.weekly_plan_snapshot_days enable row level security;
alter table public.weekly_plan_audit_events enable row level security;

drop policy if exists "forecast_contexts_per_tenant_location"
  on public.forecast_contexts;
create policy "forecast_contexts_per_tenant_location"
  on public.forecast_contexts for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "weekly_plan_snapshots_per_tenant_location"
  on public.weekly_plan_snapshots;
create policy "weekly_plan_snapshots_per_tenant_location"
  on public.weekly_plan_snapshots for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "weekly_plan_snapshot_days_per_tenant_location"
  on public.weekly_plan_snapshot_days;
create policy "weekly_plan_snapshot_days_per_tenant_location"
  on public.weekly_plan_snapshot_days for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "weekly_plan_audit_events_per_tenant_location"
  on public.weekly_plan_audit_events;
create policy "weekly_plan_audit_events_per_tenant_location"
  on public.weekly_plan_audit_events for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.forecast_contexts from public;
revoke all on public.weekly_plan_snapshots from public;
revoke all on public.weekly_plan_snapshot_days from public;
revoke all on public.weekly_plan_audit_events from public;

grant select, insert, update on public.forecast_contexts to service_role;
grant select, insert, update on public.forecast_contexts to forge_admin;

grant select, insert, update on public.weekly_plan_snapshots to service_role;
grant select, insert, update on public.weekly_plan_snapshots to forge_admin;

grant select, insert on public.weekly_plan_snapshot_days to service_role;
grant select, insert on public.weekly_plan_snapshot_days to forge_admin;

grant select, insert on public.weekly_plan_audit_events to service_role;
grant select, insert on public.weekly_plan_audit_events to forge_admin;

commit;
