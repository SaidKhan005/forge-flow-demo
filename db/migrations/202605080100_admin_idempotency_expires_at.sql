-- Lane: code-health.M1 — admin idempotency `expires_at` + sweep cron.
--
-- CODE_HEALTH reference: C4 — `tool/advisor_proxy/advisor_proxy.dart`
-- `_runAdminIdempotent` helper has no compute-failure cleanup or TTL on
-- the admin idempotency table. A single transient compute failure
-- between `reserve()` and `completeReservation()` (proxy crash, network
-- glitch, panic in the route body, etc.) leaves the row pinned in the
-- "in-flight" state — `response_status IS NULL AND completed_at IS
-- NULL` — forever. Every replay of the same Idempotency-Key thereafter
-- returns `409 idempotency_request_in_flight`, even though no work is
-- actually in flight, until an operator manually deletes the row.
--
-- This migration is the schema half of the fix: each row gets a
-- mandatory `expires_at TIMESTAMPTZ` defaulting to `now() + interval
-- '15 minutes'`, a partial B-tree index on `(expires_at)` for in-flight
-- rows, and a `pg_cron` sweep that runs every 5 minutes and DELETEs
-- in-flight rows whose `expires_at` has passed. The matching code-side
-- reclaim logic — treating an in-flight row whose `expires_at < now()`
-- as orphan and re-reserving it on the spot — lands in lane L4 (proxy
-- hardening). M1 ships only the schema + sweep so once the cron is
-- live the orphan rows are bounded to a 15-minute pin window even
-- without a proxy redeploy.
--
-- Authority:
--   * `db/migrations/202605021000_phase_hardh_admin_idempotency.sql` —
--     original CREATE TABLE for `public.admin_request_idempotency`.
--     The HARD-H table has no `status` column; "in-flight" is signaled
--     by `response_status IS NULL AND completed_at IS NULL`. The
--     partial index and sweep WHERE clause use that pair as the
--     in-flight predicate.
--   * `CODE_HEALTH.md` — C4 finding.
--
-- Sweep scope:
-- ============
-- The sweep is registered cluster-wide via `cron.schedule(jobname,
-- '*/5 * * * *', sql)`, NOT per-operator. The HARD-H table is
-- intentionally cross-tenant — admin actors (super_admin, ff_support)
-- carry no `operator_id` in their JWT and the table itself has no
-- `operator_id` column, so there is no per-tenant axis to schedule
-- along. Correctness comes from the WHERE clause (`response_status IS
-- NULL AND completed_at IS NULL AND expires_at < now()`), which only
-- removes rows whose 15-minute reserve TTL has expired without
-- completion — i.e. orphans the proxy will never finish.
--
-- pg_cron metadata in Azure DB Flexible Server:
-- =============================================
-- Azure keeps pg_cron metadata in the database named by
-- `cron.database_name`. When pg_cron is in a different database than
-- the migration target, the DO block below raises a NOTICE so the
-- live-apply log captures the "schedule from cron.database_name with
-- cron.schedule_in_database(..., 'forgeflow')" manual step. Same shape
-- as `202605051000_phase_10a_3_outbox_retention_sweep.sql`.

begin;

-- ─── expires_at column ─────────────────────────────────────────────
--
-- DEFAULT covers every new INSERT (the proxy `reserve()` path uses a
-- bare `INSERT ... ON CONFLICT DO NOTHING` that does not name the
-- column, so the DEFAULT applies). The DEFAULT also covers existing
-- rows at ALTER time because `ADD COLUMN ... DEFAULT <expr> NOT NULL`
-- evaluates the expression for every existing row. The follow-up
-- UPDATE statement is defensive: it ensures every row has a TTL even
-- if a future migration re-runs ALTER on a partially-populated table.

alter table public.admin_request_idempotency
  add column if not exists expires_at timestamptz not null
    default (now() + interval '15 minutes');

update public.admin_request_idempotency
   set expires_at = now() + interval '15 minutes'
 where expires_at is null;

comment on column public.admin_request_idempotency.expires_at is
  'TTL for the reservation. Defaults to now()+15min on INSERT. The '
  'pg_cron sweep `admin_idempotency_sweep` (*/5 * * * *) DELETEs '
  'in-flight rows (response_status IS NULL AND completed_at IS NULL) '
  'whose expires_at has passed so a transient compute failure between '
  'reserve and completeReservation cannot pin the key to 409 forever.';

-- ─── Partial index for the sweep ───────────────────────────────────
--
-- The sweep scans for in-flight rows whose `expires_at` has passed.
-- A partial B-tree on `(expires_at)` filtered by the in-flight
-- predicate keeps the scan tight even as the table grows past
-- millions of completed rows. Completed rows (response_status IS
-- NOT NULL) are not in the index and are never visited by the sweep.

create index if not exists admin_request_idempotency_in_flight_expires_idx
  on public.admin_request_idempotency (expires_at)
  where response_status is null and completed_at is null;

comment on index public.admin_request_idempotency_in_flight_expires_idx is
  'Partial index covering only in-flight rows (response_status IS NULL '
  'AND completed_at IS NULL), ordered by expires_at. Backs the '
  '`admin_idempotency_sweep` pg_cron job so the every-5-minute DELETE '
  'is a tight index scan even when completed rows fill the table.';

-- ─── pg_cron sweep registration (idempotent) ───────────────────────
--
-- Every 5 minutes. The DO block matches the rollups + retention-sweep
-- idempotency pattern: unschedule any prior `admin_idempotency_sweep`
-- entry by jobid first, then reschedule. `cron.schedule(jobname, …)`
-- raises `unique_violation` on a duplicate jobname.
--
-- The sweep SQL is inlined (not wrapped in a SECURITY DEFINER
-- function) because the DELETE shape is trivial and the table is
-- platform-wide with no RLS — service_role / forge_admin can DELETE
-- directly. Inlining keeps the migration self-contained; a future
-- slice can promote to a function if observability (sweep counts,
-- duration) becomes useful.

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
     where jobname = 'admin_idempotency_sweep'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'admin_idempotency_sweep',
    '*/5 * * * *',
    $sweep$
      delete from public.admin_request_idempotency
       where response_status is null
         and completed_at is null
         and expires_at < now()
    $sweep$
  );
end$$;

commit;
