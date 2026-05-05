-- Phase 8 spine-bridge Lane .A — data accuracy settings + F&F polling tier
-- assignment.
--
-- Authority:
--   docs/contracts/data_accuracy_settings_contract.md "Schema" section
--   (verbatim).
--
-- Two operator-scoped tables:
--
--   1. `public.data_accuracy_settings` — per-(operator, location) operator
--      controlled overrides for canonical-fact resolution. Carries:
--        * Covers source per daypart (vendor / forecast / manual)
--        * Sparse manual covers entries jsonb keyed by business_date+daypart
--        * Wage source binary (vendor / manual_mix)
--      Per the F&F-controlled tier model (REVERSED 2026-05-05) this row
--      carries NO polling-cadence-override fields. Cadence is set by F&F
--      admin via `forge_flow_polling_tier_assignment` (table 2 below).
--
--   2. `public.forge_flow_polling_tier_assignment` — per-(operator,
--      location) tier row + per-vendor cadence JSONB + F&F price + internal
--      cost basis. F&F admin controls; operator never reads directly. The
--      currently-effective row is identified by `effective_until is null`;
--      assignment history is preserved chronologically via the
--      `effective_at desc` index. `forge_admin` writes; `service_role`
--      read-only.
--
-- Hard rules carried verbatim from CLAUDE.md / phase docs:
--
--   * **HP #4 RLS-Ready Schema.** Both tables carry (operator_id,
--     location_id) from creation; per-tenant RLS policy enabled at table
--     creation time; operator-leading B-tree index drives planner
--     pushdown.
--   * **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Every policy
--     body calls `app_current_operator()` / `app_current_location()`. No
--     bare `current_setting(...)` reads.
--   * **Time guardrails (CLAUDE.md / 7.55 Rule 11).** All temporal
--     columns are `TIMESTAMPTZ`. No `TIMESTAMP WITHOUT TIME ZONE`.
--   * **Idempotent migration.** `if not exists` on every CREATE,
--     `drop policy if exists` before `create policy`. Re-applying the
--     migration is a no-op.
--
-- V1 lean cut 2 banned items absent: no KMS, no parse_warnings /
-- parse_partial, no advisory locks, no email_outbox emit, no pg_partman,
-- no SIGTERM handler.

begin;

-- ─── data_accuracy_settings ────────────────────────────────────────
--
-- Per-(operator, location) operator-controlled overrides. One row per
-- (operator, location). Covers source per daypart + sparse manual
-- entries jsonb + wage source binary toggle. No polling-cadence
-- columns — F&F admin controls cadence via the tier assignment table
-- below.

