-- Phase 8 — Denormalized business_date on integration framework tables.
--
-- Authority:
--   * docs/contracts/phase_7_55_time_boundary_contract.md Rule 11
--     (Storage convention for operator-scoped fact tables) —
--     "denormalized `business_date` `DATE` column lives alongside the
--     source-truth `TIMESTAMPTZ` ... write-once — never recomputed at
--     read."
--   * docs/contracts/integration_spine_architecture_contract.md —
--     business_date denormalized at write via IANA converter.
--   * CLAUDE.md — TIMESTAMPTZ + business_date discipline; every
--     operator-scoped fact-table B-tree index leads with operator_id.
--
-- Three Phase 8 integration framework tables carry fact-bearing time
-- data and need denormalized `business_date` columns:
--
--   | Table                          | Source-truth timestamp |
--   | public.connector_sync_log      | occurred_at TIMESTAMPTZ |
--   | public.inbound_webhook_dead_letter | occurred_at TIMESTAMPTZ |
--   | public.sanity_log              | detected_at TIMESTAMPTZ |
--
-- Five framework tables stay business_date-free:
--
--   * vendor_credentials (credential metadata)
--   * connector_connection (config)
--   * connector_sync_watermark (point-in-time sync markers)
--   * inbound_webhook_idempotency (24h TTL dedupe)
--   * demo_mode_state (singleton)
--
-- Hard rules:
--
--   1. **Additive-safe.** Nullable column → backfill in bounded passes
--      → SET NOT NULL. No long ACCESS EXCLUSIVE locks; backfill loops
--      with LIMIT 50000 per pass.
--
--   2. **Operator-leading indexes.** Every new B-tree leads with
--      `operator_id` (CLAUDE.md / 9.0Σ.b item 4); the
--      `tool/index_leading_column_lint.dart` CI gate enforces.
--
--   3. **Defense in depth via BEFORE INSERT trigger.** The existing
--      Wave-1 sinks
--      (`lib/infrastructure/persistence/postgres/{libro,oracle_micros_simphony,quickbooks_time}_postgres_sink.dart`)
--      insert into `connector_sync_log` without setting
--      `business_date`. The trigger computes it from the row's
--      source-truth TIMESTAMPTZ via the location's IANA timezone
--      AND `business_day_rollover_hour` (mirrors
--      `lib/services/integration/iana_timezone_converter.dart`
--      `toBusinessDate`) whenever NEW.business_date IS NULL.
--      Future spine-bridge sink updates can carry an explicit
--      business_date if computed Dart-side; the trigger only fires
--      on NULL.
--
--   4. **SECURITY DEFINER + OWNED BY forge_admin.** The trigger reads
--      `public.locations` (RLS-enabled) to project the row's
--      timestamp through the per-location IANA zone. Owning the
--      function as `forge_admin` (BYPASSRLS) lets the projection
--      succeed regardless of the inserter's tenant context. Function
--      grants are tightened so only the trigger context invokes it.
--
--   5. **Honest UTC fallback.** `locations.timezone` is declared NOT
--      NULL on the table, but a defensive COALESCE keeps the trigger
--      and backfill from raising on edge fixtures (tests inserting a
--      stub location with empty-string tz). The fallback emits
--      `RAISE NOTICE` so operators can spot drift in staging logs.
--      Honest-fallback rule: do not silently drop the row, do not
--      block the write — denormalize against UTC and surface the
--      degradation.
--
--   6. **Idempotent migration.** `if not exists` on every additive
--      step; the SET NOT NULL only fires once `business_date IS NULL`
--      is empty (idempotent re-apply is a no-op).

begin;

-- ─── 1. Add nullable business_date columns ─────────────────────────

alter table public.connector_sync_log
  add column if not exists business_date date;

alter table public.inbound_webhook_dead_letter
  add column if not exists business_date date;

alter table public.sanity_log
  add column if not exists business_date date;

