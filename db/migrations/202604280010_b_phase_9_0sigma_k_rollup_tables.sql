-- Phase 9.0Î£.k â€” physical rollup tables for the locked grain set
-- (item 34 / Q3.2 + item 35 / Q3.3-Q3.10 of
-- `phase_9_scalability_decisions_2026-04-27.md`; B32 in
-- `phase_9_execution_backlog.md`).
--
-- Q3.2 Locked: physical rollup tables are the operator-facing default
-- storage form. Materialized views are internal helpers only and
-- MUST NOT be exposed as operator-facing truth (the test in
-- `test/phase_9_0sigma_k_rollups_test.dart` asserts every grain in
-- this slice is a real table, not a materialized view).
--
-- Q3.3 Locked: the grain set is `daypart`, `business_day`, `week`,
-- `accounting_period`, `month`, `quarter`, `year`. Hourly/minute
-- summaries are explicitly excluded from the launch rollup
-- architecture. This migration creates one physical table per grain.
--
-- Common shape (every grain table carries the same columns):
--
--   * Tenant scope:
--       operator_id          â€” RLS leading column (item 4 / 9.0Î£.b
--                              wrappers).
--       scoped_org_unit_id   â€” Q2 hierarchy scope (corp / region /
--                              district / location_group / location
--                              leaf node).
--       location_id          â€” NULLABLE; NULL = hierarchy aggregate
--                              (region / corp), non-NULL = single
--                              location row. NULLS NOT DISTINCT on
--                              the deterministic UPSERT key
--                              collapses two NULL rows to one
--                              conflict target so Q3.6 idempotency
--                              survives location_id = NULL.
--   * Period:
--       period_start         â€” TIMESTAMPTZ window start (UTC stored,
--                              Q1 storage rule).
--       period_end           â€” TIMESTAMPTZ window end (exclusive).
--       business_date        â€” DATE the period belongs to in the
--                              location's local calendar (Q1 storage
--                              rule: computed once at write using
--                              `location.timezone +
--                              business_day_rollover_hour`).
--   * Q3.4 dimensions:
--       metric_family        â€” top-level metric grouping (sales,
--                              labor, variance, traffic, â€¦); the
--                              vendor-aggregation slices (post-7.58)
--                              fill the locked taxonomy.
--       dimensions           â€” jsonb. Q3.4-locked dimension slices
--                              live here as a JSON object per row;
--                              `dimensions_fingerprint` (generated
--                              column below) gives the UPSERT key
--                              a deterministic representation.
--       metrics              â€” jsonb. The actual aggregated values
--                              (sum_sales, labor_pct, variance_$,
--                              etc.). Producer-aggregator schema is
--                              vendor-specific and NOT defined in
--                              this slice (per task scope: "do not
--                              invent final aggregation formulas").
--   * Q3.1 watermark provenance:
--       source_watermark_seq â€” bigint sequence the worker had
--                              processed up to when this row was
--                              computed; matches the
--                              aggregation_state row that produced
--                              it.
--       source_watermark_at  â€” when the worker observed the
--                              watermark.
--   * Q3.4 + Q3.6 reproducibility:
--       rule_version         â€” the labor / target / variance rule
--                              version in force when the row was
--                              computed. Q3.8 rebuilds tag the new
--                              `rule_version` so the dashboard can
--                              tell "old rule" vs "new rule" rows
--                              apart during rollover.
--       computed_at          â€” when the worker wrote/updated the
--                              row.
--   * Q3.7 + Q3.9 freshness/status:
--       freshness_status     â€” fresh / stale / failed /
--                              last_known_good / rebuilding. Maps to
--                              the operator-facing UI labels in Q3.7.
--       last_failure_at      â€” when the most recent failed write
--                              landed (Q3.9 last-known-good
--                              behavior).
--       last_failure_reason  â€” short string for Dev/Admin Health
--                              rendering.
--
-- Q3.6 Idempotency (deterministic UPSERT):
--   The unique index named `<table>_uq` on
--   `(operator_id, scoped_org_unit_id, location_id, period_start,
--    metric_family, dimensions_fingerprint, [grain-specific cols])`
--   uses `NULLS NOT DISTINCT` so location_id NULL collapses to one
--   conflict target per other-key combination. Re-running the same
--   aggregation window writes the same row.
--
-- RLS performance discipline (item 4 / CLAUDE.md):
--   * Every B-tree index leads with operator_id (or
--     `(operator_id, scoped_org_unit_id)` where the index serves a
--     hierarchy lookup).
--   * RLS policy bodies use `public.app_current_operator()`; bare
--     `current_setting()` is forbidden by the lint at
--     `tool/rls_policy_lint.dart`.
--
-- Partition hooks (scalability audit Rollups conditional-pass gate):
--   Each grain table is created `partition by range (period_start)`
--   with a single DEFAULT partition that catches every row at
--   launch. The default partition is the Q3.8 / scalability-audit
--   "partitioning by period/operator" hook â€” a follow-up Phase 9
--   slice can carve out per-month / per-quarter partitions ahead of
--   time without rewriting tenant data, because every write that
--   currently lands in the default partition will be moved by
--   `ATTACH PARTITION ... FOR VALUES FROM ... TO ...` + a one-time
--   `INSERT ... ON CONFLICT DO NOTHING SELECT ... FROM
--   <table>_default WHERE period_start ...` migration. The default
--   partition also keeps small-tenant grains (e.g. `year`) on a
--   single physical heap â€” partitioning a 12-row-per-year table is
--   pure overhead. This migration deliberately stops at the hook;
--   the Phase 9 partition-policy slice locks the windowing rules.
--
-- Live apply status:
--   * Applied and verified on staging + Production1 on 2026-04-29 as part of
--     the Phase 9 `202604280000` through `202604280013` migration set.

begin;

-- â”€â”€â”€ Helper: shared updated_at trigger reuse â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--
-- The existing `cloud_foundation_set_updated_at()` function from
-- 202604250005 sets `updated_at = now()` on row UPDATE. We do NOT
-- attach it to the rollup tables; rollups carry `computed_at` (set
-- by the worker) instead of an opaque `updated_at`. The reasons:
--   * Q3.10 observability needs the worker's exact write time, not
--     a row-trigger time. The worker stamps `computed_at = now()`
--     itself so it can correlate with the matching
--     `aggregation_state.last_run_completed_at` value.
--   * Two timestamp columns (updated_at + computed_at) on a hot
--     UPSERT path doubles the wal volume per write for no extra
--     audit value.
--
-- Listing the omission explicitly so a future reviewer does not
-- "fix" it by adding the trigger and silently double-writing
-- `computed_at`.

-- â”€â”€â”€ Per-grain table definitions â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--
-- Each table is created with the same shape; only the daypart table
-- carries an additional `daypart` text column (the only grain whose
-- granularity is finer than its period_start alone â€” two rows for
-- the same business_day differ by daypart).

-- â”€â”€ rollup_daypart â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

create table if not exists public.rollup_daypart (
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scoped_org_unit_id uuid not null,
  location_id uuid null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  business_date date not null,
  -- Daypart-specific: e.g. `'breakfast'`, `'lunch'`, `'dinner'`,
  -- `'late_night'`, `'all'`. The exact label set is operator-
  -- configurable per Q3.3 ("Operators may configure the calendar
  -- rules behind those grains, including daypart definitions").
  -- The aggregator (post-7.58) writes vendor-mapped values; this
  -- slice does not lock the label set.
  daypart text not null
    check (char_length(daypart) between 1 and 64),
  metric_family text not null
    check (char_length(metric_family) between 1 and 64),
  dimensions jsonb not null default '{}'::jsonb
    check (jsonb_typeof(dimensions) = 'object'),
  metrics jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metrics) = 'object'),
  source_watermark_seq bigint not null default 0
    check (source_watermark_seq >= 0),
  source_watermark_at timestamptz null,
  rule_version text not null default 'v1'
    check (char_length(rule_version) between 1 and 32),
  computed_at timestamptz not null default now(),
  freshness_status text not null default 'fresh'
    check (freshness_status in (
      'fresh', 'stale', 'failed', 'last_known_good', 'rebuilding'
    )),
  last_failure_at timestamptz null,
  last_failure_reason text null,
  -- Generated stored column so the deterministic UPSERT key has a
  -- concrete column to land on. `md5(dimensions::text)` is
  -- deterministic for jsonb because PG normalizes jsonb storage
  -- (sorted keys, no whitespace, deduped). 32-char hex â€” cheap.
  dimensions_fingerprint text generated always as (
    md5(coalesce(dimensions::text, '{}'))
  ) stored,
  -- P2-1 fix from the Codex review: composite FKs tie
  -- scoped_org_unit_id and (when set) location_id back to the same
  -- operator. Without these, a row could carry an operator_id that
  -- points at one tenant while scoped_org_unit_id / location_id
  -- belongs to another, breaking the Q2 hierarchy contract and the
  -- repository's composite (operator_id, location_id) isolation
  -- pattern. The org_units side relies on its `unique (operator_id,
  -- id)` constraint (202604280002); the locations side relies on
  -- `unique (operator_id, location_id)` (202604250005). MATCH SIMPLE
  -- (the default) lets the location_id FK accept NULL for hierarchy
  -- aggregates without disabling the operator-side check.
  constraint rollup_daypart_scope_org_unit_fk
    foreign key (operator_id, scoped_org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint rollup_daypart_scope_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
) partition by range (period_start);

create table if not exists public.rollup_daypart_default
  partition of public.rollup_daypart default;

-- Q3.6 deterministic UPSERT key. NULLS NOT DISTINCT so a NULL
-- location_id (hierarchy aggregate) collapses to one conflict
-- target per other-key combination. Daypart is part of the key
-- because two rows for the same business_day differ by daypart.
create unique index if not exists rollup_daypart_uq
  on public.rollup_daypart (
    operator_id, scoped_org_unit_id, location_id,
    period_start, daypart, metric_family, dimensions_fingerprint
  )
  nulls not distinct;

-- Tenant-leading hot-read index (operator dashboard query: "show
-- me the last N days of dayparts for this org_unit / location").
create index if not exists rollup_daypart_tenant_period_idx
  on public.rollup_daypart (
    operator_id, scoped_org_unit_id, location_id, business_date desc
  );

-- â”€â”€ rollup_business_day â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

create table if not exists public.rollup_business_day (
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scoped_org_unit_id uuid not null,
  location_id uuid null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  business_date date not null,
  metric_family text not null
    check (char_length(metric_family) between 1 and 64),
  dimensions jsonb not null default '{}'::jsonb
    check (jsonb_typeof(dimensions) = 'object'),
  metrics jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metrics) = 'object'),
  source_watermark_seq bigint not null default 0
    check (source_watermark_seq >= 0),
  source_watermark_at timestamptz null,
  rule_version text not null default 'v1'
    check (char_length(rule_version) between 1 and 32),
  computed_at timestamptz not null default now(),
  freshness_status text not null default 'fresh'
    check (freshness_status in (
      'fresh', 'stale', 'failed', 'last_known_good', 'rebuilding'
    )),
  last_failure_at timestamptz null,
  last_failure_reason text null,
  dimensions_fingerprint text generated always as (
    md5(coalesce(dimensions::text, '{}'))
  ) stored,
  -- P2-1 fix from the Codex review: composite FKs tie
  -- scoped_org_unit_id and (when set) location_id back to the same
  -- operator. Without these, a row could carry an operator_id that
  -- points at one tenant while scoped_org_unit_id / location_id
  -- belongs to another, breaking the Q2 hierarchy contract and the
  -- repository's composite (operator_id, location_id) isolation
  -- pattern. The org_units side relies on its `unique (operator_id,
  -- id)` constraint (202604280002); the locations side relies on
  -- `unique (operator_id, location_id)` (202604250005). MATCH SIMPLE
  -- (the default) lets the location_id FK accept NULL for hierarchy
  -- aggregates without disabling the operator-side check.
  constraint rollup_business_day_scope_org_unit_fk
    foreign key (operator_id, scoped_org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint rollup_business_day_scope_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
) partition by range (period_start);

create table if not exists public.rollup_business_day_default
  partition of public.rollup_business_day default;

create unique index if not exists rollup_business_day_uq
  on public.rollup_business_day (
    operator_id, scoped_org_unit_id, location_id,
    period_start, metric_family, dimensions_fingerprint
  )
  nulls not distinct;

create index if not exists rollup_business_day_tenant_period_idx
  on public.rollup_business_day (
    operator_id, scoped_org_unit_id, location_id, business_date desc
  );

-- â”€â”€ rollup_week â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

create table if not exists public.rollup_week (
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scoped_org_unit_id uuid not null,
  location_id uuid null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  business_date date not null,
  metric_family text not null
    check (char_length(metric_family) between 1 and 64),
  dimensions jsonb not null default '{}'::jsonb
    check (jsonb_typeof(dimensions) = 'object'),
  metrics jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metrics) = 'object'),
  source_watermark_seq bigint not null default 0
    check (source_watermark_seq >= 0),
  source_watermark_at timestamptz null,
  rule_version text not null default 'v1'
    check (char_length(rule_version) between 1 and 32),
  computed_at timestamptz not null default now(),
  freshness_status text not null default 'fresh'
    check (freshness_status in (
      'fresh', 'stale', 'failed', 'last_known_good', 'rebuilding'
    )),
  last_failure_at timestamptz null,
  last_failure_reason text null,
  dimensions_fingerprint text generated always as (
    md5(coalesce(dimensions::text, '{}'))
  ) stored,
  -- P2-1 fix from the Codex review: composite FKs tie
  -- scoped_org_unit_id and (when set) location_id back to the same
  -- operator. Without these, a row could carry an operator_id that
  -- points at one tenant while scoped_org_unit_id / location_id
  -- belongs to another, breaking the Q2 hierarchy contract and the
  -- repository's composite (operator_id, location_id) isolation
  -- pattern. The org_units side relies on its `unique (operator_id,
  -- id)` constraint (202604280002); the locations side relies on
  -- `unique (operator_id, location_id)` (202604250005). MATCH SIMPLE
  -- (the default) lets the location_id FK accept NULL for hierarchy
  -- aggregates without disabling the operator-side check.
  constraint rollup_week_scope_org_unit_fk
    foreign key (operator_id, scoped_org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint rollup_week_scope_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
) partition by range (period_start);