create table if not exists public.data_accuracy_settings (
  setting_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,

  -- ── Covers source per daypart ─────────────────────────────────────
  -- One of: 'vendor' (default), 'forecast', 'manual'.
  covers_source_lunch text not null default 'vendor'
    check (covers_source_lunch in ('vendor', 'forecast', 'manual')),
  covers_source_dinner text not null default 'vendor'
    check (covers_source_dinner in ('vendor', 'forecast', 'manual')),
  covers_source_late_night text not null default 'vendor'
    check (covers_source_late_night in ('vendor', 'forecast', 'manual')),

  -- Manual entries per (business_date, daypart) when covers_source = 'manual'.
  -- jsonb shape: {"2026-05-04": {"lunch": 87, "dinner": 187, "late_night": 12}, ...}
  -- Sparse — only populated dates need entries. Missing date + manual setting =
  -- aggregator returns null for that daypart (no ShiftRecord written).
  covers_manual_entries jsonb not null default '{}'::jsonb
    check (jsonb_typeof(covers_manual_entries) = 'object'),

  -- ── Wage source ────────────────────────────────────────────────────
  -- 'vendor' (default; use labor vendor dollars when exposed) OR
  -- 'manual_mix' (always use wage_role_rows mix; ignore vendor dollars).
  wage_source text not null default 'vendor'
    check (wage_source in ('vendor', 'manual_mix')),

  -- ── Audit ──────────────────────────────────────────────────────────
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text,

  constraint data_accuracy_settings_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.data_accuracy_settings is
  'Phase 8 spine-bridge Lane .A — per-(operator, location) operator '
  'controlled overrides for canonical-fact resolution: covers source '
  'per daypart, sparse manual covers entries, wage source binary. '
  'Polling cadence is NOT here — F&F admin controls via '
  'forge_flow_polling_tier_assignment.';

-- One row per (operator, location).
create unique index if not exists data_accuracy_settings_unique_idx
  on public.data_accuracy_settings (operator_id, location_id);

-- Operator-leading B-tree per RLS-Ready Schema rules.
create index if not exists data_accuracy_settings_operator_idx
  on public.data_accuracy_settings (operator_id, location_id);

-- RLS — wrapper-only per Phase 9.0Σ.b item 4.
alter table public.data_accuracy_settings enable row level security;

drop policy if exists "data_accuracy_settings_per_tenant"
  on public.data_accuracy_settings;
create policy "data_accuracy_settings_per_tenant"
  on public.data_accuracy_settings for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.data_accuracy_settings from public;
grant select, insert, update on public.data_accuracy_settings to service_role;
grant select, insert, update on public.data_accuracy_settings to forge_admin;

-- ─── forge_flow_polling_tier_assignment ────────────────────────────
--
-- Per-(operator, location) tier assignment. F&F admin controls. The
-- currently-effective row is `effective_until is null`; assigning a new
-- tier closes the prior row (effective_until = now()) and inserts a
-- fresh one in a single transaction (see ForgeFlowPollingTierRepository
-- .assignTier). History is preserved.
--
-- service_role: SELECT only (operator-facing reads e.g. tier-name surface).
-- forge_admin:  SELECT/INSERT/UPDATE (the only writer of tier rows).

create table if not exists public.forge_flow_polling_tier_assignment (
  assignment_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,

  -- Tier key: 'standard' | 'premium' | 'custom'.
  tier_key text not null
    check (tier_key in ('standard', 'premium', 'custom')),

  -- Resolved cadence per vendor, seconds. F&F admin sets directly for
  -- 'custom'; for 'standard' / 'premium', the resolver reads from a
  -- F&F-maintained tier definitions table (out of scope for this
  -- contract; defaults to 'standard' presets baked in code).
  -- jsonb shape: {"oracle_micros_simphony": 300, "quickbooks_time": 60, ...}
  polling_cadence_per_vendor_seconds jsonb not null default '{}'::jsonb
    check (jsonb_typeof(polling_cadence_per_vendor_seconds) = 'object'),

  -- F&F's monthly price for this assignment, in cents. Null when
  -- billing is bundled with another product (grandfathered, comped,
  -- enterprise contract).
  monthly_price_cents integer
    check (monthly_price_cents is null or monthly_price_cents >= 0),

  -- F&F's internal vendor API cost basis for this assignment, in cents
  -- per month. Null when not yet measured. NOT operator-facing —
  -- internal margin analysis only.
  vendor_api_cost_estimate_cents_monthly integer
    check (vendor_api_cost_estimate_cents_monthly is null
           or vendor_api_cost_estimate_cents_monthly >= 0),

  effective_at timestamptz not null default now(),
  effective_until timestamptz,  -- null = currently active
  assigned_by_admin_user_id text,  -- forge_admin actor id
  created_at timestamptz not null default now(),

  constraint forge_flow_polling_tier_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.forge_flow_polling_tier_assignment is
  'Phase 8 spine-bridge Lane .A — per-(operator, location) F&F-controlled '
  'polling tier assignment. Currently-effective row marked by '
  'effective_until IS NULL; history preserved chronologically. '
  'forge_admin writes; service_role read-only.';

-- One CURRENTLY-EFFECTIVE assignment per (operator, location).
-- History is preserved; effective_until null marks current.
create unique index if not exists forge_flow_polling_tier_current_idx
  on public.forge_flow_polling_tier_assignment (operator_id, location_id)
  where effective_until is null;

create index if not exists forge_flow_polling_tier_operator_idx
  on public.forge_flow_polling_tier_assignment
    (operator_id, location_id, effective_at desc);

-- RLS — wrapper-only; service_role + forge_admin only (operator never reads
-- this table directly; operator-facing tier name comes through
-- data_accuracy_settings join).
alter table public.forge_flow_polling_tier_assignment enable row level security;

drop policy if exists "forge_flow_polling_tier_per_tenant"
  on public.forge_flow_polling_tier_assignment;
create policy "forge_flow_polling_tier_per_tenant"
  on public.forge_flow_polling_tier_assignment for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.forge_flow_polling_tier_assignment from public;
grant select on public.forge_flow_polling_tier_assignment to service_role;
grant select, insert, update
  on public.forge_flow_polling_tier_assignment to forge_admin;

commit;