-- ─── 2. Backfill (inline DO block, bounded LIMIT 50000 per pass) ───
--
-- Inlined rather than wrapped in a SECURITY DEFINER helper because:
-- the migration applier (POSTGRES_ADMIN_URL deployment role) already
-- owns the locations table, so RLS on locations is naturally exempted
-- (Postgres exempts table owners from RLS unless `force row level
-- security` is set; locations does not). A SECURITY DEFINER helper
-- would add deployment-role/forge_admin grant complexity for no
-- functional benefit at migration time.
--
-- The CTE-with-UPDATE shape bounds row count under a LIMIT clause
-- (plain `UPDATE ... FROM ... LIMIT` is invalid Postgres). Each
-- table's loop iterates until the bounded UPDATE returns 0 rows.
--
-- Denorm rule mirrors `lib/services/integration/iana_timezone_converter.dart`
-- (`toBusinessDate`): project the source-truth instant through the
-- location's IANA timezone, then subtract `business_day_rollover_hour`
-- so events whose local time is before the rollover bucket to the
-- prior business date. NULL rollover defaults to 0 (no shift). NULL
-- or empty timezone defaults to UTC (honest fallback per
-- phase_7_55_time_boundary_contract.md).

do $$
declare
  v_pass    bigint;
  v_total   bigint;
  v_orphan  bigint;
begin
  -- Surface rows whose location FK row has no resolvable timezone
  -- (test fixtures mid-cleanup, edge schema states) so staging logs
  -- spot the drift before the UTC-fallback path silently absorbs
  -- them.
  select count(*) into v_orphan
    from public.connector_sync_log csl
   where csl.business_date is null
     and not exists (
       select 1 from public.locations l
        where l.location_id = csl.location_id
          and l.timezone is not null
          and length(l.timezone) > 0
     );
  if v_orphan > 0 then
    raise notice
      'phase_8_business_date_denorm: connector_sync_log carries % '
      'rows without a resolvable location.timezone; UTC fallback '
      'will apply.', v_orphan;
  end if;

  v_total := 0;
  loop
    -- CTE collects everything (target ctid + occurred_at + the
    -- LEFT-JOINed location columns) so the UPDATE only needs to
    -- map by ctid. The PG `UPDATE ... FROM ...` semantics do not
    -- expose the target alias inside FROM-list JOIN ON clauses, so
    -- the LEFT JOIN must live inside the CTE rather than in the
    -- UPDATE's FROM list.
    with target as (
      select csl.ctid,
             csl.occurred_at,
             l.timezone,
             l.business_day_rollover_hour
        from public.connector_sync_log csl
        left join public.locations l
          on l.location_id = csl.location_id
       where csl.business_date is null
       limit 50000
    )
    update public.connector_sync_log csl
       set business_date = (
         (target.occurred_at at time zone
            coalesce(nullif(target.timezone, ''), 'UTC'))
         - (coalesce(target.business_day_rollover_hour, 0)
            * interval '1 hour')
       )::date
      from target
     where csl.ctid = target.ctid;
    get diagnostics v_pass = row_count;
    exit when v_pass = 0;
    v_total := v_total + v_pass;
  end loop;
  raise notice
    'phase_8_business_date_denorm: backfilled % connector_sync_log rows.',
    v_total;

  select count(*) into v_orphan
    from public.inbound_webhook_dead_letter dl
   where dl.business_date is null
     and not exists (
       select 1 from public.locations l
        where l.location_id = dl.location_id
          and l.timezone is not null
          and length(l.timezone) > 0
     );
  if v_orphan > 0 then
    raise notice
      'phase_8_business_date_denorm: inbound_webhook_dead_letter '
      'carries % rows without a resolvable location.timezone; UTC '
      'fallback will apply.', v_orphan;
  end if;

  v_total := 0;
  loop
    with target as (
      select dl.ctid,
             dl.occurred_at,
             l.timezone,
             l.business_day_rollover_hour
        from public.inbound_webhook_dead_letter dl
        left join public.locations l
          on l.location_id = dl.location_id
       where dl.business_date is null
       limit 50000
    )
    update public.inbound_webhook_dead_letter dl
       set business_date = (
         (target.occurred_at at time zone
            coalesce(nullif(target.timezone, ''), 'UTC'))
         - (coalesce(target.business_day_rollover_hour, 0)
            * interval '1 hour')
       )::date
      from target
     where dl.ctid = target.ctid;
    get diagnostics v_pass = row_count;
    exit when v_pass = 0;
    v_total := v_total + v_pass;
  end loop;
  raise notice
    'phase_8_business_date_denorm: backfilled % '
    'inbound_webhook_dead_letter rows.', v_total;

  select count(*) into v_orphan
    from public.sanity_log sl
   where sl.business_date is null
     and not exists (
       select 1 from public.locations l
        where l.location_id = sl.location_id
          and l.timezone is not null
          and length(l.timezone) > 0
     );
  if v_orphan > 0 then
    raise notice
      'phase_8_business_date_denorm: sanity_log carries % rows '
      'without a resolvable location.timezone; UTC fallback will '
      'apply.', v_orphan;
  end if;

  v_total := 0;
  loop
    with target as (
      select sl.ctid,
             sl.detected_at,
             l.timezone,
             l.business_day_rollover_hour
        from public.sanity_log sl
        left join public.locations l
          on l.location_id = sl.location_id
       where sl.business_date is null
       limit 50000
    )
    update public.sanity_log sl
       set business_date = (
         (target.detected_at at time zone
            coalesce(nullif(target.timezone, ''), 'UTC'))
         - (coalesce(target.business_day_rollover_hour, 0)
            * interval '1 hour')
       )::date
      from target
     where sl.ctid = target.ctid;
    get diagnostics v_pass = row_count;
    exit when v_pass = 0;
    v_total := v_total + v_pass;
  end loop;
  raise notice
    'phase_8_business_date_denorm: backfilled % sanity_log rows.',
    v_total;
