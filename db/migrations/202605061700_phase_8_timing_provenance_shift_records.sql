-- Phase 8 live + closed truth Lane 0: timing provenance foundation.
--
-- Decision: current business timing uses immutable
-- business_timing_profiles.profile_id as both the profile id and current
-- version id. A future migration may introduce a dedicated versions table,
-- but this lane must not query a table that does not exist on master.
--
-- This migration is additive:
--   * nullable closed shift_records columns preserve legacy rows as NULL.
--   * nullable open_shift_snapshots version column backfills from profile_id.
--   * no historical closed rows are rewritten or re-bucketed.
--   * indexes lead with operator_id and use CONCURRENTLY for live tables.

alter table public.shift_records
  add column if not exists business_timing_profile_id uuid,
  add column if not exists business_timing_profile_version_id uuid,
  add column if not exists service_period_key text;

comment on column public.shift_records.business_timing_profile_id is
  'Business timing profile_id used when this closed row was bucketed. Legacy rows remain NULL.';

comment on column public.shift_records.business_timing_profile_version_id is
  'Stable timing version id for downstream lanes. For V1 this equals business_timing_profiles.profile_id.';

comment on column public.shift_records.service_period_key is
  'Stable service-period key used when this closed row was bucketed. Legacy daypart remains for compatibility.';

alter table public.open_shift_snapshots
  add column if not exists business_timing_profile_version_id uuid;

comment on column public.open_shift_snapshots.business_timing_profile_version_id is
  'Stable timing version id for live snapshots. For V1 this equals business_timing_profiles.profile_id.';

update public.open_shift_snapshots
   set business_timing_profile_version_id = business_timing_profile_id
 where business_timing_profile_version_id is null;

do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'shift_records_business_timing_profile_fk'
       and conrelid = 'public.shift_records'::regclass
  ) then
    alter table public.shift_records
      add constraint shift_records_business_timing_profile_fk
      foreign key (operator_id, business_timing_profile_id)
      references public.business_timing_profiles(operator_id, profile_id)
      not valid;
  end if;

  if not exists (
    select 1
      from pg_constraint
     where conname = 'shift_records_timing_version_profile_match_check'
       and conrelid = 'public.shift_records'::regclass
  ) then
    alter table public.shift_records
      add constraint shift_records_timing_version_profile_match_check
      check (
        business_timing_profile_version_id
          is not distinct from business_timing_profile_id
      )
      not valid;
  end if;

  if not exists (
    select 1
      from pg_constraint
     where conname = 'shift_records_business_timing_profile_version_fk'
       and conrelid = 'public.shift_records'::regclass
  ) then
    alter table public.shift_records
      add constraint shift_records_business_timing_profile_version_fk
      foreign key (operator_id, business_timing_profile_version_id)
      references public.business_timing_profiles(operator_id, profile_id)
      not valid;
  end if;

  if not exists (
    select 1
      from pg_constraint
     where conname = 'shift_records_service_period_key_format_check'
       and conrelid = 'public.shift_records'::regclass
  ) then
    alter table public.shift_records
      add constraint shift_records_service_period_key_format_check
      check (
        service_period_key is null
        or service_period_key ~ '^[a-z][a-z0-9_]{0,63}$'
      )
      not valid;
  end if;

  if not exists (
    select 1
      from pg_constraint
     where conname = 'open_shift_snapshots_profile_version_fk'
       and conrelid = 'public.open_shift_snapshots'::regclass
  ) then
    alter table public.open_shift_snapshots
      add constraint open_shift_snapshots_profile_version_fk
      foreign key (operator_id, business_timing_profile_version_id)
      references public.business_timing_profiles(operator_id, profile_id)
      not valid;
  end if;

  if not exists (
    select 1
      from pg_constraint
     where conname = 'open_shift_snapshots_timing_version_profile_match_check'
       and conrelid = 'public.open_shift_snapshots'::regclass
  ) then
    alter table public.open_shift_snapshots
      add constraint open_shift_snapshots_timing_version_profile_match_check
      check (
        business_timing_profile_version_id
          is not distinct from business_timing_profile_id
      )
      not valid;
  end if;
end
$$;

create index concurrently if not exists shift_records_timing_profile_idx
  on public.shift_records (
    operator_id,
    location_id,
    business_timing_profile_id,
    business_timing_profile_version_id
  )
  where business_timing_profile_id is not null;

create index concurrently if not exists shift_records_service_period_idx
  on public.shift_records (
    operator_id,
    location_id,
    business_date desc,
    service_period_key
  )
  where service_period_key is not null;

create index concurrently if not exists open_shift_snapshots_profile_version_idx
  on public.open_shift_snapshots (
    operator_id,
    location_id,
    business_timing_profile_version_id,
    updated_at desc
  )
  where business_timing_profile_version_id is not null;
