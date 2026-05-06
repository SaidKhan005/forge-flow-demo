-- Business Timing Live - canonical timing profiles + open shift snapshots.
--
-- This slice creates the server-side source of truth for business timing:
--
--   * business_timing_profiles: scoped, effective-dated profile rows.
--   * business_timing_service_periods: optional whole-set service-period
--     overrides for a profile.
--   * business_timing_audit_events: append-only audit ledger for timing writes.
--   * open_shift_snapshots: provisional live/projected Shift read model rows.
--
-- RLS posture:
--   * timing profiles, service periods, and audit rows are operator-scoped.
--     Location resolution must read inherited operator and org-unit profiles.
--   * open_shift_snapshots is an operator+location fact table.
--   * all policies use 9.0Sigma.b wrapper functions, never bare
--     current_setting().
--
-- Time posture:
--   * locations.timezone remains the authoritative IANA timezone.
--   * timing profiles carry local business-day start and week-start rules only.
--   * operator-scoped fact timestamps are timestamptz; local clock settings are
--     stored as time-of-day values, not timezone-naive timestamps.

begin;

create extension if not exists pgcrypto;

create or replace function public.business_timing_time_is_quarter_hour(
  value time
)
returns boolean
language sql
immutable
strict
as $$
  select extract(second from value) = 0
     and extract(minute from value)::int in (0, 15, 30, 45);
$$;

create or replace function public.business_timing_time_to_minute(
  value time
)
returns integer
language sql
immutable
strict
as $$
  select (extract(hour from value)::int * 60)
       + extract(minute from value)::int;
$$;

create or replace function public.business_timing_period_contains(
  target_minute integer,
  start_minute integer,
  end_minute integer,
  rolls_past_midnight boolean
)
returns boolean
language sql
immutable
strict
as $$
  select case
    when rolls_past_midnight then
      target_minute >= start_minute or target_minute < end_minute
    else
      target_minute >= start_minute and target_minute < end_minute
    end;
$$;

create or replace function public.business_timing_periods_overlap(
  left_start_minute integer,
  left_end_minute integer,
  left_rolls_past_midnight boolean,
  right_start_minute integer,
  right_end_minute integer,
  right_rolls_past_midnight boolean
)
returns boolean
language sql
immutable
strict
as $$
  select public.business_timing_period_contains(
           right_start_minute,
           left_start_minute,
           left_end_minute,
           left_rolls_past_midnight
         )
      or public.business_timing_period_contains(
           left_start_minute,
           right_start_minute,
           right_end_minute,
           right_rolls_past_midnight
         );
$$;

create table if not exists public.business_timing_profiles (
  profile_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,

  -- The profile scope is explicit for resolver ordering. scope_id points to:
  --   operator  -> operators.operator_id and must equal operator_id
  --   org_unit  -> org_units.id for this operator
  --   location  -> locations.location_id for this operator
  scope_type text not null
    check (scope_type in ('operator', 'org_unit', 'location')),
  scope_id uuid not null,

  display_name text,
  business_day_start_local_time time not null
    check (public.business_timing_time_is_quarter_hour(
      business_day_start_local_time
    )),
  week_start_day integer not null
    check (week_start_day between 1 and 7),
  close_authority text not null
    check (close_authority in (
      'vendor_finalization',
      'app_local_cutoff_fallback'
    )),
  local_close_fallback_time time
    check (
      local_close_fallback_time is null
      or public.business_timing_time_is_quarter_hour(
        local_close_fallback_time
      )
    ),

  effective_from_business_date date not null,
  effective_until_business_date date,
  supersedes_profile_id uuid
    references public.business_timing_profiles(profile_id)
    on delete set null,

  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (operator_id, profile_id),
  constraint business_timing_profiles_effective_window_check
    check (
      effective_until_business_date is null
      or effective_until_business_date > effective_from_business_date
    ),
  constraint business_timing_profiles_local_close_required_check
    check (
      close_authority <> 'app_local_cutoff_fallback'
      or local_close_fallback_time is not null
    )
);

comment on table public.business_timing_profiles is
  'Canonical scoped/effective business timing profiles. Inheritance order is '
  'operator -> org-unit ancestors -> location. locations.timezone remains '
  'the authoritative IANA timezone; this table stores local timing rules only.';

comment on column public.business_timing_profiles.scope_type is
  'operator | org_unit | location. The scope validation trigger verifies '
  'scope_id belongs to operator_id.';

comment on column public.business_timing_profiles.business_day_start_local_time is
  'Local time-of-day when the business day starts. Quarter-hour increments.';

