-- Phase 9.0Σ.i — canonical graph storage (item 30 / Q19 from
-- `phase_9_scalability_decisions_2026-04-27.md`, B30 in
-- `phase_9_execution_backlog.md`).
--
-- Q19 lock: Apache AGE remains the launch graph query engine, but AGE
-- is NOT the source of truth. Canonical graph data lives in ordinary
-- Postgres `graph_nodes` and `graph_edges` tables; AGE label graphs
-- are rebuildable projections. Without canonical storage the projection
-- cannot be rebuilt without re-extracting from the source-of-truth
-- corpus, and the AGE health/tripwire surface (yellow at 3M active
-- edges, red at 4M) has nothing to count against.
--
-- Hard rules carried from CLAUDE.md and the 4-27 lock:
--   1. Operator-scoped from creation. Every fact-table row carries
--      `operator_id`; tenant-leading B-tree indexes lead with
--      `operator_id` so RLS policy evaluation folds into the index
--      probe (CLAUDE.md "RLS performance discipline").
--   2. RLS uses the wrapper functions from 9.0Σ.b
--      (`public.app_current_operator()`); bare `current_setting()`
--      is forbidden by the lint at `tool/rls_policy_lint.dart`.
--   3. `TIMESTAMPTZ` for every datetime column — naive (non-tz)
--      date-time types are banned in operator-scoped tables per the
--      CLAUDE.md storage rule.
--   4. Composite FKs to `public.locations(operator_id, location_id)`
--      reject cross-operator location pointers at the database layer.
--   5. Edge endpoints reference `public.graph_nodes` within the same
--      `(operator_id, graph_scope, graph_version)` tuple — a self-FK
--      with the composite uniqueness target below makes a
--      cross-operator or cross-version edge a database error.
--   6. No live mutation. Generated rebuild SQL (see
--      `tool/graph_projection/`) may DROP/CREATE the AGE projection
--      but must NEVER mutate `graph_nodes` or `graph_edges`.
--
-- Tripwire surface (Q19):
--   * `graph_health_metrics()` — set-returning function exposing
--     active vertex count, active edge count, yellow at 3M active
--     edges, red at 4M active edges, plus projection metadata
--     (last build / last benchmark slots reserved for the Phase 11A
--     graph health panel).
--   * Filters out soft-deleted / archived rows so the count tracks
--     "active" rows the AGE projection rebuild would replay.
--
-- This migration is local framework only — no live database mutation.
-- Live apply on staging + Production1 is queued under the Phase 9
-- live-mutation gate.

begin;

-- ─── graph_nodes ───────────────────────────────────────────────────
--
-- Canonical vertex storage. The AGE label graph is a projection of
-- this table; rebuilding the projection drops the AGE labels and
-- replays the rows from here. No row in `graph_nodes` is ever
-- mutated by the projection rebuild — that constraint is the whole
-- point of separating canonical truth from the query engine.
--
-- Stable id discipline:
--   * `id` is the canonical primary key (UUID) — used everywhere F&F
--     code refers to a node.
--   * `node_key` is a producer-supplied stable string (e.g. a corpus
--     chunk id, a workflow step name, a metric name) used to dedupe
--     re-extractions. The unique key is
--     `(operator_id, graph_scope, graph_version, node_key)` so the
--     same producer cannot accidentally insert two rows for the same
--     logical node within one scope/version.
--
-- Scope/version keys:
--   * `graph_scope` partitions canonical storage by use case (e.g.
--     `methodology`, `workflows`, `causal`). The advisor corpus seeds
--     today live under `methodology`; Phase 12 workflow automation
--     will use a separate scope without colliding ids.
--   * `graph_version` is the rebuild generation. Producers stamp a
--     version per re-extraction; old versions can be archived without
--     deleting them so a regression in the new version can be
--     reverted by re-projecting the previous version.
--
-- Confidence / source metadata:
--   * `confidence` (0.0..1.0) lets retrieval prefer high-confidence
--     edges; nullable so legacy/manual nodes that pre-date confidence
--     scoring still load.
--   * `source` is the producer name (e.g. `advisor_corpus_extract`,
--     `workflow_compiler`).
--   * `source_ref` is a producer-specific pointer (chunk id, doc id,
--     workflow id) for traceability.
--
-- Lifecycle:
--   * `active_from` / `active_to` carry the active date range. Edges
--     and nodes with `active_to <= now()` are filtered out of the
--     "active" rebuild and out of the tripwire counts.
--   * `deleted_at` is the soft-delete marker for compliance flows
--     (Q21 sensitive-info redaction). Rows with `deleted_at` set are
--     excluded from the AGE projection but kept on disk for audit.
--   * `archived_at` is the post-superseded marker for old graph
--     versions; archived rows are also excluded from active counts.

