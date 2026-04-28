-- Phase 9 live-closeout B13 - recovery-code attempt ledger.
--
-- Recovery-code attempts are rate-limited at 1/minute and 5/24h per user.
-- The proxy records every attempt, valid or invalid, so attackers cannot
-- distinguish wrong codes from already-used codes and cannot bypass rate
-- limits by sending malformed input.

create table if not exists public.recovery_code_attempts (
  attempt_id bigserial primary key,
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  attempted_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists recovery_code_attempts_user_attempted_idx
  on public.recovery_code_attempts (user_id, attempted_at desc);

alter table public.recovery_code_attempts enable row level security;

drop policy if exists "recovery_code_attempts_per_user"
  on public.recovery_code_attempts;

create policy "recovery_code_attempts_per_user"
  on public.recovery_code_attempts for all to service_role
  using (user_id = public.app_current_actor_user())
  with check (user_id = public.app_current_actor_user());

grant select, insert, delete on public.recovery_code_attempts
  to service_role, forge_admin;
grant usage, select on sequence public.recovery_code_attempts_attempt_id_seq
  to service_role, forge_admin;

comment on table public.recovery_code_attempts is
  'Per-user recovery-code attempt ledger. Every attempt is recorded so the proxy can enforce 1/minute and 5/24h recovery-code limits.';
