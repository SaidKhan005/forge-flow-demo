-- Phase 9.UX.1a - public MFA recovery-request abuse ledger.
--
-- This table backs the public "contact restaurant admin" recovery endpoint
-- with a durable per-email cooldown and per-IP rolling window. Values are
-- SHA-256 hashes so the limiter does not store raw email addresses or IPs.

create table if not exists public.mfa_recovery_request_attempts (
  attempt_id bigserial primary key,
  email_hash text not null,
  ip_hash text not null,
  attempted_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists mfa_recovery_request_attempts_email_idx
  on public.mfa_recovery_request_attempts (email_hash, attempted_at desc);

create index if not exists mfa_recovery_request_attempts_ip_idx
  on public.mfa_recovery_request_attempts (ip_hash, attempted_at desc);

alter table public.mfa_recovery_request_attempts enable row level security;

drop policy if exists "mfa_recovery_request_attempts_system"
  on public.mfa_recovery_request_attempts;

create policy "mfa_recovery_request_attempts_system"
  on public.mfa_recovery_request_attempts for all to service_role
  using (true)
  with check (true);

grant select, insert, delete on public.mfa_recovery_request_attempts
  to service_role, forge_admin;
grant usage, select on sequence public.mfa_recovery_request_attempts_attempt_id_seq
  to service_role, forge_admin;

comment on table public.mfa_recovery_request_attempts is
  'Durable hashed attempt ledger for public MFA recovery request cooldown and per-IP rolling-window limits.';