create table if not exists public.rollup_week_default
  partition of public.rollup_week default;

create unique index if not exists rollup_week_uq
  on public.rollup_week (
    operator_id, scoped_org_unit_id, location_id,
    period_start, metric_family, dimensions_fingerprint
  )
  nulls not distinct;

create index if not exists rollup_week_tenant_period_idx
  on public.rollup_week (
    operator_id, scoped_org_unit_id, location_id, business_date desc
  );

-- â”€â”€ rollup_accounting_period â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

create table if not exists public.rollup_accounting_period (
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scoped_org_unit_id uuid not null,
  location_id uuid null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  business_date date not null,
  metric_family text not null
    check (char_length(metric_family) between 1 and 64),
  dimensions jsonb not null default '{}'::jsonb
    check (jsonb_typeof(dimensions) = 'object'),
  metrics jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metrics) = 'object'),
  source_watermark_seq bigint not null default 0
    check (source_watermark_seq >= 0),
  source_watermark_at timestamptz null,
  rule_version text not null default 'v1'
    check (char_length(rule_version) between 1 and 32),
  computed_at timestamptz not null default now(),
  freshness_status text not null default 'fresh'
    check (freshness_status in (
      'fresh', 'stale', 'failed', 'last_known_good', 'rebuilding'
    )),
  last_failure_at timestamptz null,
  last_failure_reason text null,
  dimensions_fingerprint text generated always as (
    md5(coalesce(dimensions::text, '{}'))
  ) stored,
  -- P2-1 fix from the Codex review: composite FKs tie
  -- scoped_org_unit_id and (when set) location_id back to the same
  -- operator. Without these, a row could carry an operator_id that
  -- points at one tenant while scoped_org_unit_id / location_id
  -- belongs to another, breaking the Q2 hierarchy contract and the
  -- repository's composite (operator_id, location_id) isolation
  -- pattern. The org_units side relies on its `unique (operator_id,
  -- id)` constraint (202604280002); the locations side relies on
  -- `unique (operator_id, location_id)` (202604250005). MATCH SIMPLE
  -- (the default) lets the location_id FK accept NULL for hierarchy
  -- aggregates without disabling the operator-side check.
  constraint rollup_accounting_period_scope_org_unit_fk
    foreign key (operator_id, scoped_org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint rollup_accounting_period_scope_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
) partition by range (period_start);

