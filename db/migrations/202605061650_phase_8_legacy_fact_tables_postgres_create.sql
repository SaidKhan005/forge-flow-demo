-- Wave 2 Lane B B-W1 — Phase 8 base-schema migration for the four
-- legacy fact tables (`shift_records`, `cover_facts`, `labor_punches`,
-- `reservation_facts`).
--
-- Authority:
--   * docs/POST_HARDENING_FOLLOWUPS.md "Wave bugs surfaced 2026-05-13 by
--     local apply" W-1 — the bug this migration fixes.
--   * docs/contracts/hardening_rls_and_repository_pattern_contract.md —
--     operator-scoped fact tables carry (operator_id, location_id) from
--     creation, RLS policy is wrapper-only via
--     `app_current_operator()` / `app_current_location()`, B-tree
--     indexes lead with `operator_id`.
--   * docs/contracts/phase_7_55_time_boundary_contract.md — timestamps
--     are TIMESTAMPTZ (UTC); each fact table carries a denormalized
--     `business_date DATE NOT NULL` column; `TIMESTAMP WITHOUT TIME
--     ZONE` is banned.
--   * CLAUDE.md "Hard Promises" HP #1 (pure transport swap), HP #4
--     (per-operator isolation non-negotiable).
--   * docs/contracts/core_app_architecture.md (Layer assignment for
--     fact tables — Layer 4 canonical facts).
--   * db/migrations/202605040000_phase_8_0_integration_framework.sql
--     lines 479-537 — the framework's `add column if not exists
--     vendor_id / vendor_entity_id / vendor_modified_at / raw_payload`
--     loop that runs after this migration; the columns we declare here
--     match what that loop expects so its idempotent guard is a no-op
--     once this migration has landed.
--   * db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql
--     — the migration that fails today with `relation "shift_records"
--     does not exist`; lex-ordered after this one so its `ALTER TABLE`
--     and `CREATE INDEX CONCURRENTLY` statements succeed.
--   * db/migrations/202605080600_phase_8_idempotency_location_id_rekey.sql
--     — drops + recreates the `<fact>_vendor_idempotency_idx` unique
--     indexes on all four tables; the columns it keys on
--     `(operator_id, location_id, vendor_id, vendor_entity_id)` are
--     present at creation here.
--
-- Why this exists:
--
--   Phase 8 framework writes vendor data into the existing SQLite fact
--   tables per HP #1. The Phase 8 Postgres migrations
--   (`202605061700_…_shift_records`, `_..._fk_posture`,
--   `_idempotency_location_id_rekey`, plus the keyed data-accuracy
--   service-period child table) were authored assuming Postgres-side
--   counterparts exist, but no migration ever runs `CREATE TABLE
--   public.shift_records` (or the three sibling fact tables). Today
--   they exist only as minimal local stubs created out-of-band by step
--   6 of `runbooks/local_full_stack_setup_runbook.md`. Staging /
--   Production1 apply fails the moment one of the dependent migrations
--   runs an `ALTER TABLE` against a non-existent relation.
--
--   This migration creates all four fact tables with the columns the
--   codebase already reads/writes (per the audit of
--   `lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart`
--   and the 17 Phase 8 vendor sinks in the same directory). Every
--   subsequent migration that ALTERs these tables then applies cleanly.
--
-- Column inventory (grep ground truth, NOT guesswork):
--
--   * shift_records — from `postgres_shift_record_writer.dart` and the
--     `202605061700_…_shift_records.sql` ALTERs:
--       operator_id, location_id, restaurant_id, week_id, day_label,
--       daypart, status, business_date, covers, forecast_covers,
--       actual_sales, ppa, cplh, splh, foh_hours, boh_hours,
--       foh_labor_dollar, boh_labor_dollar, theoretical_labor_pct,
--       primary_lever, target_profile_id, target_profile_version_id,
--       target_source_type, target_cplh, target_splh, target_ppa,
--       target_foh_wage, target_boh_wage, opz_floor_cplh,
--       opz_ceiling_cplh, theoretical_foh_labor_pct,
--       theoretical_boh_labor_pct, business_timing_profile_id,
--       business_timing_profile_version_id, service_period_key,
--       source_system, source_shift_id, covers_provenance,
--       labor_dollars_provenance, vendor_id, vendor_entity_id,
--       vendor_modified_at, raw_payload, created_at, updated_at.
--
--   * cover_facts — from `square_pos_postgres_sink.dart`,
--     `toast_pos_postgres_sink.dart`, the eight other POS sinks, and
--     the framework's add-column loop:
--       operator_id, location_id, vendor_id, vendor_entity_id,
--       vendor_modified_at, covers, covers_source, opened_at,
--       closed_at, business_date, actual_sales, raw_payload,
--       created_at, updated_at.
--
--   * labor_punches — from `quickbooks_time_postgres_sink.dart`,
--     `adp_postgres_sink.dart`, the four other labor sinks, and the
--     framework's add-column loop:
--       operator_id, location_id, employee_source_id, role_name,
--       shift_start, shift_end, hours_worked, pay_rate, vendor_id,
--       vendor_entity_id, vendor_modified_at, raw_payload,
--       business_date, created_at, updated_at.
--
--   * reservation_facts — from `libro_postgres_sink.dart`,
--     `sevenrooms_reservation_postgres_sink.dart`,
--     `opentable_reservation_postgres_sink.dart`,
--     `tock_reservation_postgres_sink.dart`, and the framework's
--     add-column loop:
--       operator_id, location_id, connection_id, vendor_id,
--       vendor_entity_id, vendor_modified_at, reservation_at,
--       business_date, party_size, status, seated_at, cancelled_at,
--       raw_payload, created_at, updated_at.
--
-- Idempotency:
--
--   * Every CREATE uses `IF NOT EXISTS`. Re-applying this migration is
--     a no-op.
--   * No data writes. No backfill.
--
-- Sequencing note:
--
--   The Phase 8 framework migration `202605040000_phase_8_0_integration_framework.sql`
--   already runs `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` for
--   `vendor_id / vendor_entity_id / vendor_modified_at / raw_payload`
--   on each fact table under an `IF EXISTS` table guard, and creates
--   the `<fact>_vendor_idempotency_idx` UNIQUE indexes. That migration
--   runs BEFORE this one (lex 040000 < 061650), so on a fresh apply
--   its table guard finds no tables to alter and the alter loop is a
--   no-op. The four base tables then materialize here with the columns
--   the framework expected. The subsequent rekey migration
--   `202605080600_…_idempotency_location_id_rekey.sql` then drops +
--   recreates those unique indexes with `(operator_id, location_id,
--   vendor_id, vendor_entity_id)`. This migration includes the
--   pre-rekey index shape so the framework's idempotency contract holds
--   on a fresh Postgres until the rekey lands.
--
-- RLS / grants:
--
--   * Each fact table enables row level security at creation.
--   * Per-tenant policy uses wrapper functions
--     `app_current_operator()` + `app_current_location()` (the four
--     STABLE LEAKPROOF PARALLEL SAFE wrappers from
--     `202604280000_phase_9_0sigma_b_rls_wrappers.sql`). No bare
--     `current_setting('app.*')` reads.
--   * `service_role` and `forge_admin` get SELECT, INSERT, UPDATE
--     (canonical-fact tables are append/upsert; DELETE not needed at
--     V1). `forge_admin` retains BYPASSRLS for support paths.
--   * `public` is REVOKEd.

begin;

create extension if not exists pgcrypto;

-- ─── shift_records ────────────────────────────────────────────────
--
-- Operator-scoped canonical closed-shift fact. Per
-- `postgres_shift_record_writer.dart`:
--
--   * Replace-for-slot semantics on `(operator_id, location_id,
--     business_date, daypart)` UNIQUE — preserves Concern A
--     target_profile_version_id semantics across re-aggregation.
--   * Restaurant_id is TEXT (mirrors the SQLite mobile model's
--     `restaurant_id TEXT` PK on `restaurant_locations`); it is NOT a
--     uuid foreign key.
--   * Timing provenance triplet (`business_timing_profile_id`,
--     `business_timing_profile_version_id`, `service_period_key`) is
--     nullable here; the FK / CHECK / index additions land in
--     `202605061700_…_shift_records.sql` (the migration this one
--     unblocks).
--
-- All TIMESTAMPTZ per the time guardrails contract; `business_date`
-- is the denormalized DATE in restaurant-local timezone (computed by
-- the writer from the closed shift's `business_date` business-local
-- calendar day).

create table if not exists public.shift_records (
  shift_record_id uuid primary key default gen_random_uuid(),

  -- Operator-scoped identity (RLS-ready schema from creation, HP #4).
  operator_id uuid not null,
  location_id uuid not null,

  -- Mobile-model identity. `restaurant_id` is text to match the SQLite
  -- mobile model's PK shape; the canonical projector emits it on every
  -- write via `_seedDemoDataFromReplay` / `PostgresShiftRecordWriter`.
  restaurant_id text not null,
  week_id text not null,
  day_label text not null,
  daypart text not null,
  status text not null default 'closed',

  -- Denormalized restaurant-local business date (Phase 7.55 Rule 11).
  -- NOT NULL because every closed shift lands on a definite business
  -- day; the writer derives it from the local close window.
  business_date date not null,

  -- Volume + economics.
  covers integer not null default 0,
  forecast_covers integer not null default 0,
  actual_sales numeric(14, 4),
  ppa numeric(12, 4),
  cplh numeric(12, 4),
  splh numeric(12, 4),
  foh_hours integer,
  boh_hours integer,
  foh_labor_dollar numeric(14, 4),
  boh_labor_dollar numeric(14, 4),
  theoretical_labor_pct numeric(8, 4),
  primary_lever text,

  -- Target snapshot (preserved verbatim via Concern A on replay).
  target_profile_id text,
  target_profile_version_id text,
  target_source_type text,
  target_cplh numeric(12, 4),
  target_splh numeric(12, 4),
  target_ppa numeric(12, 4),
  target_foh_wage numeric(12, 4),
  target_boh_wage numeric(12, 4),
  opz_floor_cplh numeric(12, 4),
  opz_ceiling_cplh numeric(12, 4),
  theoretical_foh_labor_pct numeric(8, 4),
  theoretical_boh_labor_pct numeric(8, 4),

  -- Timing provenance triplet (FK / CHECK added in 202605061700_…).
  -- Nullable here so legacy / pre-Phase-8 rows stay valid; the lane-0
  -- migration that builds the FK enforces version-equals-profile via
  -- a CHECK constraint downstream.
  business_timing_profile_id uuid,
  business_timing_profile_version_id uuid,
  service_period_key text,

  -- Source provenance for the dashboard pill (metric-honesty contract).
  source_system text,
  source_shift_id text,
  covers_provenance text,
  labor_dollars_provenance text,

  -- Phase 8 integration-framework fields (added here so the framework
  -- migration's idempotent `add column if not exists` loop is a no-op
  -- once this lands). vendor_modified_at is TIMESTAMPTZ per time
  -- guardrails. raw_payload preserves the vendor-shape map for
  -- forensic re-derivation.
  vendor_id text,
  vendor_entity_id text,
  vendor_modified_at timestamptz,
  raw_payload jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint shift_records_slot_uq
    unique (operator_id, location_id, business_date, daypart)
);

comment on table public.shift_records is
  'Operator-scoped canonical closed-shift fact (Phase 8 sub-lane .2 / '
  'spine-bridge). Replace-for-slot on (operator_id, location_id, '
  'business_date, daypart). Concern A: target_profile_version_id '
  'preserved verbatim across re-aggregation. Timing-provenance triplet '
  '(business_timing_profile_id, _version_id, service_period_key) is '
  'nullable; FK + CHECK land in 202605061700_…_shift_records.';

-- Operator-leading B-tree indexes per RLS-Ready Schema. Every index
-- leads with (operator_id) or (operator_id, location_id) so RLS
-- predicates fold into index probes.
create index if not exists shift_records_operator_business_date_idx
  on public.shift_records (
    operator_id,
    location_id,
    business_date desc,
    daypart
  );

create index if not exists shift_records_operator_week_idx
  on public.shift_records (
    operator_id,
    location_id,
    week_id,
    day_label
  );

-- Restaurant-mobile-scope lookup (the mobile sync reads back by
-- restaurant_id under the operator scope). Restaurant_id leads after
-- operator_id so RLS still folds.
create index if not exists shift_records_operator_restaurant_idx
  on public.shift_records (
    operator_id,
    restaurant_id,
    business_date desc
  );

-- Phase 8 vendor idempotency UNIQUE — pre-rekey shape per the framework
-- migration's contract. The
-- `202605080600_phase_8_idempotency_location_id_rekey.sql` migration
-- drops + recreates this index keyed on (operator_id, location_id,
-- vendor_id, vendor_entity_id). Until then, this shape preserves the
-- framework's single-operator idempotency guarantee.
create unique index if not exists shift_records_vendor_idempotency_idx
  on public.shift_records (
    operator_id,
    vendor_id,
    vendor_entity_id,
    vendor_modified_at
  )
  where vendor_id is not null
    and vendor_entity_id is not null
    and vendor_modified_at is not null;

alter table public.shift_records enable row level security;

drop policy if exists "shift_records_per_tenant_location"
  on public.shift_records;
create policy "shift_records_per_tenant_location"
  on public.shift_records for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.shift_records from public;
grant select, insert, update on public.shift_records to service_role;
grant select, insert, update on public.shift_records to forge_admin;

-- ─── cover_facts ──────────────────────────────────────────────────
--
-- Operator-scoped canonical cover fact (one row per finalized POS
-- order). Written by the 11 POS sinks. Same idempotency contract as
-- shift_records: pre-rekey UNIQUE on (operator_id, vendor_id,
-- vendor_entity_id, vendor_modified_at); rekey lands in
-- `202605080600_phase_8_idempotency_location_id_rekey.sql`.

create table if not exists public.cover_facts (
  cover_fact_id uuid primary key default gen_random_uuid(),

  operator_id uuid not null,
  location_id uuid not null,

  -- Vendor identity (framework's idempotency triplet).
  vendor_id text,
  vendor_entity_id text,
  vendor_modified_at timestamptz,

  -- Volume + economics.
  covers integer,
  covers_source text,
  actual_sales numeric(14, 4),

  -- Vendor-projected timestamps (all UTC TIMESTAMPTZ; time guardrails).
  opened_at timestamptz,
  closed_at timestamptz,

  -- Denormalized restaurant-local business date (Phase 7.55 Rule 11).
  business_date date not null,

  raw_payload jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.cover_facts is
  'Operator-scoped canonical cover fact (Phase 8 spine-bridge .1.*). '
  'One row per finalized POS order. Idempotency UNIQUE pre-rekey on '
  '(operator_id, vendor_id, vendor_entity_id, vendor_modified_at); '
  'rekey to include location_id lands in 202605080600_…_idempotency_location_id_rekey.';

create index if not exists cover_facts_operator_business_date_idx
  on public.cover_facts (
    operator_id,
    location_id,
    business_date desc,
    closed_at desc
  );

create index if not exists cover_facts_operator_closed_at_idx
  on public.cover_facts (
    operator_id,
    location_id,
    closed_at desc
  )
  where closed_at is not null;

create unique index if not exists cover_facts_vendor_idempotency_idx
  on public.cover_facts (
    operator_id,
    vendor_id,
    vendor_entity_id,
    vendor_modified_at
  )
  where vendor_id is not null
    and vendor_entity_id is not null
    and vendor_modified_at is not null;

alter table public.cover_facts enable row level security;

drop policy if exists "cover_facts_per_tenant_location"
  on public.cover_facts;
create policy "cover_facts_per_tenant_location"
  on public.cover_facts for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.cover_facts from public;
grant select, insert, update on public.cover_facts to service_role;
grant select, insert, update on public.cover_facts to forge_admin;

-- ─── labor_punches ────────────────────────────────────────────────
--
-- Operator-scoped canonical labor punch (one row per timesheet
-- start/stop). Written by the 6 labor sinks (ADP, 7shifts, Agendrix,
-- Humanity, Push Operations, QuickBooks Time). Same idempotency
-- contract.

create table if not exists public.labor_punches (
  labor_punch_id uuid primary key default gen_random_uuid(),

  operator_id uuid not null,
  location_id uuid not null,

  -- Employee + role identity.
  employee_source_id text,
  role_name text,

  -- Shift window. shift_end NULLABLE when timesheet still open
  -- (employee clocked in but not out yet).
  shift_start timestamptz,
  shift_end timestamptz,

  -- Numeric duration (seconds per QBT contract; sinks normalize).
  hours_worked numeric(12, 4),

  -- Optional vendor-supplied hourly rate (NULL when adapter did not
  -- request the pay-rate scope; QBT-specific).
  pay_rate numeric(12, 4),

  -- Vendor identity (framework idempotency triplet).
  vendor_id text,
  vendor_entity_id text,
  vendor_modified_at timestamptz,

  raw_payload jsonb,

  -- Denormalized restaurant-local business date (resolved by the sink
  -- from shift_start + location.timezone + business_day_rollover_hour).
  business_date date not null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.labor_punches is
  'Operator-scoped canonical labor punch (Phase 8 spine-bridge .1.*). '
  'One row per timesheet start/stop. shift_end NULL when the punch is '
  'still open. Idempotency UNIQUE pre-rekey on (operator_id, vendor_id, '
  'vendor_entity_id, vendor_modified_at); rekey to include location_id '
  'lands in 202605080600_…_idempotency_location_id_rekey.';

create index if not exists labor_punches_operator_business_date_idx
  on public.labor_punches (
    operator_id,
    location_id,
    business_date desc,
    shift_start desc
  );

create index if not exists labor_punches_operator_employee_idx
  on public.labor_punches (
    operator_id,
    location_id,
    employee_source_id,
    shift_start desc
  )
  where employee_source_id is not null;

create unique index if not exists labor_punches_vendor_idempotency_idx
  on public.labor_punches (
    operator_id,
    vendor_id,
    vendor_entity_id,
    vendor_modified_at
  )
  where vendor_id is not null
    and vendor_entity_id is not null
    and vendor_modified_at is not null;

alter table public.labor_punches enable row level security;

drop policy if exists "labor_punches_per_tenant_location"
  on public.labor_punches;
create policy "labor_punches_per_tenant_location"
  on public.labor_punches for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.labor_punches from public;
grant select, insert, update on public.labor_punches to service_role;
grant select, insert, update on public.labor_punches to forge_admin;

-- ─── reservation_facts ────────────────────────────────────────────
--
-- Operator-scoped canonical reservation fact (one row per booking).
-- Written by the 4 reservation sinks (Libro, OpenTable, SevenRooms,
-- Tock). Carries `connection_id` (uuid) — reservation sinks join to
-- the connector_connection row to scope watermark / sync log writes.

create table if not exists public.reservation_facts (
  reservation_fact_id uuid primary key default gen_random_uuid(),

  operator_id uuid not null,
  location_id uuid not null,

  -- Reservation sinks carry connection_id (the connector_connection
  -- uuid the row arrived on); not present on cover_facts or
  -- labor_punches.
  connection_id uuid,

  -- Vendor identity (framework idempotency triplet).
  vendor_id text,
  vendor_entity_id text,
  vendor_modified_at timestamptz,

  -- Reservation window + status.
  reservation_at timestamptz,
  party_size integer,
  status text,
  seated_at timestamptz,
  cancelled_at timestamptz,

  raw_payload jsonb,

  -- Denormalized restaurant-local business date.
  business_date date not null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.reservation_facts is
  'Operator-scoped canonical reservation fact (Phase 8 spine-bridge '
  '.1.*). One row per booking. connection_id carries the originating '
  'connector_connection.connection_id. Idempotency UNIQUE pre-rekey on '
  '(operator_id, vendor_id, vendor_entity_id, vendor_modified_at); '
  'rekey to include location_id lands in '
  '202605080600_…_idempotency_location_id_rekey.';

create index if not exists reservation_facts_operator_business_date_idx
  on public.reservation_facts (
    operator_id,
    location_id,
    business_date desc,
    reservation_at desc
  );

create index if not exists reservation_facts_operator_reservation_at_idx
  on public.reservation_facts (
    operator_id,
    location_id,
    reservation_at desc
  )
  where reservation_at is not null;

create unique index if not exists reservation_facts_vendor_idempotency_idx
  on public.reservation_facts (
    operator_id,
    vendor_id,
    vendor_entity_id,
    vendor_modified_at
  )
  where vendor_id is not null
    and vendor_entity_id is not null
    and vendor_modified_at is not null;

alter table public.reservation_facts enable row level security;

drop policy if exists "reservation_facts_per_tenant_location"
  on public.reservation_facts;
create policy "reservation_facts_per_tenant_location"
  on public.reservation_facts for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.reservation_facts from public;
grant select, insert, update on public.reservation_facts to service_role;
grant select, insert, update on public.reservation_facts to forge_admin;

commit;
