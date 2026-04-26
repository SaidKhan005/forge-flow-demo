-- Phase 11a.11c.1 — Advisor cloud foundation schema (Tier 1 + Tier 1.5).
--
-- Creates the foundational identity tables (`operators`, `locations`,
-- `users`, `operator_admins`) and the support tables that every later
-- proxy / advisor / billing surface keys off:
--
--   * `usage_logs`       — partitioned per-period rollup of token /
--                          cost / request counts (proxy writes here
--                          starting in 11a.11d).
--   * `usage_caps`       — per-(operator, location, usage_class) cap
--                          definition the proxy reads before allowing
--                          a provider call.
--   * `proxy_requests`   — idempotency table; UNIQUE on
--                          `idempotency_key`, with `request_type` so
--                          Phase 12 tool-call writes reuse the same
--                          surface.
--   * `feature_flags`    — global / operator / location scopes
--                          enforced via partial unique indexes; powers
--                          the Q12 retrieval-mode flag, per-operator
--                          full-content logging opt-in, and any other
--                          gating that needs to flip without redeploys.
--   * `fx_rates`         — daily FX snapshots so internal USD cost
--                          accounting can render in the operator's
--                          `preferred_currency`.
--
-- All operator-scoped tables carry `(operator_id, location_id)` as a
-- COMPOSITE foreign key referencing `locations(operator_id,
-- location_id)`. `locations` carries an explicit `unique (operator_id,
-- location_id)` so the composite FK has a target. This rejects the
-- `(operator_a, location_b)` cross-tenant mismatch at the database
-- layer — a row whose `location_id` belongs to a different operator
-- can never be inserted, even before RLS turns on in Phase 9. Time
-- columns are `TIMESTAMPTZ` everywhere — the unzoned local-time
-- variant is banned in operator-scoped tables (silent DST corruption
-- is unrecoverable). Numeric counters and money columns carry `>= 0`
-- checks; FX rates carry `> 0` checks.
--
-- ON DELETE behavior: deleting a location cascades to every operator-
-- scoped fact row that references it. Deleting an operator cascades to
-- its locations (via `locations.operator_id` single-column FK), which
-- in turn cascades to the fact rows. PIPEDA right-to-erasure is
-- satisfied by the operator-delete cascade chain.
--
-- RLS is enabled on every table with a service-role-only policy stub.
-- Phase 9 turns on per-operator auth-bearing policies; until then only
-- the proxy's service-role connection touches these tables. The stub
-- pattern matches the corpus (`11a.3`) and counter (`11a.10b`)
-- migrations so the cloud-foundation surface looks identical to the
-- existing advisor surface.
--
-- This migration does not load rows, does not call any provider, and
-- does not modify the four prior advisor migrations (corpus storage,
-- embedding contract, vector search, proxy usage counters).

create extension if not exists pgcrypto;

-- Shared `updated_at` trigger function used by every cloud-foundation
-- table. Kept distinct from `public.advisor_set_updated_at` (defined in
-- 11a.3) so the cloud-foundation surface is self-contained — dropping
-- the foundation does not orphan corpus triggers and vice-versa.
create or replace function public.cloud_foundation_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ─── Foundational identity tables ───────────────────────────────────