create table if not exists public.rollup_accounting_period_default
  partition of public.rollup_accounting_period default;

create unique index if not exists rollup_accounting_period_uq
  on public.rollup_accounting_period (
    operator_id, scoped_org_unit_id, location_id,
    period_start, metric_family, dimensions_fingerprint
  )
  nulls not distinct;

create index if not exists rollup_accounting_period_tenant_period_idx
  on public.rollup_accounting_period (
    operator_id, scoped_org_unit_id, location_id, business_date desc
  );

-- â”€â”€ rollup_month â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

create table if not exists public.rollup_month (
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scoped_org_unit_id uuid not null,
  location_id uuid null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  business_date date not null,
  metric_family text not null
    check (char_length(metric_family) between 1 and 64),
  dimensions jsonb not null default '{}'::jsonb
    check (jsonb_typeof(dimensions) = 'object'),
  metrics jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metrics) = 'object'),
  source_watermark_seq bigint not null default 0
    check (source_watermark_seq >= 0),
  source_watermark_at timestamptz null,
  rule_version text not null default 'v1'
    check (char_length(rule_version) between 1 and 32),
  computed_at timestamptz not null default now(),
  freshness_status text not null default 'fresh'
    check (freshness_status in (
      'fresh', 'stale', 'failed', 'last_known_good', 'rebuilding'
    )),
  last_failure_at timestamptz null,
  last_failure_reason text null,
  dimensions_fingerprint text generated always as (
    md5(coalesce(dimensions::text, '{}'))
  ) stored,
  -- P2-1 fix from the Codex review: composite FKs tie
  -- scoped_org_unit_id and (when set) location_id back to the same
  -- operator. Without these, a row could carry an operator_id that
  -- points at one tenant while scoped_org_unit_id / location_id
  -- belongs to another, breaking the Q2 hierarchy contract and the
  -- repository's composite (operator_id, location_id) isolation
  -- pattern. The org_units side relies on its `unique (operator_id,
  -- id)` constraint (202604280002); the locations side relies on
  -- `unique (operator_id, location_id)` (202604250005). MATCH SIMPLE
  -- (the default) lets the location_id FK accept NULL for hierarchy
  -- aggregates without disabling the operator-side check.
  constraint rollup_month_scope_org_unit_fk
    foreign key (operator_id, scoped_org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint rollup_month_scope_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
) partition by range (period_start);

