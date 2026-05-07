-- Code-Health Lane M3 / L9 — unpause the daily audit-anchor pg_cron job.
--
-- Context:
--   `db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql`
--   created the `forge_audit_anchor_daily` pg_cron job in a NOTIFY-only
--   mode but intentionally left its schedule / active state in whatever
--   state `cron.schedule()` sets (Azure DB Flexible Server enables new
--   jobs by default, but the Cloud Scheduler trigger
--   `forge-flow-audit-anchor-daily` was paused and a follow-up note was
--   recorded to resume both cadences under code lane L9).
--
--   `db/migrations/202605070200_audit_anchor_advisory_lock_infra.sql`
--   wired the advisory-lock infra and breadcrumb columns. L9 code-lane
--   wired the advisory lock + rollforward path in the Cloud Run binary.
--   This migration is the final L9 step: resume the in-DB pg_cron tick
--   so `cron.job_run_details` reflects daily firings going forward.
--
-- This migration only acts on the existing job. It does NOT re-create the
-- job if it is absent (that is the prior migration's responsibility).
-- Re-running this migration on a host where it has already applied is a
-- clean no-op (the DO block is guarded by IF EXISTS).
--
-- Authority:
--   * `CODE_HEALTH.md` — "Audit-anchor cadence is paused"
--   * `db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql`
--     (job creation)
--   * `db/migrations/202605070200_audit_anchor_advisory_lock_infra.sql`
--     (advisory-lock infra this unpause enables safely)
--   * `runbooks/audit_chain_verify_runbook.md` §Daily anchor procedure
--
-- Azure DB Flexible Server pg_cron topology note:
--   pg_cron metadata lives in the database named by `cron.database_name`
--   (typically `postgres` on staging + Production1). The DO block below
--   emits a NOTICE and returns when pg_cron metadata is not in this
--   database; the runbook captures the manual follow-up step if needed.
--   Pattern matches `202605061700_hardening_audit_anchor_daily_schedule.sql`
--   byte-for-byte.

begin;

do $$
begin
  -- Guard: pg_cron metadata must be in this database.
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; resume the job from '
      'the cron.database_name database with: UPDATE cron.job '
      'SET active = TRUE WHERE jobname = ''forge_audit_anchor_daily'';';
    return;
  end if;

  -- Guard: job must exist (created by the prior migration).
  if not exists (
    select 1 from cron.job
     where jobname = 'forge_audit_anchor_daily'
  ) then
    raise notice
      'forge_audit_anchor_daily does not exist in cron.job; '
      'apply 202605061700_hardening_audit_anchor_daily_schedule.sql first.';
    return;
  end if;

  -- Ensure the schedule is exactly ''0 2 * * *'' and the job is active.
  -- Using a direct UPDATE on cron.job (Azure DB Flexible Server does not
  -- expose cron.alter_job; the portable pattern used by the prior
  -- migration batch is direct DML on cron.job inside a migration DO block
  -- protected by the Live-Mutation Gate in the apply runbook).
  update cron.job
     set schedule = '0 2 * * *',
         active   = true
   where jobname = 'forge_audit_anchor_daily';

  raise notice
    'forge_audit_anchor_daily: schedule set to ''0 2 * * *'' and '
    'active = true.';
end
$$;

commit;
