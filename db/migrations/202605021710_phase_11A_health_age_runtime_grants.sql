-- Phase 11A health AGE runtime grants.
--
-- The proxy health runner executes dependency probes through
-- TenantTransactionWrapper.runAsSystem, which assumes the runtime
-- Postgres role `forge_admin`. Apache AGE keeps its functions/types in
-- ag_catalog and graph label tables in the graph-named schema. Creating the
-- extension/graph as the database owner is not enough for that runtime role:
-- it still needs explicit schema/function/table privileges before a strict
-- cypher MATCH can prove the graph path is healthy.

begin;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'forge_admin') then
    execute 'grant usage on schema ag_catalog to forge_admin';
    execute 'grant execute on all functions in schema ag_catalog to forge_admin';

    if exists (select 1 from pg_namespace where nspname = 'forgeflow') then
      execute 'grant usage on schema forgeflow to forge_admin';
      execute 'grant select on all tables in schema forgeflow to forge_admin';
    end if;
  end if;
end
$$;

commit;
