-- Lane: code-health.biz-date-sec
-- CODE_HEALTH ref:
--   "phase_8_set_business_date() is SECURITY DEFINER owned by
--    forge_admin, granted EXECUTE to service_role. SQL-injection on
--    the proxy that lands a row insert hits BYPASSRLS context as a
--    side effect."
--
-- Posture chosen: KEEP `SECURITY DEFINER` + owner `forge_admin`
-- (Strategy B), and tighten the blast radius by:
--
--   1. REVOKE EXECUTE FROM service_role. Postgres invokes trigger
--      functions internally under the function's own privileges
--      (SECURITY DEFINER) — no application caller needs EXECUTE.
--      The previous GRANT TO service_role was an over-grant: it let
--      service_role (or anything that could land calls as
--      service_role, e.g. SQL injection on the proxy) invoke the
--      function directly outside trigger context, where the
--      forge_admin (BYPASSRLS) elevation has no legitimate purpose.
--      Trigger-context invocations continue to work because
--      forge_admin (the function owner) retains EXECUTE.
--
--   2. Defense-in-depth input validation. tg_argv[0] is hardcoded
--      in the per-table CREATE TRIGGER statements ('occurred_at' /
--      'detected_at') and Postgres does not expose a path for
--      callers to override it. Validate anyway: reject anything
--      outside the small allowlist so a future trigger-creation
--      mistake fails fast and obvious. Validate the projected
--      timestamp text via an explicit cast in a sub-block so a
--      malformed value raises with a clear message rather than
--      propagating an opaque cast error.
--
--   3. search_path is already locked (`SET search_path = public,
--      pg_catalog`) in the original migration; preserved here so
--      session-level search_path mutations cannot redirect the
--      `public.locations` lookup.
--
-- Why NOT Strategy A (SECURITY INVOKER):
--   * The function reads `public.locations`, which is RLS-enabled.
--     Inserts arrive on connector_sync_log / inbound_webhook_dead_letter
--     / sanity_log under varying tenant contexts (proxy session,
--     spine-bridge sink, integration sync worker). Switching to
--     INVOKER would cause the locations join to filter by the
--     current tenant context and miss the row whenever the inserter
--     is operating cross-tenant or before SET LOCAL has been
--     applied — the trigger would then take the UTC fallback path
--     on every cross-tenant insert, silently corrupting business_date
--     denorm for those rows.
--   * `test/integration/business_date_denorm_test.dart` (lines
--     222–248) explicitly asserts the function MUST be
--     SECURITY DEFINER + owned by forge_admin so the locations join
--     succeeds across tenant contexts. Strategy A would fail that
--     guard.
--
-- Idempotent: CREATE OR REPLACE FUNCTION + REVOKE-IF-GRANTED
-- semantics. Re-running the migration is a no-op.

begin;

-- ─── 1. Re-issue the function with input validation ────────────────
--
-- Body is identical to the original (db/migrations/
-- 202605050400_phase_8_business_date_denorm.sql lines 324–378) plus:
--   * tg_argv[0] allowlist check
--   * explicit timestamptz cast wrapped in a sub-block with a
--     clear error message on bad input
--
-- Owner stays forge_admin (BYPASSRLS) so the RLS-enabled
-- public.locations read continues to succeed across tenant
-- contexts. search_path stays locked.

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
  -- Defense-in-depth: tg_argv[0] is hardcoded in our CREATE TRIGGER
  -- statements (only 'occurred_at' or 'detected_at' are valid), but
  -- a future trigger-creation mistake or migration ordering bug
  -- could pass an unexpected value. Reject anything outside the
  -- allowlist so the failure is loud and obvious.
  if v_ts_col is null
     or v_ts_col not in ('occurred_at', 'detected_at') then
    raise exception
      'phase_8_set_business_date: tg_argv[0]=% is not in the '
      'allowed timestamp-column set (occurred_at, detected_at). '
      'Trigger creation is misconfigured.', coalesce(v_ts_col, '<null>');
  end if;

  if new.business_date is not null then
    return new;
  end if;

  -- Dynamic column projection. `to_jsonb(record)->>'col'` returns
  -- the column's text value with the timezone offset preserved
  -- (PG renders TIMESTAMPTZ as ISO 8601 with `+HH:MM`); the cast
  -- back to timestamptz preserves the original instant. The
  -- sub-block converts a malformed text value into a clear
  -- error rather than an opaque "invalid input syntax" leak.
  v_ts_raw := to_jsonb(new) ->> v_ts_col;
  if v_ts_raw is null then
    -- Source-truth timestamp is NULL; we cannot project. Leave
    -- business_date NULL so the NOT NULL constraint catches the
    -- malformed insert with a clear column reference.
    return new;
  end if;

  begin
    v_ts := v_ts_raw::timestamptz;
  exception when invalid_datetime_format
            or invalid_text_representation
            or datetime_field_overflow then
    raise exception
      'phase_8_set_business_date: column %.% does not contain a '
      'valid TIMESTAMPTZ (got %).',
      tg_table_name, v_ts_col, v_ts_raw;
  end;

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

-- ─── 2. Tighten EXECUTE grants ─────────────────────────────────────
--
-- The original migration granted EXECUTE to service_role so callers
-- could (in theory) invoke the function. Trigger functions are
-- invoked by Postgres internally and run under the function's own
-- privileges when SECURITY DEFINER, so no application caller needs
-- EXECUTE. Removing the service_role grant shrinks the blast radius:
-- a SQL-injection-shaped exploit landing as service_role can no
-- longer call this function directly to ride its forge_admin
-- (BYPASSRLS) context.
--
-- forge_admin retains EXECUTE because it owns the function and
-- needs to be able to call it (e.g. for direct testing under the
-- admin pool). PUBLIC remains revoked.

revoke execute on function public.phase_8_set_business_date()
  from service_role;

-- Re-assert the existing PUBLIC revoke for idempotency on fresh
-- environments where the original migration has not yet run.
revoke execute on function public.phase_8_set_business_date()
  from public;

-- forge_admin grant is preserved (no-op if already present); avoids
-- a fresh environment ending up with no executor at all.
grant execute on function public.phase_8_set_business_date()
  to forge_admin;

comment on function public.phase_8_set_business_date() is
  'Phase 8 / lane code-health.biz-date-sec: BEFORE INSERT trigger '
  'that denormalizes business_date on connector_sync_log / '
  'inbound_webhook_dead_letter / sanity_log from the source-truth '
  'TIMESTAMPTZ named in TG_ARGV[0] via the row''s location.timezone '
  '+ business_day_rollover_hour. Mirrors '
  'lib/services/integration/iana_timezone_converter.dart '
  '(toBusinessDate). Honors caller-supplied business_date (no '
  'overwrite). Honest UTC + 0-rollover fallback when '
  'locations.timezone is unresolvable. SECURITY DEFINER + owner '
  'forge_admin so the RLS-enabled locations lookup succeeds without '
  'the inserter''s tenant context. tg_argv[0] is allowlisted to '
  '(occurred_at, detected_at); EXECUTE is revoked from service_role '
  'so the function is callable only via trigger context (Postgres '
  'invokes trigger functions under their own owner''s privileges).';

commit;
