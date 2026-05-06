-- Phase 8 timing provenance FK posture follow-up (V1.B).
--
-- Lane 0 (`202605061700_phase_8_timing_provenance_shift_records.sql`) added
-- the timing-profile foreign keys on closed `shift_records` and on live
-- `open_shift_snapshots` with the default `ON DELETE NO ACTION` action. That
-- conflicts with the `core_app_architecture.md` "What never rewrites"
-- non-negotiable: closed historical truth must outlive profile mutation.
-- Default `NO ACTION` would block any `business_timing_profiles` delete the
-- moment a single closed row references the profile, breaking the Operator
-- Web timing editor's expected lifecycle.
--
-- Decision (per `docs/POST_HARDENING_FOLLOWUPS.md` P1 Phase 8 carry-forward):
-- flip these three FKs to `ON DELETE SET NULL` so that profile deletion
-- degrades the closed/live row to a null timing triplet (legacy `daypart`
-- still drives display until a future re-aggregation). Validation is
-- deferred — the new constraints stay `NOT VALID`, mirroring Lane 0's
-- posture, until a maintenance-window `VALIDATE CONSTRAINT` follow-up.
--
-- Out of scope: the version-equals-profile CHECKs
-- (`shift_records_timing_version_profile_match_check`,
-- `open_shift_snapshots_timing_version_profile_match_check`) stay in place;
-- they get dropped in a separate Phase 8R follow-up before any divergent
-- `business_timing_profile_versions` writes (see POST_HARDENING_FOLLOWUPS).
--
-- Idempotent: each block drops the constraint by name only if present and
-- re-adds it only if absent.

begin;

do $$
begin
  if exists (
    select 1
      from pg_constraint
     where conname = 'shift_records_business_timing_profile_fk'
       and conrelid = 'public.shift_records'::regclass
  ) then
    alter table public.shift_records
      drop constraint shift_records_business_timing_profile_fk;
  end if;

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
      on delete set null
      not valid;
  end if;

  if exists (
    select 1
      from pg_constraint
     where conname = 'shift_records_business_timing_profile_version_fk'
       and conrelid = 'public.shift_records'::regclass
  ) then
    alter table public.shift_records
      drop constraint shift_records_business_timing_profile_version_fk;
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
      on delete set null
      not valid;
  end if;

  if exists (
    select 1
      from pg_constraint
     where conname = 'open_shift_snapshots_profile_version_fk'
       and conrelid = 'public.open_shift_snapshots'::regclass
  ) then
    alter table public.open_shift_snapshots
      drop constraint open_shift_snapshots_profile_version_fk;
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
      on delete set null
      not valid;
  end if;
end
$$;

commit;