end
$$;

-- ─── 3. Lock the column NOT NULL ───────────────────────────────────
--
-- Run only after backfill is complete. The trigger added below
-- guarantees forward writes always populate business_date.

alter table public.connector_sync_log
  alter column business_date set not null;

alter table public.inbound_webhook_dead_letter
  alter column business_date set not null;

alter table public.sanity_log
  alter column business_date set not null;

-- ─── 4. Operator-leading B-tree indexes ────────────────────────────
--
-- All three indexes lead with operator_id per CLAUDE.md / 9.0Σ.b
-- item 4 ("Every fact-table B-tree index leads with operator_id").
-- Recent-rows shape: (operator_id, business_date desc, <source ts> desc)
-- — the index probe on operator_id folds with the RLS predicate, then
-- the descending business_date column drives "show me last week's
-- events for this operator" queries.

create index if not exists connector_sync_log_business_date_idx
  on public.connector_sync_log
    (operator_id, business_date desc, occurred_at desc);

create index if not exists inbound_webhook_dead_letter_business_date_idx
  on public.inbound_webhook_dead_letter
    (operator_id, business_date desc, occurred_at desc);

create index if not exists sanity_log_business_date_idx
  on public.sanity_log
    (operator_id, business_date desc, detected_at desc);

-- ─── 5. BEFORE INSERT trigger function ─────────────────────────────
--
-- TG_ARGV[0] names the source-truth timestamp column on the row
-- being inserted. The function projects that column via
-- `to_jsonb(NEW)->>v_ts_col` (record-typed dynamic field access),
-- looks up the row's location.timezone +
-- location.business_day_rollover_hour, and writes the projected
-- business_date when the inserter left it NULL. Inserters that
-- compute business_date Dart-side (none today; the spine-bridge
-- sink fanout will when it lands) bypass the projection by setting
-- NEW.business_date themselves.
--
-- Denorm rule mirrors
-- `lib/services/integration/iana_timezone_converter.dart`
-- (`toBusinessDate`): timezone projection then rollover-hour
-- subtraction.
--
-- SECURITY DEFINER + owner forge_admin: locations is RLS-enabled.
-- Owning the function as forge_admin (BYPASSRLS) lets the lookup
-- succeed regardless of the inserter's tenant context.
--
-- search_path is locked so a session-level search_path mutation
-- cannot redirect the locations lookup to a malicious schema (per
-- the Phase 9.0Σ.b SECURITY DEFINER hardening pattern).

