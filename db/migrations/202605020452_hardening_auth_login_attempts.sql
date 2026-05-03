-- HARD-B - public.auth_login_attempts table for the auth lockout
-- ledger. Authority: docs/contracts/hardening_auth_protection_contract.md
-- "Lockout Schema".
--
-- Records every credential attempt against the proxy login surface so
-- the lockout enforcer can count failures in the rolling 15-minute
-- window per (user_email_hash, ip_hash) and trip the 5-failure /
-- 423-Locked threshold without leaking which arm of the window the
-- failure landed in. The table also carries the per-tenant rows the
-- post-resolution success/failure path writes once the email maps to
-- a known operator.
--
-- Hard rules (CLAUDE.md + 9.0Sigma.b RLS wrappers):
--
--   1. **Tz-naive timestamp columns are banned.** Every timestamp
--      column is `timestamptz`. The partition driver (pg_partman) is
--      registered on a derived `attempted_date date` so daily
--      partition pruning works without a `timestamp` column.
--
--   2. **RLS performance discipline (CLAUDE.md).** Every B-tree index
--      that carries `operator_id` leads with it; the anonymous-lookup
--      index leads with `(user_email_hash, attempted_at desc)` so the
--      pre-tenant lookup the proxy runs (no scope resolved yet) hits
--      the same probe shape. RLS policies call the 9.0Sigma.b wrapper
--      functions; bare `current_setting()` is forbidden.
--
--   3. **Append-only by grant shape.** service_role and forge_admin
--      get INSERT and SELECT only. UPDATE and DELETE require partition
--      drop via the DBA cadence (audit retention discipline).
--
--   4. **Retention via pg_partman.** Daily range partitioning aligned
--      with audit_logs (202604280005_phase_9_0sigma_f_audit_logs.sql).
--      Anonymous-scope rows (operator_id IS NULL) age out at 30 days
--      via partition drop; tenant-bound rows ride the audit_logs
--      retention window. The retention sweep is documented next to
--      the audit_logs partition runbook.
--
--   5. **Sensitive fields are never stored in plaintext.** Email is
--      stored as `bytea` SHA-256 (the proxy hashes the normalized
--      email before insert). IP is stored as `bytea` SHA-256 (the
--      proxy hashes the inbound client IP before insert). The
--      `user_agent_class` column stores a coarse classifier
--      ("desktop", "mobile", "bot", "unknown") - never the raw
--      User-Agent string.
--
--   6. **operator_id nullable on purpose.** The login route hits this
--      table BEFORE Firebase scope is resolved (anonymous lookups by
--      `(user_email_hash, ip_hash)`). Once a successful login resolves
--      a tenant, the success row carries `operator_id` and the per-
--      tenant RLS policy admits it. Mixed nullability is the locked
--      shape per the contract.

begin;

create extension if not exists pgcrypto;
create extension if not exists pg_partman;

-- attempted_date is the partition key. The CHECK constraint anchors
-- it to the UTC date of attempted_at so the partition is deterministic
-- from the row data alone (mirrors audit_logs.chain_date).
create table if not exists public.auth_login_attempts (
  attempt_id uuid not null default gen_random_uuid(),
  operator_id uuid null
    references public.operators(operator_id) on delete cascade,
  user_email_hash bytea not null
    check (octet_length(user_email_hash) = 32),
  ip_hash bytea not null
    check (octet_length(ip_hash) = 32),
  outcome text not null
    check (outcome in ('success','failure','locked')),
  attempted_at timestamptz not null default now(),
  attempted_date date not null,
  user_agent_class text null
    check (user_agent_class is null
           or user_agent_class in ('desktop','mobile','bot','unknown')),
  constraint auth_login_attempts_attempted_date_matches_attempted_at check (
    attempted_date = (attempted_at at time zone 'UTC')::date
  ),
  primary key (attempted_date, attempt_id)
) partition by range (attempted_date);

comment on table public.auth_login_attempts is
  'HARD-B - per-attempt login ledger. Source-of-truth for the 5-failure / '
  '15-minute lockout enforcer in the proxy login route. Rows are written '
  'with operator_id NULL when the lookup runs before tenant resolution '
  '(anonymous lockout) and with operator_id set once the verified '
  'Firebase token resolves a tenant. Append-only by grant shape; daily '
  'partitions retire via the DBA partition-drop cadence aligned with '
  'audit_logs (anonymous: 30 days, tenant-bound: per audit log retention).';

comment on column public.auth_login_attempts.user_email_hash is
  'SHA-256 of the normalized email (lowercased, trimmed). Raw email '
  'never lands here per the contract sensitive-field ban.';

comment on column public.auth_login_attempts.ip_hash is
  'SHA-256 of the client IP (the resolved inbound address). Raw IP '
  'never lands here per the contract sensitive-field ban.';