create table if not exists public.graph_nodes (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  -- Optional location scoping. Edges and nodes that are global to an
  -- operator (e.g. methodology) leave `location_id` NULL; nodes
  -- specific to a single restaurant (e.g. workflow staff coaching
  -- traces) carry the location. Composite FK below pins the value to
  -- a same-operator location so a cross-operator location pointer is
  -- a database error.
  location_id uuid null,
  graph_scope text not null
    check (char_length(graph_scope) between 1 and 64),
  graph_version text not null
    check (char_length(graph_version) between 1 and 64),
  node_key text not null
    check (char_length(node_key) between 1 and 256),
  node_type text not null
    check (char_length(node_type) between 1 and 64),
  confidence numeric(4, 3) null
    check (confidence is null or (confidence >= 0.0 and confidence <= 1.0)),
  source text null,
  source_ref text null,
  properties jsonb not null default '{}'::jsonb
    -- Properties must be a JSON object so consumers can read fields
    -- without branching. Direct service_role / forge_admin inserts
    -- that try to store array/string/number/null bodies are rejected
    -- at the DB layer per the same discipline as event_outbox.
    check (jsonb_typeof(properties) = 'object'),
  active_from timestamptz not null default now(),
  active_to timestamptz null,
  deleted_at timestamptz null,
  archived_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Composite uniqueness target so the `graph_edges` self-FK below
  -- can pin (operator_id, graph_scope, graph_version, id) and reject
  -- cross-operator / cross-scope / cross-version edges at the DB.
  unique (operator_id, graph_scope, graph_version, id),
  -- Producer dedupe target: same logical node within one scope/version
  -- collapses to one row.
  unique (operator_id, graph_scope, graph_version, node_key),
  -- Composite FK: location_id (when set) must belong to the same
  -- operator. NULL location_id passes (MATCH SIMPLE) so global
  -- nodes are accepted.
  --
  -- ON DELETE SET NULL (location_id) — Q19 says a location going away
  -- must NOT erase canonical graph history; only the location pointer
  -- is nulled, the row itself is retained for audit / re-projection
  -- of prior graph_version generations. PG15+ column-list form pins
  -- the SET NULL to `location_id` so `operator_id` (NOT NULL) is
  -- preserved on the same-operator-cascade path.
  constraint graph_nodes_location_same_operator_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete set null (location_id)
);

comment on table public.graph_nodes is
  'Phase 9.0Σ.i (item 30 / Q19) — canonical graph vertex storage. '
  'Operator-scoped, RLS-protected. AGE label graphs are rebuildable '
  'projections of this table; the projection rebuild reads from here '
  'and never mutates these rows.';

comment on column public.graph_nodes.graph_scope is
  'Q19: scope partition (e.g. methodology, workflows, causal). '
  'Different scopes can carry the same node_key without collision.';

comment on column public.graph_nodes.graph_version is
  'Q19: rebuild generation. Producers stamp a version per '
  're-extraction; previous versions can be archived without deletion '
  'so a regression in a new version can be reverted by re-projecting '
  'the prior version.';

comment on column public.graph_nodes.active_from is
  'Q19: start of active date range. The AGE projection rebuild and '
  'tripwire counts require active_from <= now() so rows staged for '
  'a future activation do NOT project early.';

comment on column public.graph_nodes.active_to is
  'Q19: end of active date range; NULL means open-ended. Rows with '
  'active_to <= now() are excluded from the active projection and '
  'tripwire counts.';

comment on column public.graph_nodes.deleted_at is
  'Q21 soft-delete marker. Rows with deleted_at set are excluded from '
  'the AGE projection but retained on disk for audit / compliance.';

comment on column public.graph_nodes.archived_at is
  'Q19 archive marker. Rows from superseded graph_version generations '
  'are archived (not deleted) so re-projection of the prior version '
  'remains possible.';

-- ─── graph_edges ───────────────────────────────────────────────────
--
-- Canonical edge storage. Edges connect two `graph_nodes` rows
-- WITHIN THE SAME (operator_id, graph_scope, graph_version) tuple —
-- the composite FKs below enforce that at the database. A cross-
-- operator or cross-scope edge is a database error, not a runtime
-- check.
--
-- `from_node_id` / `to_node_id` are UUIDs into `graph_nodes.id`. The
-- edge type is structural (e.g. `CONTAINS`, `CAUSES`, `DEPENDS_ON`);
-- semantics live in `properties`. Both endpoints participate in the
-- composite FK so one tenant cannot point an edge at another tenant's
-- node.