create table if not exists public.operators (
  operator_id uuid primary key default gen_random_uuid(),
  business_name text not null,
  owner_email text not null,
  subscription_tier text not null default 'launch',
  preferred_currency char(3) not null default 'CAD'
    check (preferred_currency ~ '^[A-Z]{3}$'),
  primary_location_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.locations (
  location_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  name text not null,
  address text not null default '',
  timezone text not null,
  business_day_rollover_hour integer
    check (business_day_rollover_hour between 0 and 23),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Composite uniqueness target for the `(operator_id, location_id)`
  -- composite FKs that operator-scoped fact tables and `feature_flags`
  -- declare below. `location_id` is already unique via the PK; this
  -- explicit pair-uniqueness lets Postgres accept the composite FK
  -- definitions without a separate unique index.
  unique (operator_id, location_id)
);

-- `operators.primary_location_id` references `locations`, but
-- `locations.operator_id` references `operators`. Resolve the cycle
-- by adding the FK after `locations` is created. The FK is COMPOSITE
-- on `(operator_id, primary_location_id) -> locations(operator_id,
-- location_id)` so an operator's primary location must belong to that
-- same operator — pointing at another operator's location is rejected
-- by the database. `ON DELETE SET NULL (primary_location_id)` (PG15+)
-- nulls only the pointer column when a referenced location is deleted
-- and preserves `operator_id`, which is NOT NULL on `operators`.
alter table public.operators
  drop constraint if exists operators_primary_location_fk;
alter table public.operators
  add constraint operators_primary_location_fk
  foreign key (operator_id, primary_location_id)
  references public.locations(operator_id, location_id)
  on delete set null (primary_location_id);

create table if not exists public.users (
  user_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  email text not null,
  role text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.operator_admins (
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  is_super_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, operator_id)
);

-- ─── Counter / cap / idempotency / flags / FX ──────────────────────

-- Declarative range partitioning by `period_start`. The composite PK
-- includes `period_start` (Postgres requires the partition key to be
-- part of every unique constraint on a partitioned table). A DEFAULT
-- partition catches writes that fall outside any month-specific
-- partition the post-launch maintenance job creates ahead of time;
-- without it, a write to an unprovisioned month would fail.
create table if not exists public.usage_logs (
  operator_id uuid not null,
  location_id uuid not null,
  usage_class text not null,
  period_start timestamptz not null,
  token_count bigint not null default 0
    check (token_count >= 0),
  cost_usd numeric(12, 4) not null default 0
    check (cost_usd >= 0),
  request_count bigint not null default 0
    check (request_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (operator_id, location_id, usage_class, period_start),
  -- Composite FK rejects (operator_a, location_b) mismatches. An
  -- operator delete cascades through `locations` (via
  -- `locations.operator_id` FK) and arrives here as the chained
  -- cascade. A direct location delete also cascades here.
  foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
) partition by range (period_start);

create table if not exists public.usage_logs_default
  partition of public.usage_logs default;

create table if not exists public.usage_caps (
  operator_id uuid not null,
  location_id uuid not null,
  usage_class text not null,
  monthly_cap_usd numeric(12, 4) not null default 0
    check (monthly_cap_usd >= 0),
  per_invocation_cap_usd numeric(12, 4) not null default 0
    check (per_invocation_cap_usd >= 0),
  created_by uuid null,
  updated_by uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (operator_id, location_id, usage_class),
  -- Composite FK enforces that the cap is for a real
  -- (operator, location) pair owned by the same operator.
  foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

create table if not exists public.proxy_requests (
  request_id uuid primary key default gen_random_uuid(),
  idempotency_key text not null unique,
  request_type text not null,
  operator_id uuid not null,
  location_id uuid not null,
  usage_class text not null,
  response_payload jsonb null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Composite FK enforces that the idempotency record is scoped to a
  -- real (operator, location) pair owned by the same operator.
  foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

create table if not exists public.feature_flags (
  flag_id uuid primary key default gen_random_uuid(),
  flag_name text not null,
  -- Single-column FK enforces operator existence on operator-scoped
  -- and location-scoped rows. Global rows have NULL operator_id.
  operator_id uuid null references public.operators(operator_id)
    on delete cascade,
  -- `location_id` validation rides the composite FK below
  -- (MATCH SIMPLE skips check when either column is NULL, so global
  -- and operator-scope rows pass; location-scope rows must point at a
  -- real (operator_id, location_id) pair owned by the same operator).
  location_id uuid null,
  enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Reject the malformed (location set, operator NULL) shape: a
  -- location-scoped flag must always carry the operator that owns the
  -- location. Without this, the location-scope partial unique index
  -- below cannot detect duplicates of `(flag_name, NULL, location_x)`.
  check (location_id is null or operator_id is not null),
  -- Composite FK to `locations(operator_id, location_id)` rejects
  -- (operator_a, location_b) mismatches on location-scope rows;
  -- skipped (MATCH SIMPLE) for global / operator-scope rows whose
  -- `location_id` is NULL.
  foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

-- Postgres treats NULL as distinct in plain UNIQUE — so a global flag
-- (operator_id IS NULL, location_id IS NULL) needs a partial index
-- targeting exactly that scope to enforce uniqueness. Three partial
-- indexes cover the three logical scopes (global / operator-wide /
-- location-scoped) without overlap.
create unique index if not exists feature_flags_global_scope_idx
  on public.feature_flags (flag_name)
  where operator_id is null and location_id is null;

create unique index if not exists feature_flags_operator_scope_idx
  on public.feature_flags (flag_name, operator_id)
  where operator_id is not null and location_id is null;

-- Predicate requires BOTH columns present so `(operator_id NULL,
-- location_id X)` rows (which the CHECK above already rejects, but
-- belt-and-braces) cannot create partial-index duplicates.
create unique index if not exists feature_flags_location_scope_idx
  on public.feature_flags (flag_name, operator_id, location_id)
  where operator_id is not null and location_id is not null;

create table if not exists public.fx_rates (
  base_currency char(3) not null
    check (base_currency ~ '^[A-Z]{3}$'),
  quote_currency char(3) not null
    check (quote_currency ~ '^[A-Z]{3}$'),
  as_of_date date not null,
  rate numeric(20, 8) not null check (rate > 0),
  source text not null default 'unknown',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (base_currency, quote_currency, as_of_date)
);

-- ─── updated_at triggers ───────────────────────────────────────────

drop trigger if exists operators_set_updated_at on public.operators;
create trigger operators_set_updated_at
before update on public.operators
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists locations_set_updated_at on public.locations;
create trigger locations_set_updated_at
before update on public.locations
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists users_set_updated_at on public.users;
create trigger users_set_updated_at
before update on public.users
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists operator_admins_set_updated_at on public.operator_admins;
create trigger operator_admins_set_updated_at
before update on public.operator_admins
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists usage_logs_set_updated_at on public.usage_logs;
create trigger usage_logs_set_updated_at
before update on public.usage_logs
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists usage_caps_set_updated_at on public.usage_caps;
create trigger usage_caps_set_updated_at
before update on public.usage_caps
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists proxy_requests_set_updated_at on public.proxy_requests;
create trigger proxy_requests_set_updated_at
before update on public.proxy_requests
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists feature_flags_set_updated_at on public.feature_flags;
create trigger feature_flags_set_updated_at
before update on public.feature_flags
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists fx_rates_set_updated_at on public.fx_rates;
create trigger fx_rates_set_updated_at
before update on public.fx_rates
for each row execute function public.cloud_foundation_set_updated_at();

-- ─── RLS scaffolding (service-role-only policy stubs) ──────────────

alter table public.operators enable row level security;
alter table public.locations enable row level security;
alter table public.users enable row level security;
alter table public.operator_admins enable row level security;
alter table public.usage_logs enable row level security;
alter table public.usage_logs_default enable row level security;
alter table public.usage_caps enable row level security;
alter table public.proxy_requests enable row level security;
alter table public.feature_flags enable row level security;
alter table public.fx_rates enable row level security;

create policy "operators_service_role_all"
  on public.operators
  for all
  to service_role
  using (true)
  with check (true);

create policy "locations_service_role_all"
  on public.locations
  for all
  to service_role
  using (true)
  with check (true);

create policy "users_service_role_all"
  on public.users
  for all
  to service_role
  using (true)
  with check (true);

create policy "operator_admins_service_role_all"
  on public.operator_admins
  for all
  to service_role
  using (true)
  with check (true);

create policy "usage_logs_service_role_all"
  on public.usage_logs
  for all
  to service_role
  using (true)
  with check (true);

create policy "usage_logs_default_service_role_all"
  on public.usage_logs_default
  for all
  to service_role
  using (true)
  with check (true);

create policy "usage_caps_service_role_all"
  on public.usage_caps
  for all
  to service_role
  using (true)
  with check (true);

create policy "proxy_requests_service_role_all"
  on public.proxy_requests
  for all
  to service_role
  using (true)
  with check (true);

create policy "feature_flags_service_role_all"
  on public.feature_flags
  for all
  to service_role
  using (true)
  with check (true);

create policy "fx_rates_service_role_all"
  on public.fx_rates
  for all
  to service_role
  using (true)
  with check (true);

-- ─── Documentation comments ────────────────────────────────────────

comment on table public.operators is
  '11a.11c.1 cloud foundation. Top-level tenant. preferred_currency drives display formatting; primary_location_id selects the location used for cross-location aggregations when multi-location operators span time zones.';
comment on table public.locations is
  '11a.11c.1 cloud foundation. Per-location settings. timezone (IANA) + business_day_rollover_hour drive write-once business_date computation on operator-scoped fact tables (decided 2026-04-25).';
comment on table public.users is
  '11a.11c.1 cloud foundation. Application-side user records (distinct from Supabase auth.users which lives in the auth schema).';
comment on table public.operator_admins is
  '11a.11c.1 cloud foundation. Operator-admin grant. Composite PK on (user_id, operator_id) so a user can admin multiple operators (F&F super-admin pattern via is_super_admin).';
comment on table public.usage_logs is
  '11a.11c.1 cloud foundation. Partitioned per-(operator, location, usage_class, period_start) rollup of token / cost / request counts. Phase 11a.11d wires per-request UPSERTs into the matching partition; default partition catches months without an explicit partition.';
comment on table public.usage_caps is
  '11a.11c.1 cloud foundation. Per-(operator, location, usage_class) cap definition. monthly_cap_usd and per_invocation_cap_usd are USD; display layer converts to operator preferred_currency via fx_rates at render time.';
comment on table public.proxy_requests is
  '11a.11c.1 cloud foundation. Idempotency table. UNIQUE on idempotency_key; request_type generalises for Phase 12 tool-call reuse. Nightly maintenance prunes rows older than 48 hours.';
comment on table public.feature_flags is
  '11a.11c.1 cloud foundation. Three logical scopes (global / operator-wide / location-scoped) enforced via three partial unique indexes — Postgres treats NULL as distinct in plain UNIQUE, so the partial-index pattern is required to forbid duplicate rows for the same logical scope.';
comment on table public.fx_rates is
  '11a.11c.1 cloud foundation. Daily FX snapshots from an external source. Display layer converts internal USD cost accounting to operator preferred_currency at render time.';
