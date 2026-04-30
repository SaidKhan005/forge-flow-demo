-- Phase 9.UX.1 - delayed MFA factor removal requests.
--
-- Removing MFA is delayed for 24 hours. This table is the durable request
-- ledger between the user/admin action and the server-side completion pass.

create table if not exists public.mfa_factor_removal_requests (
  request_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  location_id uuid not null,
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  factor_id uuid not null references public.mfa_factors(factor_id)
    on delete cascade,
  requested_by_user_id uuid not null references public.users(user_id)
    on delete restrict,
  step_up_proof_id text not null,
  requested_at timestamptz not null default now(),
  execute_after timestamptz not null,
  completed_at timestamptz null,
  cancelled_at timestamptz null,
  processing_started_at timestamptz null,
  processing_owner text null,
  last_error text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  check (execute_after >= requested_at)
);

create unique index if not exists mfa_factor_removal_active_idx
  on public.mfa_factor_removal_requests (operator_id, user_id, factor_id)
  where completed_at is null and cancelled_at is null;

create index if not exists mfa_factor_removal_due_idx
  on public.mfa_factor_removal_requests (
    execute_after,
    request_id
  )
  where completed_at is null and cancelled_at is null;

create index if not exists mfa_factor_removal_processing_idx
  on public.mfa_factor_removal_requests (
    processing_started_at,
    request_id
  )
  where completed_at is null and cancelled_at is null;

create index if not exists mfa_factor_removal_recent_idx
  on public.mfa_factor_removal_requests (
    operator_id,
    location_id,
    user_id,
    requested_at desc
  );

alter table public.mfa_factor_removal_requests enable row level security;

drop policy if exists "mfa_factor_removal_requests_per_user"
  on public.mfa_factor_removal_requests;

create policy "mfa_factor_removal_requests_per_user"
  on public.mfa_factor_removal_requests for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
    and user_id = public.app_current_actor_user()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
    and user_id = public.app_current_actor_user()
  );

grant select, insert, update, delete on public.mfa_factor_removal_requests
  to service_role, forge_admin;

comment on table public.mfa_factor_removal_requests is
  'Durable 24-hour MFA factor removal request ledger. Completion clears server-side MFA, revokes the local factor, audits completion, and queues notification fan-out.';