create table if not exists public.graph_edges (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  location_id uuid null,
  graph_scope text not null
    check (char_length(graph_scope) between 1 and 64),
  graph_version text not null
    check (char_length(graph_version) between 1 and 64),
  edge_key text not null
    check (char_length(edge_key) between 1 and 256),
  edge_type text not null
    check (char_length(edge_type) between 1 and 64),
  from_node_id uuid not null,
  to_node_id uuid not null,
  confidence numeric(4, 3) null
    check (confidence is null or (confidence >= 0.0 and confidence <= 1.0)),
  source text null,
  source_ref text null,
  properties jsonb not null default '{}'::jsonb
    check (jsonb_typeof(properties) = 'object'),
  active_from timestamptz not null default now(),
  active_to timestamptz null,
  deleted_at timestamptz null,
  archived_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Producer dedupe target.
  unique (operator_id, graph_scope, graph_version, edge_key),
  -- Same-operator location pointer. ON DELETE SET NULL (location_id)
  -- mirrors the discipline on graph_nodes — a location delete must not
  -- erase canonical edge history; only the pointer is nulled.
  constraint graph_edges_location_same_operator_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete set null (location_id),
  -- Same-(operator, scope, version) endpoint FKs. The target table is
  -- `graph_nodes`'s composite uniqueness key declared above.
  constraint graph_edges_from_node_same_scope_fk
    foreign key (operator_id, graph_scope, graph_version, from_node_id)
    references public.graph_nodes(operator_id, graph_scope, graph_version, id)
    on delete cascade,
  constraint graph_edges_to_node_same_scope_fk
    foreign key (operator_id, graph_scope, graph_version, to_node_id)
    references public.graph_nodes(operator_id, graph_scope, graph_version, id)
    on delete cascade
);

comment on table public.graph_edges is
  'Phase 9.0Σ.i (item 30 / Q19) — canonical graph edge storage. '
  'Endpoints reference graph_nodes within the same '
  '(operator_id, graph_scope, graph_version) tuple via composite '
  'FKs; cross-operator / cross-scope / cross-version edges are DB '
  'errors. AGE projections are rebuilt from these rows.';

comment on column public.graph_edges.edge_type is
  'Q19: structural edge type (CONTAINS, CAUSES, DEPENDS_ON, ...). '
  'Semantics carried in properties.';

-- ─── Indexes (tenant-leading per CLAUDE.md RLS performance discipline) ─
--
-- Every B-tree index leads with `operator_id` so the RLS policy
-- evaluation folds into the index probe. The four indexes below cover
-- the four hot paths the projection rebuild + retrieval traversals
-- use:
--   1. node lookup by (operator, scope, version, type)
--   2. edge traversal from a starting node
--   3. edge traversal back from an ending node
--   4. active-edge count for the tripwire (Q19 yellow/red)
--
-- The active-edge index uses a partial predicate so the tripwire scan
-- only walks rows that the AGE projection would project today; archived
-- and deleted rows do not pollute the index.

create index if not exists graph_nodes_operator_scope_type_idx
  on public.graph_nodes (operator_id, graph_scope, graph_version, node_type);

create index if not exists graph_nodes_operator_active_idx
  on public.graph_nodes (operator_id, graph_scope, graph_version)
  where deleted_at is null and archived_at is null;

create index if not exists graph_edges_operator_from_node_idx
  on public.graph_edges
    (operator_id, graph_scope, graph_version, from_node_id);

create index if not exists graph_edges_operator_to_node_idx
  on public.graph_edges
    (operator_id, graph_scope, graph_version, to_node_id);

create index if not exists graph_edges_operator_active_idx
  on public.graph_edges (operator_id, graph_scope, graph_version)
  where deleted_at is null and archived_at is null;

-- ─── updated_at triggers ───────────────────────────────────────────
--
-- Reuses the cloud-foundation `cloud_foundation_set_updated_at()`
-- function from 202604250005 so updated_at stays consistent across
-- operator-scoped tables.

drop trigger if exists graph_nodes_set_updated_at on public.graph_nodes;
create trigger graph_nodes_set_updated_at
before update on public.graph_nodes
for each row execute function public.cloud_foundation_set_updated_at();

drop trigger if exists graph_edges_set_updated_at on public.graph_edges;
create trigger graph_edges_set_updated_at
before update on public.graph_edges
for each row execute function public.cloud_foundation_set_updated_at();

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ───────────────────────
--
-- Per-tenant from creation. Both tables use the
-- `public.app_current_operator()` wrapper from 9.0Σ.b. Bare
-- `current_setting()` is forbidden by the lint.

alter table public.graph_nodes enable row level security;

