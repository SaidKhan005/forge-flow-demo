-- Phase 11a.11c.5 — Role bootstrap for generic Postgres deployments.
--
-- Existing advisor migrations (202604250001 onward) attach RLS
-- policies to two named roles: `service_role` and `authenticated`.
-- These names are conventions Supabase ships pre-created; on a generic
-- Postgres host (Azure Database for PostgreSQL, local Docker dev, or
-- bare metal) they do not exist by default, so the very first advisor
-- migration would fail at the `to service_role` / `to authenticated`
-- clauses with `role "..." does not exist`.
--
-- This migration creates them if missing, idempotently. It runs first
-- because of its `0000` lexicographic prefix, so every later advisor
-- migration finds the roles already in place. The roles are NOLOGIN
-- and carry no inherent privileges — they exist purely as RLS policy
-- targets. The deployment-specific authentication layer (Supabase
-- gateway, Azure managed identity, bespoke auth proxy) is responsible
-- for assuming the right role at request time.
--
-- Hard rules:
--   * No DDL outside role creation. No table, schema, extension, or
--     policy DDL belongs in this file — those live in their own
--     migrations so role creation can be audited independently.
--   * Idempotent. Re-running this file on an environment that already
--     has the roles is a no-op.
--   * No privilege grants. Granting USAGE / SELECT / INSERT to these
--     roles is the job of the table-owning migrations and (later)
--     Phase 9 RLS hardening, not this one.

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'service_role'
  ) then
    create role service_role nologin;
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'authenticated'
  ) then
    create role authenticated nologin;
  end if;
end
$$;