create table if not exists public.rollup_month_default
  partition of public.rollup_month default;

create unique index if not exists rollup_month_uq
  on public.rollup_month (
    operator_id, scoped_org_unit_id, location_id,
    period_start, metric_family, dimensions_fingerprint
  )
  nulls not distinct;

create index if not exists rollup_month_tenant_period_idx
  on public.rollup_month (
    operator_id, scoped_org_unit_id, location_id, business_date desc
  );

-- â”€â”€ rollup_quarter â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

create table if not exists public.rollup_quarter (
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scoped_org_unit_id uuid not null,
  location_id uuid null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  business_date date not null,
  metric_family text not null
    check (char_length(metric_family) between 1 and 64),
  dimensions jsonb not null default '{}'::jsonb
    check (jsonb_typeof(dimensions) = 'object'),
  metrics jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metrics) = 'object'),
  source_watermark_seq bigint not null default 0
    check (source_watermark_seq >= 0),
  source_watermark_at timestamptz null,
  rule_version text not null default 'v1'
    check (char_length(rule_version) between 1 and 32),
  computed_at timestamptz not null default now(),
  freshness_status text not null default 'fresh'
    check (freshness_status in (
      'fresh', 'stale', 'failed', 'last_known_good', 'rebuilding'
    )),
  last_failure_at timestamptz null,
  last_failure_reason text null,
  dimensions_fingerprint text generated always as (
    md5(coalesce(dimensions::text, '{}'))
  ) stored,
  -- P2-1 fix from the Codex review: composite FKs tie
  -- scoped_org_unit_id and (when set) location_id back to the same
  -- operator. Without these, a row could carry an operator_id that
  -- points at one tenant while scoped_org_unit_id / location_id
  -- belongs to another, breaking the Q2 hierarchy contract and the
  -- repository's composite (operator_id, location_id) isolation
  -- pattern. The org_units side relies on its `unique (operator_id,
  -- id)` constraint (202604280002); the locations side relies on
  -- `unique (operator_id, location_id)` (202604250005). MATCH SIMPLE
  -- (the default) lets the location_id FK accept NULL for hierarchy
  -- aggregates without disabling the operator-side check.
  constraint rollup_quarter_scope_org_unit_fk
    foreign key (operator_id, scoped_org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint rollup_quarter_scope_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
) partition by range (period_start);

