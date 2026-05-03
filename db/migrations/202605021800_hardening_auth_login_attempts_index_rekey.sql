-- HARD-B follow-up: re-key auth_login_attempts indexes now that the
-- repo-wide operator-leading lint covers this table.
--
-- The email-hash lockout index remains intentionally cross-tenant:
-- the login lockout enforcer evaluates `(email_hash, ip_hash)` before
-- Firebase/operator scope exists and runs through the forge_admin
-- BYPASSRLS path. The IP-failure triage index, however, supports
-- operator-side review and must lead with operator_id.

begin;

drop index if exists public.auth_login_attempts_idx_email_hash_time;

create index if not exists auth_login_attempts_idx_email_hash_time
  on public.auth_login_attempts (user_email_hash, ip_hash, attempted_at desc);

drop index if exists public.auth_login_attempts_idx_ip_hash_failures;

create index if not exists auth_login_attempts_idx_ip_hash_failures
  on public.auth_login_attempts (operator_id, ip_hash, attempted_at desc)
  where operator_id is not null
    and outcome in ('failure','locked');

commit;
