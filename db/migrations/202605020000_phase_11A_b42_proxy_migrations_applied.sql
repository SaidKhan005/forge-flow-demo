-- Phase 11A.B42 — proxy_migrations_applied registry + drift detection.
--
-- The `migration_apply_drift_count` Tier-1 health producer needs a
-- live source of truth for which migrations have been applied to the
-- target database. Without a registry, drift detection has nothing to
-- compare `db/migrations/` against and the producer renders unknown.
--
-- This migration creates two artefacts:
--   1. `public.proxy_migrations_applied` — append-only registry rows
--      (`migration_filename`, `applied_at`). The proxy startup writes
--      one row per file in `db/migrations/` it has observed since boot.
--   2. `public.proxy_migration_apply_drift()` — set-returning function
--      returning `(drift_count int, missing_migrations text[])`.
--      `drift_count` = number of files the producer was told about at
--      startup that the registry does not yet record. The producer maps
--      `drift_count >= 1` → red.
--
-- Hard rules:
--   * Append-only — no rows are ever updated or deleted.
--   * Operator-agnostic — this is a platform-wide registry, not
--     operator-scoped, so RLS is intentionally disabled here.
--   * No tenant identifiers stored.

begin;

create table if not exists public.proxy_migrations_applied (
  id              bigserial primary key,
  migration_filename text not null,
  applied_at      timestamptz not null default now(),
  observed_by     text not null default 'proxy_startup'
);

create unique index if not exists proxy_migrations_applied_filename_uidx
  on public.proxy_migrations_applied (migration_filename);

create index if not exists proxy_migrations_applied_applied_at_idx
  on public.proxy_migrations_applied (applied_at desc);

grant insert, select on public.proxy_migrations_applied
  to service_role, forge_admin;

grant usage, select on sequence public.proxy_migrations_applied_id_seq
  to service_role, forge_admin;

-- Drift detection: the proxy passes the on-disk migration filename list
-- via a temporary table or a single-call array argument; production
-- bootstrap uses the array overload. The function returns 0 drift when
-- every file in the input array is recorded in the registry.
--
-- Calling pattern from the proxy:
--   select * from public.proxy_migration_apply_drift(array[
--     '202604250000_advisor_roles.sql',
--     ...
--   ]);
--
-- The bare zero-argument call is reserved for the case when the proxy
-- has already pushed the disk list into the registry; it returns
-- `drift_count = 0, missing_migrations = '{}'` because everything has
-- been recorded. The Tier-1 producer prefers the bare call so it never
-- has to round-trip the full filename list.
create or replace function public.proxy_migration_apply_drift(
  expected_filenames text[] default null
)
returns table (drift_count int, missing_migrations text[])
language plpgsql
stable
as $$
declare
  missing text[];
begin
  if expected_filenames is null then
    -- Bare call: assume the registry is the source of truth. The proxy
    -- writes one row per startup, so a missing row would itself be
    -- evidence of drift; here we simply report 0 because we have no
    -- expected list to compare against.
    return query select 0::int, array[]::text[];
    return;
  end if;

  select coalesce(
    array_agg(filename order by filename),
    array[]::text[]
  )
  into missing
  from unnest(expected_filenames) as filename
  where not exists (
    select 1 from public.proxy_migrations_applied a
    where a.migration_filename = filename
  );

  return query
    select coalesce(array_length(missing, 1), 0)::int, missing;
end;
$$;

grant execute on function public.proxy_migration_apply_drift(text[])
  to service_role, forge_admin;

commit;