create table if not exists public.rollup_quarter_default
  partition of public.rollup_quarter default;

create unique index if not exists rollup_quarter_uq
  on public.rollup_quarter (
    operator_id, scoped_org_unit_id, location_id,
    period_start, metric_family, dimensions_fingerprint
  )
  nulls not distinct;

create index if not exists rollup_quarter_tenant_period_idx
  on public.rollup_quarter (
    operator_id, scoped_org_unit_id, location_id, business_date desc
  );

-- â”€â”€ rollup_year â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--
-- Year-grain rollups produce ~1 row per (operator, org_unit,
-- metric_family, dimensions) per year. The default partition is
-- enough for the foreseeable launch volume; the partition hook is
-- still in place so the future per-year ATTACH PARTITION path is
-- consistent with the other grains.

create table if not exists public.rollup_year (
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  scoped_org_unit_id uuid not null,
  location_id uuid null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  business_date date not null,
  metric_family text not null
    check (char_length(metric_family) between 1 and 64),
  dimensions jsonb not null default '{}'::jsonb
    check (jsonb_typeof(dimensions) = 'object'),
  metrics jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metrics) = 'object'),
  source_watermark_seq bigint not null default 0
    check (source_watermark_seq >= 0),
  source_watermark_at timestamptz null,
  rule_version text not null default 'v1'
    check (char_length(rule_version) between 1 and 32),
  computed_at timestamptz not null default now(),
  freshness_status text not null default 'fresh'
    check (freshness_status in (
      'fresh', 'stale', 'failed', 'last_known_good', 'rebuilding'
    )),
  last_failure_at timestamptz null,
  last_failure_reason text null,
  dimensions_fingerprint text generated always as (
    md5(coalesce(dimensions::text, '{}'))
  ) stored,
  -- P2-1 fix from the Codex review: composite FKs tie
  -- scoped_org_unit_id and (when set) location_id back to the same
  -- operator. Without these, a row could carry an operator_id that
  -- points at one tenant while scoped_org_unit_id / location_id
  -- belongs to another, breaking the Q2 hierarchy contract and the
  -- repository's composite (operator_id, location_id) isolation
  -- pattern. The org_units side relies on its `unique (operator_id,
  -- id)` constraint (202604280002); the locations side relies on
  -- `unique (operator_id, location_id)` (202604250005). MATCH SIMPLE
  -- (the default) lets the location_id FK accept NULL for hierarchy
  -- aggregates without disabling the operator-side check.
  constraint rollup_year_scope_org_unit_fk
    foreign key (operator_id, scoped_org_unit_id)
    references public.org_units(operator_id, id)
    on delete cascade,
  constraint rollup_year_scope_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
) partition by range (period_start);

