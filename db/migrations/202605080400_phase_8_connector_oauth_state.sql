-- Phase 8 — Operator-facing connector OAuth state (CSRF) table.
--
-- Authority:
--   * The active slice prompt (operator-facing OAuth begin/callback
--     routes per vendor).
--   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
--   * CLAUDE.md Hard Promise #4 (per-operator isolation; RLS-ready
--     schema from creation) and Hard Promise #7 (server-side secrets).
--
-- Why this table:
--   The new `/v1/integrations/oauth/<vendor>/begin` route mints a
--   single-use CSRF state token, stores it here with a 10-minute TTL,
--   and hands the operator's browser the vendor authorize URL. The
--   matching `/v1/integrations/oauth/<vendor>/callback` route reads
--   the row, marks it consumed, and only then proceeds to swap the
--   vendor `code` for an access/refresh token bundle. The state row
--   binds (operator_id, location_id, vendor_id) to the token so a
--   stolen state token cannot be replayed against a different
--   operator.
--
-- V1 lean cuts:
--   * No partitioning. Pruning happens via the index on `expires_at`
--     plus an opportunistic delete inside the validate path; a cron
--     sweep is a Production1 follow-up.
--   * No dedicated `consumed_at` index. The (state_token) primary key
--     is the only lookup path; consumed rows linger until the TTL
--     prune deletes them.
--   * No on-conflict logic. The state token is generated server-side
--     with sufficient entropy that collisions are not modeled at V1.
--
-- Time guardrails (CLAUDE.md / 7.55 Rule 11):
--   `created_at` / `expires_at` / `consumed_at` are `TIMESTAMPTZ`
--   (UTC). `TIMESTAMP WITHOUT TIME ZONE` is banned in operator-scoped
--   tables.
--
-- RLS posture (Phase 9.0Σ.b item 4):
--   Wrapper-only policy bodies (`app_current_operator`,
--   `app_current_location`). The route module reads + writes through
--   the tenant-scoped pool so the SET LOCAL chain pins the policy.
--
-- Idempotent: every CREATE uses `if not exists`; every policy is
-- `drop policy if exists` first.

begin;

create table if not exists public.connector_oauth_state (
  state_token text primary key
    check (
      char_length(state_token) between 32 and 256
      and state_token = btrim(state_token)
    ),
  operator_id uuid not null,
  location_id uuid not null,
  vendor_id text not null
    check (
      char_length(vendor_id) between 1 and 64
      and vendor_id = btrim(vendor_id)
    ),
  -- The redirect URI registered with the vendor app. The callback
  -- compares this to its own canonical callback URL so an attacker
  -- who tampers with the begin response cannot redirect the consent
  -- flow to a different host.
  redirect_uri text not null
    check (char_length(redirect_uri) between 1 and 2048),
  -- Per-vendor PKCE verifier (RFC 7636). Null for vendors that do
  -- not implement PKCE; the callback only enforces this when the row
  -- carries a non-null value.
  pkce_verifier text
    check (
      pkce_verifier is null
      or char_length(pkce_verifier) between 43 and 128
    ),
  -- The actor user id from the JWT at begin time. The callback
  -- writes this onto the audit row + connection rows so the
  -- "connected by" trail is preserved when the vendor consent flow
  -- bounces the operator's browser through a different tab.
  actor_user_id text
    check (actor_user_id is null or char_length(actor_user_id) <= 256),
  -- Optional — vendors that scope OAuth to a sub-module (Square's
  -- /v2/locations subset, 7shifts /v2/companies/{id}, etc.) carry
  -- the module here so the callback can pass it through to the
  -- connect persist step.
  module text
    check (
      module is null
      or (char_length(module) between 1 and 64 and module = btrim(module))
    ),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  consumed_at timestamptz,
  constraint connector_oauth_state_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.connector_oauth_state is
  'Phase 8 — single-use CSRF state tokens for operator-facing '
  'OAuth begin/callback. 10-minute TTL via expires_at; the callback '
  'sets consumed_at on first use so a replay returns 400.';

-- Operator-leading composite index for prune scans + per-tenant
-- lookups. CI lint requires every operator-scoped fact-table B-tree
-- index to lead with `operator_id` (or `(operator_id, location_id)`).
create index if not exists connector_oauth_state_operator_idx
  on public.connector_oauth_state (operator_id, location_id, expires_at);

-- Secondary index for the prune sweep (a future cron) — leads with
-- `expires_at` so the sweep can range-scan without rewriting an
-- operator-scoped scan. Per the indexing rules this index does NOT
-- need `operator_id` first because it is used only by platform-wide
-- janitorial paths through `runAsSystem` (RLS off).
create index if not exists connector_oauth_state_expires_at_idx
  on public.connector_oauth_state (expires_at)
  where consumed_at is null;

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ────────────────────────

alter table public.connector_oauth_state enable row level security;

drop policy if exists "connector_oauth_state_per_tenant"
  on public.connector_oauth_state;
create policy "connector_oauth_state_per_tenant"
  on public.connector_oauth_state for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

-- ─── Grants ────────────────────────────────────────────────────────

revoke all on public.connector_oauth_state from public;
grant select, insert, update, delete on public.connector_oauth_state
  to service_role;
grant select, insert, update, delete on public.connector_oauth_state
  to forge_admin;

commit;
