-- Phase 11A health AGE rebuild runtime DML grants (Graph F3).
--
-- Complements 202605021710_phase_11A_health_age_runtime_grants.sql.
--
-- That earlier migration granted the proxy runtime role `forge_admin`
-- only `usage` + `select` on the `forgeflow` Apache AGE graph schema --
-- exactly enough for the strict /health probe, which runs a read-only
-- cypher MATCH. The G5a rebuild route (POST /v1/admin/age/rebuild ->
-- RepositoryAgeRebuildGateway in tool/advisor_proxy/proxy_bootstrap.dart)
-- needs more: it delete-and-reprojects the operator's approved canonical
-- graph into the `forgeflow` graph via cypher DETACH DELETE + MERGE, which
-- is data-modifying. With select-only on that schema a live rebuild raises
-- a Postgres privilege error that the gateway surfaces as a typed 503
-- instead of projecting. This migration grants the minimal DML the
-- delete-and-reproject path needs, and nothing more.
--
-- Apache AGE storage model (why these specific grants):
--   * Each graph is a Postgres schema named after the graph, so the
--     `forgeflow` graph lives in a `forgeflow` schema. Vertices and edges
--     are rows in label tables inside that schema; the parent label tables
--     `forgeflow._ag_label_vertex` / `forgeflow._ag_label_edge` and the
--     graph's bootstrap objects were created by the database owner during
--     202605021700_phase_11A_health_age_graph_bootstrap.sql, so the runtime
--     role does NOT own them and needs explicit table DML to write them.
--   * A cypher MERGE against a label that does not yet exist makes AGE
--     create a new label table in the graph schema at projection time
--     (create_vlabel / create_elabel under the hood, i.e. CREATE TABLE in
--     the `forgeflow` schema). The runtime role therefore needs CREATE on
--     the schema. Label tables it creates at runtime are owned by it, so
--     it already holds full rights on those without an extra grant.
--   * Each label table has an `id` sequence that INSERT advances via
--     nextval, so the runtime role needs sequence usage/select/update on
--     the schema's sequences.
--
-- Least privilege and isolation posture:
--   * Granted to `forge_admin` ONLY. The rebuild runs exclusively through
--     TenantTransactionWrapper.runAsSystem (forge_admin); `service_role`
--     has no part in the projection, so it is intentionally not granted
--     here.
--   * No superuser, no ownership transfer, no broad `ALL PRIVILEGES`. The
--     table grant is the explicit INSERT/UPDATE/DELETE/SELECT set the
--     delete-and-reproject needs (no TRUNCATE / REFERENCES / TRIGGER); the
--     schema grant adds only CREATE on top of the usage it already has.
--   * Scoped to the `forgeflow` AGE graph schema and `ag_catalog` only.
--     It does NOT touch the canonical source tables `public.graph_nodes` /
--     `public.graph_edges` and therefore does not weaken their RLS in any
--     way. Per-operator isolation (HP#4) for the AGE projection is enforced
--     by G5a stamping `operator_id` on every projected vertex/edge and
--     scoping its DETACH DELETE by `operator_id` (a row-level filter in the
--     projection code), NOT by a per-operator schema -- AGE keeps one
--     shared graph schema, so this schema-level grant cannot widen the
--     tenant boundary the projection enforces in code.
--   * Re-runnable: standard GRANT / ALTER DEFAULT PRIVILEGES are
--     idempotent, and the whole block is guarded on the role and schema
--     existing so it is a no-op where either is absent (e.g. a local SQLite
--     demo clone or a Postgres instance without the graph bootstrapped).

begin;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'forge_admin') then
    -- ag_catalog: the health grant already gave usage + execute here; the
    -- rebuild also reads AGE's catalog tables (e.g. ag_label) while building
    -- and validating cypher, so ensure read access on the catalog tables.
    execute 'grant usage on schema ag_catalog to forge_admin';
    execute 'grant select on all tables in schema ag_catalog to forge_admin';

    if exists (select 1 from pg_namespace where nspname = 'forgeflow') then
      -- CREATE lets a MERGE against a not-yet-seen label create its label
      -- table at projection time; usage is re-affirmed so this migration is
      -- self-contained (it is the same usage the health grant already set).
      execute 'grant usage, create on schema forgeflow to forge_admin';

      -- DML on the existing label tables (including the owner-created
      -- _ag_label_vertex / _ag_label_edge parents) so DETACH DELETE + MERGE
      -- can write them. Explicit verbs only -- no TRUNCATE/REFERENCES/TRIGGER.
      execute 'grant select, insert, update, delete '
              'on all tables in schema forgeflow to forge_admin';

      -- Label-table id sequences: INSERT advances them via nextval.
      execute 'grant usage, select, update '
              'on all sequences in schema forgeflow to forge_admin';

      -- Future label tables/sequences the owner role creates in this schema
      -- (e.g. a later bootstrap that pre-creates labels) inherit the same
      -- minimal DML automatically. Label tables created at runtime by
      -- forge_admin are owned by forge_admin and need no default privilege.
      execute 'alter default privileges in schema forgeflow '
              'grant select, insert, update, delete on tables to forge_admin';
      execute 'alter default privileges in schema forgeflow '
              'grant usage, select, update on sequences to forge_admin';
    end if;
  end if;
end
$$;

commit;