create table if not exists public.rollup_year_default
  partition of public.rollup_year default;

create unique index if not exists rollup_year_uq
  on public.rollup_year (
    operator_id, scoped_org_unit_id, location_id,
    period_start, metric_family, dimensions_fingerprint
  )
  nulls not distinct;

create index if not exists rollup_year_tenant_period_idx
  on public.rollup_year (
    operator_id, scoped_org_unit_id, location_id, business_date desc
  );

-- â”€â”€â”€ RLS scaffolding (every grain table, wrapper-only per 9.0Î£.b) â”€

alter table public.rollup_daypart enable row level security;
alter table public.rollup_business_day enable row level security;
alter table public.rollup_week enable row level security;
alter table public.rollup_accounting_period enable row level security;
alter table public.rollup_month enable row level security;
alter table public.rollup_quarter enable row level security;
alter table public.rollup_year enable row level security;

-- Per-tenant SELECT/ALL through the `service_role` runtime path.
-- Each policy uses `public.app_current_operator()` (item 4 wrapper)
-- so the planner folds the predicate into the operator-leading
-- index. Cross-tenant admin writes go through `forge_admin`
-- BYPASSRLS via `runAsSystem`, never a separate policy.

create policy "rollup_daypart_per_tenant"
  on public.rollup_daypart for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

