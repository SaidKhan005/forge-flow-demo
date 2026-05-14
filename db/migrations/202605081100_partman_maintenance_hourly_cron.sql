-- CODE_OPS_DEBT — Theme C #6 — register the hourly partman_maintenance
-- pg_cron job.
--
-- Context:
--   `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql` set up
--   `pg_partman` daily range partitioning on `public.audit_logs` and
--   noted in a comment that the maintenance call should run hourly via
--   `cron.schedule('partman_maintenance', '0 * * * *',
--   $$SELECT public.run_maintenance(p_analyze := true)$$)`. The
--   schedule was never registered. Without it `audit_logs` partitions
--   stop being created ahead of the producer (the `daily premake` of 7
--   buffers a week, but eventually exhausts) and detached partitions
--   never get pruned.
--
-- Azure DB Flexible Server topology:
--   Azure keeps `pg_cron` metadata in the database named by
--   `cron.database_name` (typically `postgres`). Application databases
--   call `cron.schedule_in_database(...)` to register from outside the
--   metadata database, OR the migration runs INSIDE the cron database.
--   This migration is split-safe: a `to_regnamespace('cron') is null`
--   guard at the top emits a NOTICE and exits cleanly when applied to
--   a database without the cron schema, so the same SQL ships against
--   every environment without environment-specific hand-edits.
--
-- Replay-safe:
--   The DO block deletes any pre-existing job with the same name before
--   inserting the new schedule, so re-running the migration is
--   idempotent. The schedule is fixed at `0 * * * *` (top of every
--   hour) — the comment in 202604280005 pinned the cadence and the
--   constants in `phase_9_scalability_decisions_2026-04-27.md` lock it.
--
-- Authority:
--   * `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`:38-46
--     (the original TODO comment)
--   * `CODE_OPS_DEBT.md` Theme C row 6 — partman maintenance is a
--     comment-only TODO; this migration retires the row.
--   * `runbooks/admin_provider_credentials_kms_rollout_runbook.md` —
--     references `pg_partman` daily partitioning for audit_logs.
--
-- Verification SQL (run in the cron database, typically `postgres`):
--
--   select jobname, schedule, active, command
--     from cron.job
--    where jobname = 'partman_maintenance';
--   -- expected: schedule = '0 * * * *', active = true,
--   --           command = 'select public.run_maintenance(p_analyze := true);'

begin;

-- B-W2 fix (2026-05-13): outer block uses tagged dollar-quote `$partman$`
-- because the inner notice strings contain literal `$$` substrings that the
-- PG lexer matches regardless of single-quote string context. Without the
-- tag the outer `do $$` block terminates early at the first inner `$$`,
-- raising "syntax error at or near 'select'" the moment the migration runs.
-- Single-character edit per POST_HARDENING_FOLLOWUPS W-2; no behavioral
-- change.
do $partman$
declare
  v_existing int;
  v_jobid    bigint;
begin
  -- Guard 1: pg_cron schema not present in this database. Azure
  -- Flexible Server keeps the metadata in the cron database; the
  -- batch migration runner sees a NOTICE and moves on.
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; '
      'connect to the cron database (cron.database_name) and re-run, '
      'or use cron.schedule_in_database(''partman_maintenance'', '
      '''0 * * * *'', '
      '$$select public.run_maintenance(p_analyze := true)$$, '
      '''forgeflow''). Skipping.';
    return;
  end if;

  -- Idempotent rebuild: delete any prior row with the same name so
  -- a schedule change in a follow-up migration is also picked up.
  -- Azure Flexible Server does not expose `cron.alter_job()`; the
  -- only supported mutation path is INSERT-after-DELETE on
  -- `cron.job`, which is what `cron.schedule()` does internally.
  select count(*)
    into v_existing
    from cron.job
   where jobname = 'partman_maintenance';

  if v_existing > 0 then
    delete from cron.job where jobname = 'partman_maintenance';
    raise notice
      'partman_maintenance: removed % pre-existing cron.job row(s) '
      'before re-registering.', v_existing;
  end if;

  -- Register the hourly maintenance call. `cron.schedule()` returns
  -- the new jobid; we capture it for the NOTICE so deploy verification
  -- can grep the apply log for the registered jobid.
  v_jobid := cron.schedule(
    'partman_maintenance',
    '0 * * * *',
    'select public.run_maintenance(p_analyze := true);'
  );

  -- Make sure the row is active (cron.schedule() defaults to active=true,
  -- but mirroring the audit_anchor unpause's belt-and-suspenders posture).
  update cron.job
     set active = true
   where jobname = 'partman_maintenance';

  raise notice
    'partman_maintenance: registered jobid=%, schedule=''0 * * * *'', '
    'command=run_maintenance(p_analyze := true)', v_jobid;
end;
$partman$;

commit;