create policy "graph_nodes_per_tenant"
  on public.graph_nodes for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "graph_nodes_per_tenant" on public.graph_nodes is
  'Phase 9.0Σ.i — tenant sees only their own canonical graph vertices. '
  'Reads operator context via app_current_operator() wrapper (item 4) '
  'so the planner folds the predicate into the operator-leading '
  'indexes. forge_admin BYPASSRLS handles cross-tenant admin paths.';

alter table public.graph_edges enable row level security;

create policy "graph_edges_per_tenant"
  on public.graph_edges for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "graph_edges_per_tenant" on public.graph_edges is
  'Phase 9.0Σ.i — tenant sees only their own canonical graph edges. '
  'Same wrapper-driven posture as graph_nodes_per_tenant.';

-- ─── Grants ────────────────────────────────────────────────────────
--
-- Same posture as the other 9.0Σ operator-scoped tables: service_role
-- and forge_admin both get full DML so the runtime + admin paths both
-- work. RLS is the per-tenant gate; PUBLIC stays revoked.

grant select, insert, update, delete on public.graph_nodes to service_role;
grant select, insert, update, delete on public.graph_nodes to forge_admin;

grant select, insert, update, delete on public.graph_edges to service_role;
grant select, insert, update, delete on public.graph_edges to forge_admin;

-- ─── Tripwire surface (Q19 yellow 3M / red 4M active edges) ────────
--
-- Set-returning function that exposes the graph health metrics the
-- 11A graph panel reads. Per Q19:
--   * yellow_threshold_active_edges = 3,000,000
--   * red_threshold_active_edges    = 4,000,000
-- The status column is computed from active_edge_count vs the
-- thresholds so callers do not have to re-implement the rule.
--
-- Reserved metadata slots (last_projection_built_at,
-- last_benchmark_at) return NULL today; populated when the projection
-- rebuild and benchmark harness land their own state tables in a
-- later slice. Defining the columns now keeps the function shape
-- stable for the 11A panel.
--
-- The function runs SECURITY INVOKER so RLS still applies — counts
-- are scoped to the calling tenant. F&F internal admin paths use
-- forge_admin BYPASSRLS to read across tenants.

create or replace function public.graph_health_metrics()
returns table (
  graph_scope text,
  graph_version text,
  active_node_count bigint,
  active_edge_count bigint,
  yellow_threshold_active_edges bigint,
  red_threshold_active_edges bigint,
  status text,
  last_projection_built_at timestamptz,
  last_benchmark_at timestamptz
)
language sql
stable
as $$
  with active_nodes as (
    select graph_scope, graph_version, count(*)::bigint as cnt
    from public.graph_nodes
    where deleted_at is null
      and archived_at is null
      and active_from <= now()
      and (active_to is null or active_to > now())
    group by graph_scope, graph_version
  ),
  active_edges as (
    select graph_scope, graph_version, count(*)::bigint as cnt
    from public.graph_edges
    where deleted_at is null
      and archived_at is null
      and active_from <= now()
      and (active_to is null or active_to > now())
    group by graph_scope, graph_version
  ),
  scopes as (
    select graph_scope, graph_version from active_nodes
    union
    select graph_scope, graph_version from active_edges
  )
  select
    s.graph_scope,
    s.graph_version,
    coalesce(n.cnt, 0)::bigint as active_node_count,
    coalesce(e.cnt, 0)::bigint as active_edge_count,
    3000000::bigint as yellow_threshold_active_edges,
    4000000::bigint as red_threshold_active_edges,
    case
      when coalesce(e.cnt, 0) >= 4000000 then 'red'
      when coalesce(e.cnt, 0) >= 3000000 then 'yellow'
      else 'green'
    end as status,
    null::timestamptz as last_projection_built_at,
    null::timestamptz as last_benchmark_at
  from scopes s
  left join active_nodes n
    on n.graph_scope = s.graph_scope and n.graph_version = s.graph_version
  left join active_edges e
    on e.graph_scope = s.graph_scope and e.graph_version = s.graph_version;
$$;

comment on function public.graph_health_metrics() is
  'Phase 9.0Σ.i (item 30 / Q19) — graph health + tripwire surface. '
  'Returns active vertex/edge counts per (graph_scope, graph_version) '
  'with yellow at 3M / red at 4M active edges. SECURITY INVOKER so '
  'RLS scopes counts to the calling tenant; forge_admin BYPASSRLS '
  'handles cross-tenant admin reads. last_projection_built_at and '
  'last_benchmark_at are reserved slots filled by a later slice.';

grant execute on function public.graph_health_metrics() to service_role;
grant execute on function public.graph_health_metrics() to forge_admin;

commit;
