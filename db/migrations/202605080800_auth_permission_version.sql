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
--
-- 2026-05-13 audit carve-out (PR #481 retroactive audit Finding #M1):
-- the functional index below was rewritten in-place during PR #481
-- (changed from `(user_id, permission_version)` to
-- `(operator_id, user_id, permission_version)`) to satisfy CLAUDE.md
-- HP #4 leading-column rule. Migrations are normally immutable once
-- applied; the in-place rewrite is acceptable here because the operator
-- verified 2026-05-13 that this migration had NOT been applied to
-- staging or Production1 at the time of the rewrite (it was still in
-- the "code-ready" pending-apply queue per
-- `docs/POST_HARDENING_FOLLOWUPS.md`). Future migrations MUST follow
-- the expand-contract pattern (new migration drops + recreates the
-- index) once the migration has been applied anywhere downstream.
-- See `docs/archive/_audits/post_codex_wave/pr_481_retroactive_audit.md` for
-- the full rationale.

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
