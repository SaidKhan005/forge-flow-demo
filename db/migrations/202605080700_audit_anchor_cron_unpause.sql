-- Code-Health Lane M3 / L9 — unpause the forge_audit_anchor_daily cron job.
--
-- Context:
--   Migration `202605061700_hardening_audit_anchor_daily_schedule.sql`
--   registered the `forge_audit_anchor_daily` pg_cron job with schedule
--   `'0 2 * * *'` and `active = true`. However the Cloud Scheduler
--   trigger `forge-flow-audit-anchor-daily` was left PAUSED (per the
--   punchlist §5 note in `docs/_execution/2026-05-05_v1_launch_punchlist.md`).
--   Code-Health Lane L9 wires the advisory lock guard and the Azure Blob
--   daily write in the Cloud Run binary; this migration ensures the
--   in-DB pg_cron job is active and on the expected schedule so the
--   daily cadence is verifiable from inside Postgres
--   (`cron.job_run_details`) regardless of Cloud Scheduler state.
--
-- Azure DB Flexible Server note:
--   Azure DB Flexible Server does NOT expose `cron.alter_job()` — the
--   extension ships without that helper. The only supported mutation
--   path is a direct UPDATE on `cron.job` (table-level write) inside
--   the cron database. This migration does a direct UPDATE; the guard
--   first checks that the table exists in this database.
--
-- Replay-safe:
--   The DO block checks whether `cron.job` is present and whether the
--   target row exists before touching anything. Re-running on a host
--   where it has already applied is a clean no-op (the UPDATE is
--   idempotent). A NOTICE is raised instead of an ERROR when pg_cron
--   metadata is not in this database so the migration does not block
--   batch application on the app database (Azure keeps pg_cron metadata
--   in the database named by `cron.database_name`, typically `postgres`).
--
-- Authority:
--   * `docs/_execution/2026-05-05_v1_launch_punchlist.md` §5
--   * `db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql`
--     (the original schedule registration that left active=true; this
--     migration is a belt-and-suspenders unpause for the code-lane
--     graduation).
--   * `CODE_HEALTH.md` — "Audit-anchor cadence is paused" finding.
--
-- Verification SQL (run in the cron database, typically `postgres`):
--
--   select jobname, schedule, active, command
--     from cron.job
--    where jobname = 'forge_audit_anchor_daily';
--   -- expected: schedule = '0 2 * * *', active = true

begin;

do $$
declare
  v_rows int;
begin
  -- Guard 1: pg_cron schema not present in this database.
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; '
      'connect to the cron database (cron.database_name) and re-run, '
      'or use cron.schedule_in_database(''forge_audit_anchor_daily'', '
      '''forgeflow'') to register there. Skipping unpause.';
    return;
  end if;

  -- Guard 2: job row does not exist yet (e.g. migration applied out
  -- of order or cron database is fresh). Emit a NOTICE rather than
  -- silently doing nothing.
  select count(*)
    into v_rows
    from cron.job
   where jobname = 'forge_audit_anchor_daily';

  if v_rows = 0 then
    raise notice
      'forge_audit_anchor_daily job not found in cron.job; '
      'apply 202605061700_hardening_audit_anchor_daily_schedule.sql '
      'first, then re-run this migration.';
    return;
  end if;

  -- Idempotent UPDATE: set the canonical schedule and mark active.
  -- Azure DB Flexible Server does not expose cron.alter_job(), so a
  -- direct UPDATE on cron.job is the only supported mutation path.
  update cron.job
     set schedule = '0 2 * * *',
         active   = true
   where jobname = 'forge_audit_anchor_daily';

  raise notice
    'forge_audit_anchor_daily: schedule set to ''0 2 * * *'', '
    'active = true.';
end;
$$;

commit;
