-- Phase 9 audit-fix - rename auth_sessions.refresh_token_hash → token_hash.
--
-- The 9.0 schema named the column `refresh_token_hash` but the value the
-- writer actually stores is the SHA-256 hex digest of the live Firebase
-- ID token (the raw refresh token never leaves the firebase_auth SDK).
-- Calling it "refresh_token_hash" implies refresh-token-reuse detection
-- the writer cannot deliver. Rename to `token_hash` to match what the
-- column actually holds.
--
-- Idempotent: safe to re-run on local + staging + Production1.
--   * Production1 is empty of operator data, so no row migration cost.
--   * Staging applied 9.0 + 9.2 RLS; the rename preserves all grants
--     and policies via Postgres' implicit cascade.
--   * If a future slice adds a real refresh-token-hash column, it can
--     land alongside `token_hash` without a clash.

begin;

do $$
begin
  if exists (
    select 1
      from information_schema.columns
     where table_schema = 'public'
       and table_name = 'auth_sessions'
       and column_name = 'refresh_token_hash'
  ) and not exists (
    select 1
      from information_schema.columns
     where table_schema = 'public'
       and table_name = 'auth_sessions'
       and column_name = 'token_hash'
  ) then
    execute 'alter table public.auth_sessions '
            'rename column refresh_token_hash to token_hash';
  end if;
end;
$$;

comment on column public.auth_sessions.token_hash is
  'SHA-256 hex digest of the credential token associated with this session row. '
  'Currently the live Firebase ID token hash (the raw refresh token is not '
  'exposed by the firebase_auth SDK). Identifies the row for refresh / revoke '
  'lookups; does NOT detect refresh-token reuse on its own.';

commit;