create table if not exists public.business_timing_service_periods (
  service_period_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  profile_id uuid not null,
  service_period_key text not null
    check (service_period_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  label text not null
    check (length(trim(label)) > 0),
  short_label text not null default ''
    check (length(short_label) <= 8),
  sort_order integer not null
    check (sort_order between 1 and 4),
  start_local_time time not null
    check (public.business_timing_time_is_quarter_hour(start_local_time)),
  end_local_time time not null
    check (public.business_timing_time_is_quarter_hour(end_local_time)),
  rolls_past_midnight boolean not null default false,
  applicable_weekdays integer[] not null
    check (
      cardinality(applicable_weekdays) between 1 and 7
      and applicable_weekdays <@ array[1, 2, 3, 4, 5, 6, 7]
    ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint business_timing_service_periods_profile_fk
    foreign key (operator_id, profile_id)
    references public.business_timing_profiles(operator_id, profile_id)
    on delete cascade,
  constraint business_timing_service_periods_clock_window_check
    check (start_local_time <> end_local_time),
  constraint business_timing_service_periods_key_uq
    unique (operator_id, profile_id, service_period_key),
  constraint business_timing_service_periods_sort_uq
    unique (operator_id, profile_id, sort_order)
);

comment on table public.business_timing_service_periods is
  'Optional whole-set service-period override for one timing profile. A '
  'profile with no rows inherits periods from the next higher resolved scope.';

create table if not exists public.business_timing_audit_events (
  audit_event_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  profile_id uuid
    references public.business_timing_profiles(profile_id)
    on delete set null,
  scope_type text not null
    check (scope_type in ('operator', 'org_unit', 'location')),
  scope_id uuid not null,
  event_type text not null
    check (event_type in (
      'profile_created',
      'profile_updated',
      'profile_closed',
      'service_periods_replaced'
    )),
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
  created_at timestamptz not null default now()
);

comment on table public.business_timing_audit_events is
  'Append-only audit events for business timing profile and service-period '
  'mutations. Rows are operator-scoped and visible through tenant RLS.';

create table if not exists public.open_shift_snapshots (
  snapshot_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  business_timing_profile_id uuid not null,

  business_date date not null,
  week_start_date date not null,
  week_id text not null,
  day_label text not null
    check (length(trim(day_label)) > 0),

  snapshot_scope text not null
    check (snapshot_scope in ('whole_day', 'service_period')),
  service_period_key text not null,
  service_period_label text not null
    check (length(trim(service_period_label)) > 0),

  status text not null default 'projected'
    check (status in ('open', 'projected')),

  forecast_covers integer not null default 0
    check (forecast_covers >= 0),
  current_covers integer not null default 0
    check (current_covers >= 0),
  scheduled_foh_hours integer not null default 0
    check (scheduled_foh_hours >= 0),
  scheduled_boh_hours integer not null default 0
    check (scheduled_boh_hours >= 0),
  current_ppa numeric(12, 4) not null default 0
    check (current_ppa >= 0),
  current_cplh numeric(12, 4) not null default 0
    check (current_cplh >= 0),
  current_splh numeric(12, 4) not null default 0
    check (current_splh >= 0),
  blended_wage numeric(12, 4) not null default 0
    check (blended_wage >= 0),

  time_label text not null default '',
  service_elapsed_label text not null default '',
  source_system text,
  source_shift_id text,
  provenance jsonb not null default '{}'::jsonb
    check (jsonb_typeof(provenance) = 'object'),
  last_event_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint open_shift_snapshots_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint open_shift_snapshots_profile_fk
    foreign key (operator_id, business_timing_profile_id)
    references public.business_timing_profiles(operator_id, profile_id),
  constraint open_shift_snapshots_scope_key_check
    check (
      (snapshot_scope = 'whole_day' and service_period_key = 'whole_day')
      or (
        snapshot_scope = 'service_period'
        and service_period_key ~ '^[a-z][a-z0-9_]{0,63}$'
      )
    ),
  constraint open_shift_snapshots_location_business_day_scope_uq
    unique (
      operator_id,
      location_id,
      business_date,
      snapshot_scope,
      service_period_key
    )
);

comment on table public.open_shift_snapshots is
  'Server-side provisional live/projected Shift read model. One row per '
  'business date whole-day rollup plus one row per service period. Rows lock '
  'the business_timing_profile_id that opened the live business day.';

create or replace function public.business_timing_validate_scope()
returns trigger
language plpgsql
as $$
begin
  if new.scope_type = 'operator' then
    if new.scope_id <> new.operator_id then
      raise exception
        'operator-scoped business timing profile scope_id must equal operator_id'
        using errcode = '23514';
    end if;
  elsif new.scope_type = 'org_unit' then
    if not exists (
      select 1
        from public.org_units ou
       where ou.operator_id = new.operator_id
         and ou.id = new.scope_id
    ) then
      raise exception
        'business timing profile org_unit scope_id % does not belong to operator_id %',
        new.scope_id, new.operator_id
        using errcode = '23503';
    end if;
  elsif new.scope_type = 'location' then
    if not exists (
      select 1
        from public.locations loc
       where loc.operator_id = new.operator_id
         and loc.location_id = new.scope_id
    ) then
      raise exception
        'business timing profile location scope_id % does not belong to operator_id %',
        new.scope_id, new.operator_id
        using errcode = '23503';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.business_timing_prevent_effective_overlap()
returns trigger
language plpgsql
as $$
declare
  proposed_range daterange;
begin
  proposed_range := daterange(
    new.effective_from_business_date,
    coalesce(new.effective_until_business_date, 'infinity'::date),
    '[)'
  );

  if exists (
    select 1
      from public.business_timing_profiles existing
     where existing.operator_id = new.operator_id
       and existing.scope_type = new.scope_type
       and existing.scope_id = new.scope_id
       and existing.profile_id <> new.profile_id
       and daterange(
             existing.effective_from_business_date,
             coalesce(existing.effective_until_business_date, 'infinity'::date),
             '[)'
           ) && proposed_range
  ) then
    raise exception
      'overlapping business timing effective window for operator_id %, scope_type %, scope_id %',
      new.operator_id, new.scope_type, new.scope_id
      using errcode = '23P01';
  end if;

  return new;
end;
$$;

create or replace function public.business_timing_validate_service_periods()
returns trigger
language plpgsql
as $$
declare
  target_profile_id uuid;
  profile_start_minute integer;
  period_count integer;
  rolling_count integer;
  left_period record;
  right_period record;
begin
  if tg_op = 'DELETE' then
    target_profile_id := old.profile_id;
  else
    target_profile_id := new.profile_id;
  end if;

  select public.business_timing_time_to_minute(
           profile.business_day_start_local_time
         )
    into profile_start_minute
    from public.business_timing_profiles profile
   where profile.profile_id = target_profile_id;

  if profile_start_minute is null then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  select count(*)
    into period_count
    from public.business_timing_service_periods
   where profile_id = target_profile_id;

  if period_count > 4 then
    raise exception
      'business timing profile % has more than four service periods',
      target_profile_id
      using errcode = '23514';
  end if;

  select count(*)
    into rolling_count
    from public.business_timing_service_periods
   where profile_id = target_profile_id
     and rolls_past_midnight;

  if rolling_count > 1 then
    raise exception
      'business timing profile % has more than one rolling service period',
      target_profile_id
      using errcode = '23514';
  end if;

  for left_period in
    select
      service_period_id,
      service_period_key,
      public.business_timing_time_to_minute(start_local_time) as start_minute,
      public.business_timing_time_to_minute(end_local_time) as end_minute,
      rolls_past_midnight,
      applicable_weekdays
    from public.business_timing_service_periods
    where profile_id = target_profile_id
  loop
    if public.business_timing_period_contains(
      profile_start_minute,
      left_period.start_minute,
      left_period.end_minute,
      left_period.rolls_past_midnight
    ) then
      raise exception
        'business-day start falls inside service period %',
        left_period.service_period_key
        using errcode = '23514';
    end if;

    for right_period in
      select
        service_period_id,
        service_period_key,
        public.business_timing_time_to_minute(start_local_time) as start_minute,
        public.business_timing_time_to_minute(end_local_time) as end_minute,
        rolls_past_midnight,
        applicable_weekdays
      from public.business_timing_service_periods
      where profile_id = target_profile_id
        and service_period_id > left_period.service_period_id
    loop
      if left_period.applicable_weekdays && right_period.applicable_weekdays
         and public.business_timing_periods_overlap(
           left_period.start_minute,
           left_period.end_minute,
           left_period.rolls_past_midnight,
           right_period.start_minute,
           right_period.end_minute,
           right_period.rolls_past_midnight
         ) then
        raise exception
          'service periods % and % overlap on at least one weekday',
          left_period.service_period_key,
          right_period.service_period_key
          using errcode = '23514';
      end if;
    end loop;
  end loop;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists business_timing_profiles_validate_scope
  on public.business_timing_profiles;
create trigger business_timing_profiles_validate_scope
before insert or update of operator_id, scope_type, scope_id
on public.business_timing_profiles
for each row execute function public.business_timing_validate_scope();

drop trigger if exists business_timing_profiles_prevent_effective_overlap
  on public.business_timing_profiles;
create trigger business_timing_profiles_prevent_effective_overlap
before insert or update of operator_id, scope_type, scope_id,
  effective_from_business_date, effective_until_business_date
on public.business_timing_profiles
for each row execute function public.business_timing_prevent_effective_overlap();

drop trigger if exists business_timing_profiles_set_updated_at
  on public.business_timing_profiles;
create trigger business_timing_profiles_set_updated_at
before update on public.business_timing_profiles
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists business_timing_profiles_validate_periods
  on public.business_timing_profiles;
create trigger business_timing_profiles_validate_periods
after update of business_day_start_local_time
on public.business_timing_profiles
for each row execute function public.business_timing_validate_service_periods();

drop trigger if exists business_timing_service_periods_validate
  on public.business_timing_service_periods;
create trigger business_timing_service_periods_validate
after insert or update or delete on public.business_timing_service_periods
for each row execute function public.business_timing_validate_service_periods();

drop trigger if exists business_timing_service_periods_set_updated_at
  on public.business_timing_service_periods;
create trigger business_timing_service_periods_set_updated_at
before update on public.business_timing_service_periods
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists open_shift_snapshots_set_updated_at
  on public.open_shift_snapshots;
create trigger open_shift_snapshots_set_updated_at
before update on public.open_shift_snapshots
for each row execute function public.cloud_foundation_set_updated_at();

-- Operator-leading indexes. B-tree indexes must lead with operator_id so RLS
-- predicates fold into index probes.
create unique index if not exists business_timing_profiles_scope_from_uq
  on public.business_timing_profiles (
    operator_id,
    scope_type,
    scope_id,
    effective_from_business_date
  );

create index if not exists business_timing_profiles_scope_effective_idx
  on public.business_timing_profiles (
    operator_id,
    scope_type,
    scope_id,
    effective_from_business_date desc,
    effective_until_business_date
  );

create index if not exists business_timing_profiles_updated_idx
  on public.business_timing_profiles (operator_id, updated_at desc);

create index if not exists business_timing_service_periods_profile_idx
  on public.business_timing_service_periods (
    operator_id,
    profile_id,
    sort_order
  );

create index if not exists business_timing_audit_events_created_idx
  on public.business_timing_audit_events (
    operator_id,
    created_at desc,
    audit_event_id
  );

create index if not exists business_timing_audit_events_profile_idx
  on public.business_timing_audit_events (
    operator_id,
    profile_id,
    created_at desc
  )
  where profile_id is not null;

create index if not exists open_shift_snapshots_business_date_idx
  on public.open_shift_snapshots (
    operator_id,
    location_id,
    business_date desc,
    snapshot_scope,
    service_period_key
  );

create index if not exists open_shift_snapshots_status_idx
  on public.open_shift_snapshots (
    operator_id,
    location_id,
    status,
    updated_at desc
  );

create index if not exists open_shift_snapshots_updated_idx
  on public.open_shift_snapshots (
    operator_id,
    location_id,
    updated_at desc,
    snapshot_id
  );

-- RLS policies.
alter table public.business_timing_profiles enable row level security;
alter table public.business_timing_service_periods enable row level security;
alter table public.business_timing_audit_events enable row level security;
alter table public.open_shift_snapshots enable row level security;

drop policy if exists "business_timing_profiles_per_tenant"
  on public.business_timing_profiles;
create policy "business_timing_profiles_per_tenant"
  on public.business_timing_profiles for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

drop policy if exists "business_timing_service_periods_per_tenant"
  on public.business_timing_service_periods;
create policy "business_timing_service_periods_per_tenant"
  on public.business_timing_service_periods for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

drop policy if exists "business_timing_audit_events_per_tenant"
  on public.business_timing_audit_events;
create policy "business_timing_audit_events_per_tenant"
  on public.business_timing_audit_events for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

drop policy if exists "open_shift_snapshots_per_tenant_location"
  on public.open_shift_snapshots;
create policy "open_shift_snapshots_per_tenant_location"
  on public.open_shift_snapshots for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.business_timing_profiles from public;
revoke all on public.business_timing_service_periods from public;
revoke all on public.business_timing_audit_events from public;
revoke all on public.open_shift_snapshots from public;

grant select, insert, update on public.business_timing_profiles to service_role;
grant select, insert, update on public.business_timing_profiles to forge_admin;

grant select, insert, update, delete
  on public.business_timing_service_periods to service_role;
grant select, insert, update, delete
  on public.business_timing_service_periods to forge_admin;

grant select, insert on public.business_timing_audit_events to service_role;
grant select, insert on public.business_timing_audit_events to forge_admin;

grant select, insert, update, delete on public.open_shift_snapshots
  to service_role;
grant select, insert, update, delete on public.open_shift_snapshots
  to forge_admin;

commit;
