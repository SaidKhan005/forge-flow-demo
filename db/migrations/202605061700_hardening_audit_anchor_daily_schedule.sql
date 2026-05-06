-- Hardening / Wave B3 — daily pg_cron tick for the audit-anchor sweep.
--
-- Origin: `docs/_execution/2026-05-05_v1_launch_punchlist.md` §5
-- "Daily Azure Blob audit-anchor cron". The Phase 9.0Σ.f hash-chained
-- audit_logs slice (`202604280005_phase_9_0sigma_f_audit_logs.sql`)
-- created `public.audit_chain_anchors`; the Cloud Run job
-- `forge-flow-audit-anchor` (`tool/audit_anchor/main.dart` +
-- `runbooks/audit_anchor_cloudrun_deploy_runbook.md`) is the
-- production executor that walks each `(operator_id, chain_date)`
-- chain, writes the immutable Azure Blob, and inserts the matching
-- `audit_chain_anchors` row.
--
-- Status entering this slice (per the punchlist + B43 in
-- `phase_9_execution_backlog.md`): the Cloud Run Job is deployed on
-- staging and was exercised once via `gcloud run jobs execute` on
-- 2026-05-03; the matching Cloud Scheduler trigger
-- `forge-flow-audit-anchor-daily` (23:55 Etc/UTC) is created but
-- **paused**. There is no continuous in-DB schedule of the daily
-- anchor cadence yet — only the manually-fired Cloud Run executions.
--
-- This migration adds a small `pg_cron` NOTIFY-only kickoff so the
-- daily anchor cadence is observable from inside Postgres
-- (`cron.job_run_details`) regardless of whether Cloud Scheduler is
-- paused/resumed/region-failed. The pattern mirrors
-- `public.rollup_run_hot_path()` / `public.rollup_run_cold_path()`
-- from the prior batch's
-- `202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql`: the SQL
-- function NEVER does the anchor work itself (anchoring requires
-- Azure Blob writes via WIF, which Postgres has no business
-- attempting), it only `pg_notify`s an `audit_anchor_tick` envelope.
-- A future Dart subscriber can listen on the channel and trigger the
-- Cloud Run anchor sweep independently of Cloud Scheduler; until
-- that subscriber lands, the row in `cron.job_run_details` is the
-- evidence-of-tick that operators read for "did the daily cadence
-- fire today".
--
-- Anchor function behavior is UNCHANGED. The Cloud Run binary at
-- `tool/audit_anchor/main.dart` and its Azure Blob client at
-- `tool/audit_anchor/azure_blob_client.dart` are out of scope here;
-- this slice only adds the in-DB cron tick that wraps them with a
-- pg_cron-owned daily cadence.
--
-- Authority:
--   * `docs/_execution/2026-05-05_v1_launch_punchlist.md` §5
--   * `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
--     (RLS-ready schema, tenant-leading index discipline; this slice
--     adds neither a table nor an index, so the rules apply only by
--     reference — no new operator-scoped surfaces.)
--   * `docs/phases/phase_9/phase_9_execution_backlog.md` (B43 audit
--     anchor deploy)
--   * `runbooks/phase_9_production1_migration_apply_runbook.md`
--     (next-batch pending follow-up scope + apply order)
--
-- Hard rules carried from CLAUDE.md and the prior batch:
--
--   1. **Tenant-leading discipline.** This is a maintenance job;
--      cron rows have no `operator_id`. The kickoff function does
--      not read or write any operator-scoped table, so the
--      tenant-leading-index rule does not bind. The actual anchor
--      sweep is owned by the Cloud Run binary, which authenticates
--      with `forge_admin` BYPASSRLS for cross-operator reads.
--
--   2. **Replay-safe.** `cron.schedule(jobname, …)` raises
--      `unique_violation` on a duplicate jobname. The DO block
--      below removes any existing job by jobid first, then
--      reschedules. Re-running this migration on a host where the
--      schedule already exists is a clean no-op.
--
--   3. **Azure pg_cron split-DB topology.** Azure DB Flexible Server
--      keeps pg_cron metadata in the database named by
--      `cron.database_name` (currently `postgres` on
--      staging + Production1). The DO block emits a NOTICE and
--      returns when pg_cron metadata is not in this database; the
--      runbook captures the manual `cron.schedule_in_database(...,
--      'forgeflow')` follow-up step. Pattern matches the rollup
--      hot/cold path migration byte-for-byte.
--
--   4. **NOTIFY-only kickoff.** The function MUST NOT attempt the
--      actual anchor work. Postgres has no Azure WIF client and no
--      `pg_net`-style HTTP capability; trying to anchor from inside
--      pg_cron would either silently fail or require granting the
--      database network egress it currently does not have. The
--      function is deliberately one-statement (`pg_notify`) so the
--      cost of a daily fire is negligible.
--
--   5. **Job naming.** `forge_audit_anchor_daily` follows the
--      existing `forge_rollup_hot_path` / `forge_rollup_cold_path`
--      naming convention from the prior batch.
--
--   6. **Schedule choice.** `'0 2 * * *'` = 02:00 Etc/UTC daily.
--      Two hours past midnight UTC gives the previous-UTC-day chain
--      a settled buffer (the chain rolls at 00:00 UTC because
--      `audit_logs.chain_date = (occurred_at AT TIME ZONE 'UTC')
--      ::date`). The Cloud Scheduler trigger fires at 23:55 UTC
--      and anchors the previous UTC day; this in-DB tick at 02:00
--      UTC is intentionally staggered so the two cadences do not
--      collide if both end up driving the Cloud Run binary in
--      future. 02:00 UTC corresponds to 21:00 ET / 18:00 PT prior
--      day — restaurants are still open in the West, but the
--      kickoff is NOTIFY-only so it does not contend on any live
--      facts.
--
--   7. **No new tables, no new RLS, no new grants.** The function
--      is granted to `forge_admin` only; runtime `service_role`
--      has no business firing the audit-anchor cadence on its own.
--
-- Verification SQL operators can run post-apply:
--
--   -- 1. Function exists in the app database.
--   select pg_get_functiondef(p.oid)
--     from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname = 'audit_anchor_run_daily';
--
--   -- 2. Cron job exists with the expected schedule (run from
--   --    the postgres maintenance database on Azure):
--   select jobname, schedule, active, command
--     from cron.job
--    where jobname = 'forge_audit_anchor_daily';
--   -- expected: '0 2 * * *', active = true,
--   --           command = 'select public.audit_anchor_run_daily();'
--
--   -- 3. NOTIFY envelope shape (sanity check; LISTEN in another
--   --    session before running):
--   select public.audit_anchor_run_daily();
--   -- expected: notification on channel 'audit_anchor_tick' with
--   --           payload like {"fired_at": "...", "source": "pg_cron"}
--
--   -- 4. Recent run history (after the first daily fire):
--   select start_time, status, return_message
--     from cron.job_run_details
--    where jobid = (
--      select jobid from cron.job
--       where jobname = 'forge_audit_anchor_daily'
--    )
--    order by start_time desc
--    limit 5;
--
-- Live apply status: code-ready 2026-05-06; staging apply pending
-- under the Live-Mutation Gate of
-- `runbooks/phase_9_production1_migration_apply_runbook.md`.

begin;

-- ─── Function: audit_anchor_run_daily ──────────────────────────────
--
-- Cron-callable wake-up signal for the daily audit-anchor cadence.
-- NOTIFY-only — see "Hard rule #4" above for why this function
-- never attempts the anchor work itself.
--
-- The envelope keys (`source`, `fired_at`) match the contract a
-- future Dart subscriber will read. Adding new keys is non-
-- breaking; renaming or removing them needs a paired subscriber
-- update once the listener exists.
--
-- Idempotent: re-firing only emits another notification. NOTIFY is
-- best-effort and dropping duplicates is the subscriber's job.

create or replace function public.audit_anchor_run_daily()
returns void
language plpgsql
as $$
begin
  perform pg_notify(
    'audit_anchor_tick',
    json_build_object(
      'source', 'pg_cron',
      'fired_at', now()
    )::text
  );
end;
$$;

comment on function public.audit_anchor_run_daily() is
  'Hardening / Wave B3 (punchlist §5) — cron-callable wake-up '
  'signal for the daily audit-anchor cadence. Emits '
  'pg_notify(''audit_anchor_tick'', …) only; the actual anchor '
  'sweep is performed by the Cloud Run binary at '
  'tool/audit_anchor/main.dart, which writes the immutable Azure '
  'Blob and inserts the matching audit_chain_anchors row. This '
  'function MUST NOT attempt the anchor work itself — Postgres '
  'has no Azure WIF client. The pg_cron tick exists so the daily '
  'cadence is observable from inside Postgres '
  '(cron.job_run_details) regardless of Cloud Scheduler state.';

revoke execute on function public.audit_anchor_run_daily() from public;
grant execute on function public.audit_anchor_run_daily() to forge_admin;

-- ─── Schedule registration (idempotent) ────────────────────────────
--
-- `cron.schedule(jobname, schedule, command)` raises
-- `unique_violation` on a duplicate jobname. The DO block below
-- unschedules-then-reschedules so re-running this migration is a
-- clean no-op rather than a hard error.
--
-- Azure DB Flexible Server keeps pg_cron metadata in the database
-- named by `cron.database_name` (currently `postgres` on staging
-- and Production1). When pg_cron metadata is not in this database,
-- the DO block emits a NOTICE and returns; the runbook captures
-- the manual `cron.schedule_in_database(..., 'forgeflow')`
-- follow-up step. Pattern matches
-- `202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql` byte-for-byte.

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
     where jobname = 'forge_audit_anchor_daily'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'forge_audit_anchor_daily',
    '0 2 * * *',
    'select public.audit_anchor_run_daily();'
  );
end$$;

commit;