create policy "rollup_business_day_per_tenant"
  on public.rollup_business_day for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

create policy "rollup_week_per_tenant"
  on public.rollup_week for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

create policy "rollup_accounting_period_per_tenant"
  on public.rollup_accounting_period for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

create policy "rollup_month_per_tenant"
  on public.rollup_month for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

create policy "rollup_quarter_per_tenant"
  on public.rollup_quarter for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

create policy "rollup_year_per_tenant"
  on public.rollup_year for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

-- â”€â”€â”€ Grants â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--
-- service_role: tenant-side reads (dashboards). The aggregator
-- worker is internal infra and runs through forge_admin BYPASSRLS;
-- it does not need service_role privileges. UPDATE + DELETE on the
-- service_role grant covers Q3.7 "freshness_status flips to stale"
-- writes the freshness sweep can perform inside a tenant transaction
-- if a future slice moves the sweep into the tenant runtime.
-- forge_admin: cross-tenant admin paths (Q3.8 rebuilds, the
-- aggregator worker, retention sweeps).

grant select on public.rollup_daypart to service_role;
grant select on public.rollup_business_day to service_role;
grant select on public.rollup_week to service_role;
grant select on public.rollup_accounting_period to service_role;
grant select on public.rollup_month to service_role;
grant select on public.rollup_quarter to service_role;
grant select on public.rollup_year to service_role;

grant select, insert, update, delete on public.rollup_daypart to forge_admin;
grant select, insert, update, delete on public.rollup_business_day to forge_admin;
grant select, insert, update, delete on public.rollup_week to forge_admin;
grant select, insert, update, delete on public.rollup_accounting_period to forge_admin;
grant select, insert, update, delete on public.rollup_month to forge_admin;
grant select, insert, update, delete on public.rollup_quarter to forge_admin;
grant select, insert, update, delete on public.rollup_year to forge_admin;

-- â”€â”€â”€ Comments (Q3 lock provenance + partition hook callout) â”€â”€â”€â”€â”€â”€â”€

comment on table public.rollup_daypart is
  'Phase 9.0Î£.k (item 34 / Q3.2 + item 35 / Q3.3) â€” physical rollup '
  'table for the `daypart` grain. Operator-facing truth (Q3.2). '
  'Partitioned by period_start; default partition catches all rows '
  'until per-month partitions are carved out by a follow-up Phase 9 '
  'partition-policy slice.';

comment on table public.rollup_business_day is
  'Phase 9.0Î£.k (item 34 / Q3.2 + item 35 / Q3.3) â€” physical rollup '
  'table for the `business_day` grain. Partition hook on '
  'period_start; default partition until per-month partitions land.';

comment on table public.rollup_week is
  'Phase 9.0Î£.k (item 34 / Q3.2 + item 35 / Q3.3) â€” physical rollup '
  'table for the `week` grain. Partition hook on period_start.';

comment on table public.rollup_accounting_period is
  'Phase 9.0Î£.k (item 34 / Q3.2 + item 35 / Q3.3) â€” physical rollup '
  'table for the `accounting_period` grain. Partition hook on '
  'period_start.';

comment on table public.rollup_month is
  'Phase 9.0Î£.k (item 34 / Q3.2 + item 35 / Q3.3) â€” physical rollup '
  'table for the `month` grain. Partition hook on period_start.';

comment on table public.rollup_quarter is
  'Phase 9.0Î£.k (item 34 / Q3.2 + item 35 / Q3.3) â€” physical rollup '
  'table for the `quarter` grain. Partition hook on period_start.';

comment on table public.rollup_year is
  'Phase 9.0Î£.k (item 34 / Q3.2 + item 35 / Q3.3) â€” physical rollup '
  'table for the `year` grain. Partition hook on period_start; the '
  'default partition is sufficient at launch volume.';

commit;