comment on column public.auth_login_attempts.attempted_date is
  'UTC date of attempted_at. Partition driver. CHECK constraint forbids '
  'a value that disagrees with attempted_at - the lockout query relies '
  'on this for partition pruning when scanning the 15-minute window.';

comment on column public.auth_login_attempts.outcome is
  '"success" - credential check passed. "failure" - credential check '
  'failed (per contract: bad_password / unknown_user / mfa_required / '
  'mfa_failed map to the audit row, not this column). "locked" - the '
  'enforcer tripped the threshold and rejected with 423.';

-- pg_partman registration. Daily interval, 7 days premade so a
-- maintenance hiccup cannot leave a producer without a partition.
-- Mirrors the audit_logs registration block.
do $$
begin
  if not exists (
    select 1 from public.part_config
     where parent_table = 'public.auth_login_attempts'
  ) then
    perform public.create_parent(
      p_parent_table  := 'public.auth_login_attempts',
      p_control       := 'attempted_date',
      p_interval      := '1 day',
      p_premake       := 7,
      p_default_table := false,
      p_jobmon        := false
    );
  end if;
end;
$$;

update public.part_config
   set premake                  = 7,
       retention_keep_table     = true,
       infinite_time_partitions = true
 where parent_table = 'public.auth_login_attempts';

-- Anonymous-lookup index. The login route counts failures in the
-- 15-minute window for an `(email_hash, ip_hash)` pair BEFORE a tenant
-- can be resolved, so the leading column on this index is the email
-- hash per the contract. `attempted_date` rides on the WHERE clause
-- the planner uses for partition pruning; per-partition the
-- (user_email_hash, attempted_at desc) index makes the count cheap.
create index if not exists auth_login_attempts_idx_email_hash_time
  on public.auth_login_attempts (user_email_hash, attempted_at desc);

-- Tenant-leading index per the RLS performance discipline. Covers the
-- "show me my failed logins last 24h" tenant audit-review query
-- without scanning the email-hash index. Partial: only tenant-bound
-- rows participate, so anonymous lockout writes do not bloat this
-- index.
create index if not exists auth_login_attempts_idx_operator_time
  on public.auth_login_attempts (operator_id, attempted_at desc)
  where operator_id is not null;

-- Secondary lookup: counts of failures by `(ip_hash, attempted_at)`
-- when the operator-side wants to triage abuse from a single source
-- across multiple emails. Distinct from the leading-email index;
-- partial on outcome != 'success' so success rows do not bloat it.
create index if not exists auth_login_attempts_idx_ip_hash_failures
  on public.auth_login_attempts (ip_hash, attempted_at desc)
  where outcome in ('failure','locked');

-- ----- RLS (wrapper-only per 9.0Sigma.b) -----------------------------
--
-- Tenant-bound rows (operator_id IS NOT NULL) are gated by the
-- per-operator policy. Anonymous rows (operator_id IS NULL) are
-- writable / readable only via the forge_admin BYPASSRLS escape
-- hatch (the proxy `withSystem` path) - the lockout lookup before
-- tenant resolution always runs there.

alter table public.auth_login_attempts enable row level security;

drop policy if exists "auth_login_attempts_per_tenant_select"
  on public.auth_login_attempts;
drop policy if exists "auth_login_attempts_per_tenant_insert"
  on public.auth_login_attempts;

create policy "auth_login_attempts_per_tenant_select"
  on public.auth_login_attempts for select to service_role
  using (
    operator_id is not null
    and operator_id = public.app_current_operator()
  );

create policy "auth_login_attempts_per_tenant_insert"
  on public.auth_login_attempts for insert to service_role
  with check (
    operator_id is not null
    and operator_id = public.app_current_operator()
  );

comment on policy "auth_login_attempts_per_tenant_select" on public.auth_login_attempts is
  'HARD-B - tenants read only their own auth_login_attempts rows. '
  'Wrapper-only via app_current_operator() (item 4). Anonymous '
  '(operator_id IS NULL) rows are visible only via forge_admin '
  'BYPASSRLS (the proxy withSystem path used for pre-tenant lookups).';

comment on policy "auth_login_attempts_per_tenant_insert" on public.auth_login_attempts is
  'HARD-B - tenants may only insert rows attributed to their own '
  'operator. Anonymous rows go through the forge_admin BYPASSRLS path '
  'so the proxy can record failures BEFORE Firebase resolves a tenant.';

-- ----- Append-only grants --------------------------------------------
--
-- service_role + forge_admin get INSERT and SELECT only. UPDATE and
-- DELETE are explicitly REVOKEd so the partition-drop cadence remains
-- the only retention path.

revoke all on public.auth_login_attempts from public;
grant select, insert on public.auth_login_attempts to service_role;
grant select, insert on public.auth_login_attempts to forge_admin;
revoke update, delete on public.auth_login_attempts from service_role;
revoke update, delete on public.auth_login_attempts from forge_admin;

commit;
