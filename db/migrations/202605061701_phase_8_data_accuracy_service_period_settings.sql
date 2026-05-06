-- Hardening Wave B1 — Data Accuracy keyed service-period settings.
--
-- Authority:
--   * docs/contracts/data_accuracy_settings_contract.md
--     "Business timing compatibility amendment (2026-05-06)" + "Schema"
--     section. The amendment declares the hardcoded
--     `covers_source_lunch` / `_dinner` / `_late_night` columns a
--     rejected legacy compatibility shape; the V1 implementation target
--     is a keyed child table per `service_period_key`.
--   * docs/contracts/phase_7_55_time_boundary_contract.md
--     (TIMESTAMPTZ-only on operator-scoped fact tables).
--   * docs/contracts/integration_spine_architecture_contract.md
--     (covers-source resolution at the aggregator layer keys on a
--     stable service_period_key, not display label).
--   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
--     (RLS wrapper-only policy bodies; tenant-leading B-tree indexes;
--     `app_current_operator()` / `app_current_location()` only — no
--     bare `current_setting('app.*')`).
--   * docs/_execution/2026-05-05_v1_launch_punchlist.md §5
--     "Data Accuracy keyed service-period settings".
--
-- Why this migration:
--
--   The existing `public.data_accuracy_settings` row carries one
--   covers_source column per hardcoded daypart (lunch / dinner /
--   late_night). Business timing makes service periods restaurant-
--   configurable, so a 4th period (e.g., `breakfast`) or a custom
--   period (e.g., `brunch`) cannot be operator-controlled without a
--   schema change. This migration replaces the hardcoded shape with
--   a keyed child table that admits one covers-source row per
--   (operator, location, service_period_key, effective_at_business_date)
--   so future service periods light up without further migrations.
--
-- What this migration does NOT do (in scope of this lane):
--
--   * Does NOT drop the legacy `covers_source_lunch` /
--     `covers_source_dinner` / `covers_source_late_night` columns on
--     `public.data_accuracy_settings`. They remain as a read-only
--     fallback for rows the keyed table does not yet cover. A future
--     migration will drop them once every read path (aggregator, F&F
--     Ops Console admin reads, operator web Data Accuracy tab) is
--     migrated to the keyed lookup.
--   * Does NOT touch `public.shift_records` or any timing triplet on
--     ShiftFactBuilder — those are owned by the `8.live-and-closed-truth`
--     lanes.
--
-- Hard rules carried verbatim from CLAUDE.md / phase docs:
--
--   * **HP #4 RLS-Ready Schema.** Table carries (operator_id,
--     location_id) from creation; tenant-leading B-tree indexes;
--     per-tenant RLS policy enabled at table-creation time.
--   * **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Policy body
--     calls `app_current_operator()` / `app_current_location()`. No
--     bare `current_setting(...)` reads.
--   * **Time guardrails (CLAUDE.md / 7.55 Rule 11).** All temporal
--     columns are `TIMESTAMPTZ`; the effective-dating anchor is a
--     business-local DATE column denormalized off
--     `locations.business_day_rollover_hour`.
--   * **Idempotent migration.** `if not exists` on every CREATE,
--     `drop policy if exists` before `create policy`. Re-applying the
--     migration is a no-op.
--
-- service_period_key shape pattern matches the `business_timing_*`
-- tables (see 202605060000_phase_business_timing_live_schema.sql line
-- 172): `^[a-z][a-z0-9_]{0,63}$` so `lunch`, `dinner`, `late_night`,
-- `breakfast`, `brunch`, `happy_hour`, etc. are all admissible. The
-- aggregator reads with the wire form of `Daypart` (`lunch`, `dinner`,
-- `late_night`) so existing rows seeded under those keys keep
-- working.

begin;

