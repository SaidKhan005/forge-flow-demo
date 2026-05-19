-- Projection retry evidence hardening.
--
-- Why this exists
-- ---------------
-- The retry ledger now records both post-input projector failures and
-- pre-input failures where the projector input could not be built. Support
-- needs to see that failure point directly, and hard-deleting a location or
-- connector must not silently remove terminal retry evidence.
--
-- Operator approval gate
-- ----------------------
-- This is schema-touching. Per CLAUDE.md, it requires explicit operator
-- approval before merge regardless of audit verdict.

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

alter table public.canonical_fact_projection_retry_jobs
  add column if not exists failure_stage text not null default 'post_input';

alter table public.canonical_fact_projection_retry_jobs
  drop constraint if exists canonical_fact_projection_retry_jobs_failure_stage_chk;
alter table public.canonical_fact_projection_retry_jobs
  add constraint canonical_fact_projection_retry_jobs_failure_stage_chk
  check (failure_stage in ('post_input', 'pre_input')) not valid;
alter table public.canonical_fact_projection_retry_jobs
  validate constraint canonical_fact_projection_retry_jobs_failure_stage_chk;

alter table public.canonical_fact_projection_retry_jobs
  add column if not exists original_location_id uuid,
  add column if not exists original_connection_id uuid;

update public.canonical_fact_projection_retry_jobs
set
  original_location_id = coalesce(original_location_id, location_id),
  original_connection_id = coalesce(original_connection_id, connection_id)
where original_location_id is null
   or original_connection_id is null;

alter table public.canonical_fact_projection_retry_jobs
  alter column original_location_id set not null,
  alter column original_connection_id set not null,
  alter column location_id drop not null,
  alter column connection_id drop not null;

alter table public.canonical_fact_projection_retry_jobs
  drop constraint if exists canonical_fact_projection_retry_jobs_connection_id_fkey;
alter table public.canonical_fact_projection_retry_jobs
  drop constraint if exists canonical_fact_projection_retry_jobs_connection_fk;
alter table public.canonical_fact_projection_retry_jobs
  add constraint canonical_fact_projection_retry_jobs_connection_fk
  foreign key (connection_id)
  references public.connector_connection(connection_id)
  on delete set null;

alter table public.canonical_fact_projection_retry_jobs
  drop constraint if exists canonical_fact_projection_retry_jobs_operator_location_fk;
alter table public.canonical_fact_projection_retry_jobs
  add constraint canonical_fact_projection_retry_jobs_operator_location_fk
  foreign key (operator_id, location_id)
  references public.locations(operator_id, location_id)
  on delete set null (location_id);

comment on column public.canonical_fact_projection_retry_jobs.failure_stage is
  'Failure point for support triage: post_input means replayable projector '
  'input was built; pre_input means raw facts were preserved but no replay '
  'input exists.';

comment on column public.canonical_fact_projection_retry_jobs.original_location_id is
  'Immutable location id captured when the retry evidence row was created. '
  'Kept even when location_id is nulled by hard-delete cleanup.';

comment on column public.canonical_fact_projection_retry_jobs.original_connection_id is
  'Immutable connector connection id captured when the retry evidence row was '
  'created. Kept even when connection_id is nulled by hard-delete cleanup.';

create index if not exists canonical_fact_projection_retry_jobs_original_location_idx
  on public.canonical_fact_projection_retry_jobs
  (operator_id, original_location_id, status, updated_at desc);

create index if not exists canonical_fact_projection_retry_jobs_original_connection_idx
  on public.canonical_fact_projection_retry_jobs
  (operator_id, original_connection_id, created_at desc);

drop policy if exists "canonical_fact_projection_retry_jobs_per_tenant"
  on public.canonical_fact_projection_retry_jobs;
create policy "canonical_fact_projection_retry_jobs_per_tenant"
  on public.canonical_fact_projection_retry_jobs for all to service_role
  using (
    operator_id = public.app_current_operator()
    and coalesce(location_id, original_location_id)
      = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and coalesce(location_id, original_location_id)
      = public.app_current_location()
  );

commit;
