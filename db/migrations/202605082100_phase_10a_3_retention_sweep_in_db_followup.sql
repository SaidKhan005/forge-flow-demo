-- Phase 10a.3 — bounded retention sweep, Azure split-DB schedule
-- follow-up.
--
-- Context:
--   `db/migrations/202605050200_phase_10a_3_event_outbox_retention.sql`
--   shipped the original unbounded `event_outbox_retention_sweep()`
--   function and a daily 09:00 UTC `forge_event_outbox_retention_sweep`
--   cron entry; `db/migrations/202605051000_phase_10a_3_outbox_retention_sweep.sql`
--   layered the bounded `run_event_outbox_retention_sweep()` function
--   plus a 03:00 UTC `event_outbox_retention_sweep_daily` cron entry
--   on top.
--
--   Both prior schedule blocks gracefully bow out with a NOTICE when
--   the migration runs against a database that does not host the
--   pg_cron metadata. Azure DB Flexible Server pins pg_cron metadata
--   to the database named in `cron.database_name` (typically
--   `postgres`); the application schema (`forgeflow`) is a different
--   database, so on Azure those NOTICEs were the live-apply outcome
--   and the schedules were never registered. The bounded sweep
--   relied on an out-of-band manual step that was easy to miss.
--
-- What this migration does:
--   1. From the `cron.database_name` (where pg_cron lives), DELETE
--      any prior `forge_event_outbox_retention_sweep` row (the
--      legacy unbounded daily cron from the first migration). The
--      bounded path supersedes it; leaving both around would cause
--      two writers fighting for the same delivered-rows window.
--   2. Then DELETE-then-INSERT the bounded
--      `event_outbox_retention_sweep_daily` schedule via
--      `cron.schedule_in_database('event_outbox_retention_sweep_daily',
--      '0 3 * * *', '...', 'forgeflow')` so the sweep call runs in
--      the application database where the function lives.
--
-- Idempotent. Re-running this migration deletes the rows again, then
-- re-INSERTs the bounded entry.
--
-- Topology guards:
--   * pg_cron in this DB → run the DELETE-then-INSERT here.
--   * pg_cron in a different DB → emit a NOTICE (the migration is
--     intended to be applied from the cron database; the
--     `forgeflow` application database does not host the metadata).
--
-- Why "_in_database":
--   `cron.schedule()` queues the command against the same database
--   as the caller, which would route the SELECT into the metadata
--   database where `public.run_event_outbox_retention_sweep()` does
--   not exist. `cron.schedule_in_database(jobname, schedule,
--   command, database)` pins the per-tick connection to the named
--   database so the function call resolves correctly.
--
-- Hard rules carried from CLAUDE.md and the contract:
--
--   1. The bounded sweep MUST NOT touch un-delivered rows; this
--      migration only changes how the schedule is registered, not
--      what runs. The bounded function from
--      `202605051000_phase_10a_3_outbox_retention_sweep.sql` keeps
--      the predicate.
--
--   2. The schedule cadence stays `0 3 * * *` per the prior
--      migration. Changing it requires a paired update there.
--
--   3. The DELETE leg is bounded by `jobname` so the migration cannot
--      accidentally evict an unrelated job.
--
-- Live apply:
--   Apply against the database named in `cron.database_name` (Azure:
--   typically `postgres`). The migration emits NOTICEs that the
--   deploy verification log can grep for to confirm the legacy
--   schedule was removed and the bounded schedule was re-registered
--   under `cron.schedule_in_database`.
--
-- Authority:
--   * `db/migrations/202605050200_phase_10a_3_event_outbox_retention.sql`
--     — function `public.event_outbox_retention_sweep` + the
--     legacy unbounded daily schedule.
--   * `db/migrations/202605051000_phase_10a_3_outbox_retention_sweep.sql`
--     — function `public.run_event_outbox_retention_sweep` + the
--     bounded 03:00 UTC schedule (in-database NOTICE only on Azure).
--   * `docs/contracts/event_outbox_contract.md` — Retention.

begin;

do $$
declare
  v_legacy_removed int := 0;
  v_bounded_existing int := 0;
  v_bounded_jobid bigint;
begin
  -- Topology guard: pg_cron metadata MUST live in this database.
  -- When applied against the application database on Azure, the
  -- guard fires and the migration prints the manual command that
  -- replays the same intent from the cron database.
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; '
      'connect to the cron database (cron.database_name; typically '
      'postgres on Azure) and re-run this migration so the legacy '
      '''forge_event_outbox_retention_sweep'' row is removed and the '
      'bounded ''event_outbox_retention_sweep_daily'' schedule is '
      're-registered via cron.schedule_in_database(..., ''forgeflow''). '
      'Skipping.';
    return;
  end if;

  -- 1. Drop the legacy unbounded daily cron from the original
  --    202605050200 migration. The bounded path supersedes it; running
  --    both would have two cron passes contending on the same
  --    delivered-rows window.
  select count(*)
    into v_legacy_removed
    from cron.job
   where jobname = 'forge_event_outbox_retention_sweep';

  if v_legacy_removed > 0 then
    delete from cron.job where jobname = 'forge_event_outbox_retention_sweep';
    raise notice
      'event_outbox_retention_sweep: removed % legacy '
      '''forge_event_outbox_retention_sweep'' cron.job row(s).',
      v_legacy_removed;
  end if;

  -- 2. Idempotent rebuild of the bounded schedule. DELETE-then-INSERT
  --    so a re-apply lands the latest cadence + command. The schedule
  --    pins the application database (`forgeflow`) so the per-tick
  --    connection resolves `public.run_event_outbox_retention_sweep()`
  --    (the function lives in the application database, not the
  --    cron metadata database).
  select count(*)
    into v_bounded_existing
    from cron.job
   where jobname = 'event_outbox_retention_sweep_daily';

  if v_bounded_existing > 0 then
    delete from cron.job where jobname = 'event_outbox_retention_sweep_daily';
    raise notice
      'event_outbox_retention_sweep: removed % pre-existing '
      '''event_outbox_retention_sweep_daily'' cron.job row(s) before '
      're-registering via cron.schedule_in_database.',
      v_bounded_existing;
  end if;

  v_bounded_jobid := cron.schedule_in_database(
    'event_outbox_retention_sweep_daily',
    '0 3 * * *',
    'select public.run_event_outbox_retention_sweep();',
    'forgeflow'
  );

  update cron.job
     set active = true
   where jobname = 'event_outbox_retention_sweep_daily';

  raise notice
    'event_outbox_retention_sweep: registered jobid=%, schedule=''0 3 * * *'', '
    'database=forgeflow, command=run_event_outbox_retention_sweep()',
    v_bounded_jobid;
end;
$$;

commit;