-- ─── data_accuracy_service_period_settings ────────────────────────
--
-- Keyed child table — one row per (operator, location,
-- service_period_key, effective_at_business_date). The
-- effective-dating model lets operators stage a forward-looking
-- change (e.g., switching covers source on 2026-06-01 ahead of a
-- POS migration) without overwriting the historical lookup; the
-- repository's lookup picks the most recent row at-or-before the
-- supplied business_date so closed-shift aggregation still resolves
-- to the operator's intent on the day the shift closed.
--
-- covers_source extends the legacy 3-way enum with
-- `reservation_plus_walkin` so a future slice can let an operator
-- elect the reservation+walk-in resolution path without further
-- schema churn. The aggregator currently only honors the three
-- legacy values when projecting back onto the existing
-- `CoversSource` enum (Lane 8.spine-bridge.2 — sanctioned legacy
-- compat); `reservation_plus_walkin` is admitted by the schema and
-- will be wired to operator preference in a follow-up slice.
--
-- wage_source carries the 4-way internal class (per the contract's
-- "Wage source resolution" section) so the table supports a future
-- slice that exposes the per-period wage source choice on the
-- operator web Data Accuracy tab. The aggregator's wage-source
-- read still uses the legacy `data_accuracy_settings.wage_source`
-- binary; the per-period field is reserved for the follow-up.

create table if not exists public.data_accuracy_service_period_settings (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  service_period_key text not null
    check (service_period_key ~ '^[a-z][a-z0-9_]{0,63}$'),

  -- Operator's covers-source preference for this service period.
  -- 'vendor' (default; use POS vendor's cover_facts when populated)
  -- 'forecast' (use F&F-derived 60-day forecast substitution)
  -- 'manual' (operator enters covers manually per business date)
  -- 'reservation_plus_walkin' (sum seated party_size from reservation
  --   facts plus operator walk-in count; reserved for the operator
  --   walk-in surface follow-up)
  covers_source text not null default 'vendor'
    check (covers_source in (
      'vendor',
      'forecast',
      'manual',
      'reservation_plus_walkin'
    )),

  -- Operator's wage-source preference for this service period.
  -- 'vendor_per_employee' (labor vendor reports per-employee dollars;
  --   sum directly)
  -- 'vendor_per_position' (labor vendor reports per-position rates;
  --   compute via rate × scheduled hours per role)
  -- 'target_substitution' (no labor vendor dollars; substitute target
  --   wage × actual hours)
  -- 'manual_mix' (operator override; always use wage_role_rows)
  wage_source text not null default 'vendor_per_employee'
    check (wage_source in (
      'vendor_per_employee',
      'vendor_per_position',
      'target_substitution',
      'manual_mix'
    )),

  -- Business-local DATE the row becomes effective. Repository lookup
  -- picks the most recent row at-or-before the supplied
  -- business_date so historical closes resolve under the setting in
  -- force on the day the shift closed.
  effective_at_business_date date not null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text,

  constraint data_accuracy_service_period_settings_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.data_accuracy_service_period_settings is
  'Hardening Wave B1 — keyed Data Accuracy settings per '
  '(operator, location, service_period_key, effective_at_business_date). '
  'Replaces the hardcoded covers_source_lunch / _dinner / _late_night '
  'columns on public.data_accuracy_settings. Legacy columns remain as a '
  'read-only fallback until every read path migrates.';

-- One row per (operator, location, service_period_key,
-- effective_at_business_date). Operators may stage forward-looking
-- changes by inserting a row with a future business date; the
-- aggregator picks the most recent at-or-before the closed shift's
-- business date.
create unique index if not exists
  data_accuracy_service_period_settings_unique_idx
  on public.data_accuracy_service_period_settings (
    operator_id,
    location_id,
    service_period_key,
    effective_at_business_date
  );

-- Operator-leading B-tree per RLS-Ready Schema rules. Effective date
-- descending so the at-or-before lookup terminates at the first row
-- when scanning the index.
create index if not exists
  data_accuracy_service_period_settings_operator_idx
  on public.data_accuracy_service_period_settings (
    operator_id,
    location_id,
    service_period_key,
    effective_at_business_date desc
  );

-- RLS — wrapper-only per Phase 9.0Σ.b item 4.
alter table public.data_accuracy_service_period_settings
  enable row level security;

drop policy if exists "data_accuracy_service_period_settings_per_tenant"
  on public.data_accuracy_service_period_settings;
create policy "data_accuracy_service_period_settings_per_tenant"
  on public.data_accuracy_service_period_settings for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.data_accuracy_service_period_settings from public;
grant select, insert, update
  on public.data_accuracy_service_period_settings to service_role;
grant select, insert, update
  on public.data_accuracy_service_period_settings to forge_admin;

commit;
