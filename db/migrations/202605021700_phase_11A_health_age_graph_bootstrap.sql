-- Phase 11A health AGE graph bootstrap.
--
-- The strict /health AGE probe executes a real cypher MATCH against the
-- canonical graph name. An empty graph is healthy, but a missing graph is
-- schema/config drift. Keep the graph namespace present even before corpus
-- projection has materialized vertices or edges.

begin;

create extension if not exists age;

do $$
begin
  perform set_config('search_path', 'ag_catalog,"$user",public', false);

  if not exists (
    select 1
    from ag_catalog.ag_graph
    where name = 'forgeflow'
  ) then
    perform ag_catalog.create_graph('forgeflow');
  end if;
end
$$;

commit;
