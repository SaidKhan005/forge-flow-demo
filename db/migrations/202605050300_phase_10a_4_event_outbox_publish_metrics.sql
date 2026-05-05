-- Phase 10a.4 — event_outbox publish-error-rate metrics table.
--
-- Closes the production-data gap behind the
-- `event_outbox_publish_error_rate` proxy `/health` producer
-- (`tool/advisor_proxy/health_producers/outbox_producers.dart`). The
-- producer's SQL has been live since 10a.0 and reads:
--
--   select coalesce(sum(failed_publish_count), 0)::bigint as failed,
--          coalesce(sum(attempted_publish_count), 0)::bigint as attempted
--     from event_outbox_publish_metrics
--    where window_start > now() - interval '5 minutes'
--
-- but no migration ever created `event_outbox_publish_metrics` and no
-- writer ever populated it, so the producer always projected to
-- `producer_error` / `unknown` in production. This slice creates the
-- table, instruments the bridge worker to UPSERT one-minute buckets
-- through the admin pool, and adds a daily retention sweep so the
-- bookkeeping table cannot grow unbounded.
--
-- Authority:
--   * `docs/contracts/event_outbox_contract.md` "Foundation vs. Bridge
--     Boundary" — yellow at 1 % publish error rate / red at "repeated
--     publish failures". `outbox_producers.dart` pins the concrete red
--     line at 5 % over the rolling 5-minute window.
--   * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md`
--     "Yellow/red tripwires" subsection — surface in F&F Dev/Admin
--     Health UX, not just logs.
--   * Decision 33 in `phase_9_scalability_decisions_2026-04-27.md`
--     locks the threshold values.
--
-- Hard rules carried from CLAUDE.md and the contract:
--
--   1. This is a platform-wide bridge-bookkeeping table, NOT a
--      per-tenant fact table — same posture as
--      `event_outbox_dead_letter`'s cross-operator depth aggregate
--      (proxy `/health` envelope's "no tenant identifiers" rule). The
--      table therefore has no `operator_id` column and no per-tenant
--      RLS policy. The bridge writer runs through `runAsSystem` on the
--      admin pool; the proxy `/health` producer reads through the same
--      admin pool. Tenants never read or write this table directly.
--   2. RLS is OFF on the table because there is no per-tenant
--      predicate to enforce; access is gated entirely through the
--      grants below (forge_admin only).
--   3. `TIMESTAMPTZ` for `window_start` and `updated_at` per
--      CLAUDE.md "Time Guardrails".
--   4. `attempted_publish_count` and `failed_publish_count` are
--      monotonically increasing per bucket; the bridge UPSERTs deltas
--      so a slow flush followed by a fast flush in the same minute
--      bucket sums correctly.
--   5. Retention is via `pg_cron` daily DELETE — same pattern as the
--      10a.3 event_outbox retention sweep. Rows older than 1 hour are
--      removed; the producer reads only the last 5 minutes, so 1
--      hour is plenty of headroom for clock skew or a delayed cron
--      run without unbounded growth.
--
-- Live apply status: lands on staging first; production cutover after
-- the proxy `/health` `event_outbox_publish_error_rate` metric reports
-- a non-`unknown` value (proves the bridge is writing buckets).

begin;

-- ─── event_outbox_publish_metrics ──────────────────────────────────
--
-- One-minute bucket counter. The bridge worker accumulates publish
-- attempt / failure counts in-memory keyed by minute-of-UTC, and
-- periodically (default 30s) flushes the deltas to this table via
-- a single UPSERT-per-bucket inside `runAsSystem` (admin pool, no
-- tenant context).
--
-- Schema rationale:
--   * `window_start timestamptz primary key` — bucket boundary,
--     truncated to the minute boundary on the writer side. The PK
--     gives O(1) UPSERT lookup and the producer's
--     `where window_start > now() - interval '5 minutes'` predicate
--     range-scans the head of the index without a separate ordering
--     index (PG's btree on a timestamptz column orders ascending).
--   * `attempted_publish_count bigint` — every publish attempt
--     observed by the bridge across all operators in the bucket
--     window. Non-negative `CHECK` so a buggy writer cannot land a
--     negative delta that would underflow into a wrap-around when
--     the producer sums.
--   * `failed_publish_count bigint` — subset of `attempted` that
--     threw inside `RealtimeEventPublisher.publish(...)`. The
--     producer computes the ratio `failed / attempted`; when
--     `attempted = 0` the producer projects green by definition (no
--     traffic in the window means no error rate).
--   * `updated_at timestamptz default now()` — set on every UPSERT
--     so log search can see when the bridge last touched the bucket
--     (debugging "stale" buckets where the writer crashed mid-flush).
--
-- The PK is `window_start` alone; a composite (operator_id, ...)
-- shape is intentionally NOT used because aggregation is platform-
-- wide. Per-operator drilldown is admin SQL against
-- `realtime.bridge.publish_failed` log lines, not a column projection
-- on this table.

create table if not exists public.event_outbox_publish_metrics (
  window_start timestamptz not null primary key,
  attempted_publish_count bigint not null default 0
    check (attempted_publish_count >= 0),
  failed_publish_count bigint not null default 0
    check (failed_publish_count >= 0)
    check (failed_publish_count <= attempted_publish_count),
  updated_at timestamptz not null default now()
);

comment on table public.event_outbox_publish_metrics is
  'Phase 10a.4 — platform-wide one-minute publish-attempt / '
  'publish-failure counters that back the proxy /health '
  'event_outbox_publish_error_rate producer. Bridge-bookkeeping, NOT '
  'a per-tenant fact table; no operator_id, no RLS — access gated by '
  'grants (forge_admin write, forge_admin read). Retention via '
  'pg_cron daily sweep deletes rows older than 1 hour.';

comment on column public.event_outbox_publish_metrics.window_start is
  'Minute-aligned UTC bucket boundary. The bridge writer truncates '
  'now() to the minute before UPSERTing so deltas accumulate inside '
  'a stable bucket regardless of flush cadence.';

comment on column public.event_outbox_publish_metrics.attempted_publish_count is
  'Cumulative publish attempts observed by the bridge in this bucket '
  'window. Sums across all operators (platform-wide aggregation).';

comment on column public.event_outbox_publish_metrics.failed_publish_count is
  'Subset of attempted_publish_count that threw inside '
  'RealtimeEventPublisher.publish(...). The producer reads the ratio '
  'failed / attempted over the rolling 5-minute window.';

-- ─── Function: event_outbox_publish_metrics_retention_sweep ────────
--
-- Cron-callable retention worker. Mirrors the 10a.3 event_outbox
-- retention sweep pattern: SECURITY DEFINER + forge_admin owner so
-- the cross-operator (well, cross-everything — the table is platform-
-- wide) DELETE runs without a tenant context. Returns the deleted-row
-- count so cron run-history confirms the sweep is doing real work.
--
-- Predicate is "older than 1 hour" — the producer reads the last 5
-- minutes, so 1 hour leaves 55 minutes of slack for clock skew or a
-- delayed cron run. With minute-granularity buckets the table holds
-- at most ~60 rows in steady state.

create or replace function public.event_outbox_publish_metrics_retention_sweep()
returns bigint
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_deleted bigint;
begin
  delete from public.event_outbox_publish_metrics
   where window_start < now() - interval '1 hour';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function public.event_outbox_publish_metrics_retention_sweep() is
  'Phase 10a.4 — daily retention sweep. DELETEs '
  'event_outbox_publish_metrics rows where window_start < now() - '
  'INTERVAL ''1 hour''. The producer reads only the last 5 minutes, '
  'so 1 hour is the contract-mandated headroom. SECURITY DEFINER so '
  'the cross-table DELETE runs without a tenant context. Returns the '
  'deleted-row count so the cron run-history surfaces real work.';

alter function public.event_outbox_publish_metrics_retention_sweep()
  owner to forge_admin;

revoke execute on function public.event_outbox_publish_metrics_retention_sweep()
  from public;
grant execute on function public.event_outbox_publish_metrics_retention_sweep()
  to forge_admin;

-- ─── Schedule registration (idempotent) ────────────────────────────
--
-- Daily at 09:05 UTC — five minutes after the 10a.3 retention sweep
-- so the two cross-operator sweeps do not contend for the admin
-- connection at the same instant. Pattern (idempotent unschedule-then-
-- reschedule, NOTICE on cross-database installs) is identical to the
-- 10a.3 retention migration so the live-apply log is uniform.

do $$
declare
  v_jobid bigint;
begin
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; schedule from cron.database_name with cron.schedule_in_database(..., ''forgeflow'')';
    return;
  end if;

  for v_jobid in
    select jobid from cron.job
     where jobname = 'forge_event_outbox_publish_metrics_retention_sweep'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'forge_event_outbox_publish_metrics_retention_sweep',
    '5 9 * * *',
    'select public.event_outbox_publish_metrics_retention_sweep();'
  );
end$$;

-- ─── Grants ────────────────────────────────────────────────────────
--
-- forge_admin owns the write surface (bridge worker + retention sweep
-- both run as forge_admin via runAsSystem) and the read surface (the
-- proxy /health admin pool). service_role is intentionally NOT
-- granted — tenants have no business reading platform-wide bridge
-- bookkeeping, and the producer reads through the admin pool.

revoke all on public.event_outbox_publish_metrics from public;

grant select, insert, update, delete on public.event_outbox_publish_metrics
  to forge_admin;

commit;
