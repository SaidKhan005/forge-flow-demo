-- Phase 8 mobile core - first connection backfill jobs.
--
-- Authority:
--   * docs/contracts/mobile_core_first_connection_backfill_contract.md
--   * docs/_execution/2026-05-06_mobile_core_first_connection_backfill_sprint_plan.md
--   * docs/contracts/integration_spine_architecture_contract.md
--   * docs/contracts/phase_7_55_time_boundary_contract.md
--   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
--
-- Why this migration:
--
--   First connection already has adapter `backfill()` command/result seams,
--   but the production spine needs a durable, claimable work item before
--   connect routes, workers, projector wire-in, and mobile status can share
--   one source of truth. This table stores only server-side work state.
--   Mobile remains a cache and reads status through the proxy in a later
--   lane.

begin;

create table if not exists public.connector_backfill_jobs (
  job_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  connection_id uuid not null
    references public.connector_connection(connection_id)
    on delete cascade,
  vendor_id text not null
    check (
      char_length(vendor_id) between 1 and 64
      and vendor_id = btrim(vendor_id)
    ),
  category text not null
    check (category in ('pos', 'labor', 'reservation')),
  mode text not null default 'first_backfill'
    check (mode = 'first_backfill'),
  status text not null default 'pending'
    check (status in ('pending', 'running', 'succeeded', 'failed')),
  window_start timestamptz not null,
  window_end timestamptz not null,
  cursor_token text
    check (
      cursor_token is null
      or (
        char_length(cursor_token) between 1 and 2048
        and cursor_token = btrim(cursor_token)
      )
    ),
  last_modified_seen timestamptz,
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  worker_id text
    check (
      worker_id is null
      or (
        char_length(worker_id) between 1 and 128
        and worker_id = btrim(worker_id)
      )
    ),
  claimed_at timestamptz,
  completed_at timestamptz,
  last_error text
    check (last_error is null or char_length(last_error) <= 4096),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text,
  updated_by text,
  constraint connector_backfill_jobs_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint connector_backfill_jobs_window_chk
    check (
      window_end > window_start
      and window_end <= window_start + interval '60 days'
    )
);

comment on table public.connector_backfill_jobs is
  'Phase 8 mobile core - durable first-connection backfill work items. '
  'Connect routes enqueue, workers claim with SKIP LOCKED, and later '
  'lanes expose status through proxy/mobile cache paths.';

comment on column public.connector_backfill_jobs.mode is
  'V1 admits only first_backfill. Future explicit operator replays can '
  'add a separate bounded mode without changing this lane contract.';

-- One active job per connection/category/window. Succeeded and failed rows
-- are kept as history; a later explicit replay can enqueue a fresh active row.
create unique index if not exists connector_backfill_jobs_active_uq
  on public.connector_backfill_jobs (
    operator_id,
    connection_id,
    category,
    window_start,
    window_end
  )
  where status in ('pending', 'running');

-- Claim path: tenant leading, then pending/running status and oldest work.
create index if not exists connector_backfill_jobs_claim_idx
  on public.connector_backfill_jobs (
    operator_id,
    location_id,
    status,
    claimed_at,
    created_at
  );

-- Status lookup for connect/status lanes without scanning job history.
create index if not exists connector_backfill_jobs_connection_status_idx
  on public.connector_backfill_jobs (
    operator_id,
    connection_id,
    category,
    status,
    updated_at desc
  );

alter table public.connector_backfill_jobs enable row level security;

drop policy if exists "connector_backfill_jobs_per_tenant"
  on public.connector_backfill_jobs;
create policy "connector_backfill_jobs_per_tenant"
  on public.connector_backfill_jobs for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.connector_backfill_jobs from public;
grant select, insert, update
  on public.connector_backfill_jobs to service_role;
grant select, insert, update
  on public.connector_backfill_jobs to forge_admin;

commit;
