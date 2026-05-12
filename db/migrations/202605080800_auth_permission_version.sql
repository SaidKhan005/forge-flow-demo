-- B1.A1 — permission_version column on users.
--
-- A3 audit finding: admins keep API access for ~5 minutes after a
-- permission revoke because the live JWT is still valid and the proxy
-- does not compare a DB-side freshness stamp to the token claim.
--
-- Fix: add `permission_version INTEGER NOT NULL DEFAULT 0` to `users`.
-- Every grant/revoke path increments this column; the proxy auth-
-- middleware compares the JWT claim `permission_version` against the
-- DB on every request. On mismatch → 401.
--
-- Replay-safe: `ADD COLUMN IF NOT EXISTS` + re-entrant default.

alter table public.users
  add column if not exists permission_version integer not null default 0;

comment on column public.users.permission_version is
  'Monotonically increasing counter bumped on every role grant or revoke. '
  'Proxy compares JWT claim against this value; a mismatch forces a 401 '
  'so that a revoked token cannot be replayed past the next request.';

-- Tenant-leading functional index for the proxy middleware's authenticated
-- point lookups. `users` is operator-scoped, so keep operator_id first for
-- RLS planning discipline, then user_id for the exact actor lookup.
create index if not exists users_permission_version_idx
  on public.users (operator_id, user_id, permission_version);