create or replace function public.phase_8_set_business_date()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_ts_col   text := tg_argv[0];
  v_ts_raw   text;
  v_tz       text;
  v_rollover integer;
  v_ts       timestamptz;
begin
  if new.business_date is not null then
    return new;
  end if;

  -- Dynamic column projection. `to_jsonb(record)->>'col'` returns
  -- the column's text value with the timezone offset preserved
  -- (PG renders TIMESTAMPTZ as ISO 8601 with `+HH:MM`); the cast
  -- back to timestamptz preserves the original instant.
  v_ts_raw := to_jsonb(new) ->> v_ts_col;
  if v_ts_raw is null then
    -- Source-truth timestamp is NULL; we cannot project. Leave
    -- business_date NULL so the NOT NULL constraint catches the
    -- malformed insert with a clear column reference.
    return new;
  end if;
  v_ts := v_ts_raw::timestamptz;

  select l.timezone, l.business_day_rollover_hour
    into v_tz, v_rollover
    from public.locations l
   where l.location_id = new.location_id;

  if v_tz is null or length(v_tz) = 0 then
    raise notice
      'phase_8_set_business_date: % row for location_id=% has no '
      'resolvable timezone; falling back to UTC.',
      tg_table_name, new.location_id;
    v_tz := 'UTC';
  end if;

  -- Denorm rule mirrors
  -- `lib/services/integration/iana_timezone_converter.dart`
  -- (`toBusinessDate`): project to local then subtract the rollover
  -- hour so events whose local time is before the rollover bucket
  -- to the prior business date. NULL rollover defaults to 0.
  new.business_date := (
    (v_ts at time zone v_tz)
    - (coalesce(v_rollover, 0) * interval '1 hour')
  )::date;
  return new;
end;
$$;

alter function public.phase_8_set_business_date() owner to forge_admin;

revoke execute on function public.phase_8_set_business_date() from public;
grant execute on function public.phase_8_set_business_date()
  to service_role;
grant execute on function public.phase_8_set_business_date()
  to forge_admin;

comment on function public.phase_8_set_business_date() is
  'Phase 8: BEFORE INSERT trigger that denormalizes business_date '
  'on connector_sync_log / inbound_webhook_dead_letter / sanity_log '
  'from the source-truth TIMESTAMPTZ named in TG_ARGV[0] via the '
  'row''s location.timezone + business_day_rollover_hour. Mirrors '
  'lib/services/integration/iana_timezone_converter.dart '
  '(toBusinessDate). Honors caller-supplied business_date (no '
  'overwrite). Honest UTC + 0-rollover fallback when '
  'locations.timezone is unresolvable. SECURITY DEFINER + owner '
  'forge_admin so the RLS-enabled locations lookup succeeds '
  'without the inserter''s tenant context.';

-- ─── 6. Per-table triggers ─────────────────────────────────────────

drop trigger if exists connector_sync_log_set_business_date
  on public.connector_sync_log;
create trigger connector_sync_log_set_business_date
  before insert on public.connector_sync_log
  for each row
  execute function public.phase_8_set_business_date('occurred_at');

drop trigger if exists inbound_webhook_dead_letter_set_business_date
  on public.inbound_webhook_dead_letter;
create trigger inbound_webhook_dead_letter_set_business_date
  before insert on public.inbound_webhook_dead_letter
  for each row
  execute function public.phase_8_set_business_date('occurred_at');

drop trigger if exists sanity_log_set_business_date
  on public.sanity_log;
create trigger sanity_log_set_business_date
  before insert on public.sanity_log
  for each row
  execute function public.phase_8_set_business_date('detected_at');

commit;
