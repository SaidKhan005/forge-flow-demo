# Phase 9 Graph Projection Rebuild Runbook

Operational runbook for the canonical graph rebuild path landed by
`db/migrations/202604280008_phase_9_0sigma_i_graph_canonical.sql`
(B30) and the rebuild artifact preparer at
`tool/graph_projection/graph_projection.dart`. This runbook is the
single source of truth for any operator running the AGE label graph
rebuild against staging or Production1.

The rebuild is a **projection-only** operation: canonical truth lives
in `public.graph_nodes` and `public.graph_edges`, and the rebuild
drops/recreates the AGE label graph from those rows. Canonical rows
are never mutated. Phase 9.0Σ.i Q19 owns the rule.

## Authority

This runbook is governed by:

- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`
  Q19 (AGE graph scale tripwire + rebuildable projection — yellow at
  3M active edges, red at 4M, non-destructive rollover).
- `db/migrations/202604280008_phase_9_0sigma_i_graph_canonical.sql`
  for the canonical `graph_nodes` / `graph_edges` schema, the
  composite same-operator FKs, the active-row partial indexes, the
  RLS policies, and the tenant-scoped helper function
  `public.graph_health_metrics()` (used for ad-hoc tenant queries
  only — see "How B42 graph health keys consume this status" below
  for why the rebuild's tripwire reads canonical tables directly
  instead of calling this helper).
- `tool/graph_projection/graph_projection.dart` for the build-only
  artifact preparer (`prepare-rebuild`) that emits four SQL files plus
  a manifest into `build/graph_projection/`.
- `runbooks/phase_9_production1_migration_apply_runbook.md` for the
  general live-mutation gate language Production1 applies inherit.
- `CLAUDE.md` ("AGE infrastructure live before 11b", "Per-operator
  isolation is non-negotiable", "F&F holds all provider keys
  server-side", and the Postgres host pin to Azure DB Flexible Server,
  Canada Central, PG 16).

## Scope

Per Q19, every rebuild is bounded by these axes. Pick one value per
axis (or "all"); do not run an unbounded rebuild.

| Axis           | Source                                                 |
| -------------- | ------------------------------------------------------ |
| operator       | `operators.operator_id` (or "all" for forge_admin)     |
| graph_scope    | `methodology`, `workflows`, `causal`, …                |
| graph_version  | rebuild generation (e.g. `v3`)                         |
| AGE graph name | `advisor_corpus` by default (`--graph=…` overrides)    |
| date           | "now" — the rebuild always replays active rows only    |

The preparer's `--graph` and `--scope` flags name the AGE graph and
the canonical scope filter. Filter shapes:

- `--scope=all_active` (default) — no SQL-level filter; every active
  `(operator_id, graph_scope, graph_version)` tuple visible to the
  caller is rebuilt. The drop step calls `ag_catalog.drop_graph` and
  every projection in the AGE catalog is replaced.
- `--scope=<scope>` — bounded to a single canonical scope (e.g.
  `methodology`); every active `graph_version` under that scope is
  rebuilt. The drop step uses Cypher `DETACH DELETE` against only
  the matched subgraph; untouched scopes survive.
- `--scope=<scope>:<version>` — bounded to a single
  `(graph_scope, graph_version)` tuple (e.g. `methodology:v3`); the
  prior-version re-projection / scope-bounded rollback path. Drop
  uses Cypher `DETACH DELETE`; only the matched
  `(scope, version)` subgraph is removed and rebuilt.

Filter values are sanitized to `[A-Za-z0-9_-]` (and `.` in the
version segment); invalid values throw at parse time before any SQL
is emitted. Cross-operator scoping is layered on top: a tenant
session sees only its own canonical rows via RLS, while a
`forge_admin` session sees every operator (the rebuild's tripwire
surfaces operator_id explicitly so a forge_admin run reports
per-tenant status rather than a cross-tenant aggregate).

## When to run a rebuild

Trigger a rebuild for any of:

1. **Canonical drift detected.** The B30 byte-equivalence smoke
   reports `AGE_REBUILD_SMOKE_DIGEST_MISMATCH` against a previous
   projection. The operator runs a fresh rebuild and re-checks.
2. **Yellow tripwire (3,000,000 active edges in one
   `(graph_scope, graph_version)`).** Schedule a Q19 rollover plan
   before red fires. The rebuild itself does not move the row count;
   the rollover plan archives stale rows or repartitions the
   projection.
3. **Red tripwire (4,000,000 active edges in one
   `(graph_scope, graph_version)`).** Execute the Q19 rollover
   immediately. Repartition projections, prune/archive stale edges
   from the active projection without deleting canonical data, rebuild
   AGE, shadow-query, cut over only after validation.
4. **Schema landing** — a new migration adds columns or constraints
   the projection layer needs to surface (e.g. a new node_type the
   advisor traversal will use). The rebuild replays canonical rows
   under the new shape.
5. **Recovery** — operator-side AGE catalog corruption or a botched
   manual Cypher write. The canonical tables remain authoritative;
   the rebuild restores the projection from canonical truth.
6. **Pre-cutover sanity** — the cutover.0 pre-flight runs the rebuild
   against staging to confirm the projection-build path is healthy
   before the Production1 cutover window.

Do **not** rebuild for:

- A vector-only retrieval regression — that lives in the HNSW/DiskANN
  switch trigger doc, not here.
- A purely advisor-corpus seed change — the older 7.57.4 advisor seed
  surface is out of scope; the rebuild reads canonical
  `graph_nodes`/`graph_edges` only.
- A no-op operator request — the canonical rebuild is non-destructive
  but is still a synchronous write against the AGE catalog and a
  transient resource pressure event on the Postgres host.

## Preflight checks

Stop with `BLOCKED` if any item is missing.

- [ ] This runbook reviewed in the current session.
- [ ] Target host named explicitly by name only
      (`forge-flow-staging-pg` or `forge-flow-production1-pg`,
      Canada Central). No DSNs, secrets, tokens, or passwords pasted
      into chat or docs.
- [ ] AGE extension allow-listed in `azure.extensions` for the target
      Flexible Server, and `select extname from pg_extension where
      extname = 'age'` returns one row at the live host.
- [ ] Canonical migrations through
      `202604280008_phase_9_0sigma_i_graph_canonical.sql` already
      applied at the target.
- [ ] Fresh restore point captured (Production1 only).
- [ ] Staging has applied the same rebuild SQL successfully and
      reported an AGE_REBUILD_SMOKE_OK NOTICE before any Production1
      attempt.
- [ ] `flutter analyze --fatal-infos` and `flutter test
      test/phase_9_0sigma_i_graph_canonical_test.dart` are green on
      the applying commit.
- [ ] Operator approving the apply named explicitly.
- [ ] Vector-only retrieval fallback confirmed healthy at the target
      so an AGE_BLOCKER path leaves the launch product working.

## Dry-run / local artifact generation

Every rebuild starts as a local build-only run. The preparer writes
SQL files plus a manifest to `build/graph_projection/`; nothing in the
preparer opens a Postgres connection or hits a provider.

```powershell
dart run tool/graph_projection/main.dart prepare-rebuild
# or, with overrides:
dart run tool/graph_projection/main.dart prepare-rebuild `
  --output=build/graph_projection_staging `
  --graph=advisor_corpus `
  --scope=all_active
```

Outputs:

- `001_age_drop_projection.sql` — drops the AGE label graph.
- `002_age_rebuild_projection.sql` — rebuilds vertices + edges from
  `public.graph_nodes` / `public.graph_edges` (active rows only).
- `003_age_rebuild_smoke.sql` — byte-equivalence digest check
  (canonical vs. AGE) over the identity tuple. The B30 staging gate
  is "canonical and AGE digests match".
- `004_age_rebuild_tripwire.sql` — aggregates `public.graph_nodes`
  / `public.graph_edges` directly with `GROUP BY (operator_id,
  graph_scope, graph_version)` and emits the per-row + cross-scope
  NOTICE lines the B42 `/health` route will consume. The migration's
  `public.graph_health_metrics()` helper is intentionally NOT
  invoked here because it discards `operator_id`; B42's
  forge_admin views need per-tenant rows.
- `graph_projection_rebuild_manifest.json` — the rebuild contract
  (manifest fields enumerated below).

The preparer is byte-deterministic: identical canonical inputs
produce identical SQL files and an identical `rebuild_run_id`. A
re-run that produces a different `rebuild_run_id` indicates a
contract drift and must be investigated before applying anywhere.

The manifest is the parsing target for downstream tooling. Its key
fields:

- `graph_name` — AGE label graph the rebuild targets.
- `graph_scope_filter` — `all_active` by default.
- `graph_scope_filter_parsed` — structured form of the filter
  (`is_all_active`, `scope`, `version`, `description`).
- `graph_scope_version_pairs` — describes which canonical
  `(operator_id, graph_scope, graph_version)` rows are in scope.
- `canonical_source_tables` — `public.graph_nodes`,
  `public.graph_edges`. The advisor seed tables from 7.57.4 are
  named as forbidden inputs.
- `canonical_safety` — declares `mutates_canonical_rows = false`,
  `mutates_graph_nodes_table = false`,
  `mutates_graph_edges_table = false`,
  `rebuild_artifacts_imply_canonical_mutation = false`,
  `mutates_age_projection = true`.
- `age_projection_identity` — declares the composite identity tuple
  used by AGE MERGE/MATCH (`vertex_merge_pattern_keys`,
  `edge_merge_pattern_keys`, `edge_endpoint_match_keys`) so a
  downstream tool can verify the rebuild honors canonical identity
  and does not silently collapse rows on UUID alone.
- `tripwire_surface` — Q19 yellow 3,000,000 / red 4,000,000 active
  edges, `aggregation_keys = (operator_id, graph_scope,
  graph_version)`, `forge_admin_per_tenant_rows = true`, the
  reserved metadata slots `last_projection_built_at` /
  `last_benchmark_at`, the full B42 health metric keys list, and
  the explicit active vs reserved-null split
  (`b42_health_metric_keys_active` /
  `b42_health_metric_keys_reserved_null_today`).
- `rebuild_validation_steps` — the ordered apply plan
  (preflight → dry-run → drop → rebuild → smoke → tripwire).
- `runbook_reference` — points back to this file.
- `byte_equivalence_gate` — names the digest algorithm + identity
  tuples the smoke compares; B30 staging gate.

Operators who only need to inspect the contract can read the manifest
without running anything against the live host.

## Production1 approval gate

Before applying any generated SQL to Production1:

- [ ] Staging applied the same generated SQL files and reported
      AGE_REBUILD_OK + AGE_REBUILD_SMOKE_OK + the expected tripwire
      band (green or yellow). A red tripwire on staging blocks
      Production1.
- [ ] The `rebuild_run_id` in the staging manifest matches the
      Production1 manifest (same canonical inputs → same id).
- [ ] Operator approving the apply named explicitly. Production1
      requires Vanessa or a F&F internal admin with explicit
      Production1 cutover authority; staging-only operators cannot
      promote a rebuild to Production1.
- [ ] Apply window scheduled in the Production1 maintenance band.
      The rebuild scans every active row in `graph_nodes` and
      `graph_edges`; do not run during peak.
- [ ] Backup / restore point captured within the prior 60 minutes.
- [ ] Cloud Armor enforcement posture unchanged (the rebuild is a
      DB-only operation, but a rolling enforcement change concurrent
      with the rebuild widens the on-call surface — defer one or
      the other).
- [ ] AGE_BLOCKER fallback path acknowledged: if AGE is unavailable,
      the rebuild emits the AGE_BLOCKER NOTICE and exits cleanly;
      vector-only retrieval remains the launch fallback. Record the
      blocker as 9.0Σ.i acceptance evidence and stop.

Stop with `BLOCKED` if any item is missing.

## Rebuild execution outline

Per the `rebuild_validation_steps` plan in the manifest. Apply the
generated SQL inside a tenant-scoped transaction. The preparer never
opens a connection; the operator runs the SQL via `psql` or the
admin proxy with `forge_admin` BYPASSRLS for cross-operator scopes.

### 1. Drop the AGE label graph

Apply `001_age_drop_projection.sql`. Two emission shapes:

- `--scope=all_active`: the script calls `ag_catalog.drop_graph` and
  every projection in the AGE catalog is replaced.
- `--scope=<scope>` or `--scope=<scope>:<version>`: the script runs
  Cypher `MATCH (v) WHERE v.graph_scope = '<scope>' [AND
  v.graph_version = '<version>'] DETACH DELETE v`. Only the matched
  subgraph is removed; every other operator/scope/version remains
  intact. The script counts the matched vertices before and after
  the delete and `RAISE EXCEPTION`s with `AGE_DROP_INCOMPLETE` if
  the post-delete count is non-zero.

Possible NOTICE outcomes:

- `AGE_BLOCKER` — Apache AGE is unavailable. Stop. Record acceptance
  evidence; vector-only retrieval is the launch fallback.
- `AGE_DROP_OK: graph="advisor_corpus" dropped (scope=all_active).`
  — whole-graph drop completed cleanly.
- `AGE_DROP_OK: graph="advisor_corpus" bounded-scope drop complete
  (scope filter: <description>, vertices removed=N).` — bounded
  drop completed cleanly.
- `AGE_DROP_NOTE: graph="advisor_corpus" not present; nothing to
  drop.` — first-time rebuild or a previous run completed cleanup.
- `AGE_DROP_INCOMPLETE: …` — bounded drop left vertices behind.
  Investigate before rebuilding.

Canonical rows are not touched in this step.

### 2. Rebuild the AGE label graph

Apply `002_age_rebuild_projection.sql`. The script:

- Re-creates the AGE graph if missing.
- Walks `public.graph_nodes` and `public.graph_edges` in
  `(operator_id, graph_scope, graph_version, id)` order — the cursor
  ordering is the determinism contract.
- Honors the scope filter: `WHERE deleted_at IS NULL AND archived_at
  IS NULL AND active_from <= now() AND (active_to IS NULL OR
  active_to > now())` plus optional `AND graph_scope = '<scope>'
  [AND graph_version = '<version>']`.
- MERGEs vertices and edges with the **canonical composite identity**
  tuple `(operator_id, graph_scope, graph_version, node_id|edge_id)`.
  The composite key is mandatory: canonical UUIDs are universally
  unique today, but the canonical contract makes identity
  composite, not UUID-only. A composite MERGE keeps two rows with
  the same UUID under different `(operator, scope, version)` frames
  as separate AGE vertices; a UUID-only MERGE would collapse them
  and silently overwrite vertex properties, which is the bug.
- Edge endpoint MATCHes also use the composite tuple so an edge can
  only attach to a vertex within its own canonical frame.
- Skips soft-deleted, archived, future-staged (`active_from > now()`),
  and expired rows; only the rows the projection should serve today
  are projected.

Expected NOTICE: `AGE_REBUILD_OK: graph="advisor_corpus" rebuilt
from public.graph_nodes / public.graph_edges (canonical rows
untouched, scope filter: <description>). projected_nodes=N,
projected_edges=M.`

If the script raises `AGE_REBUILD_INVALID_NODE_TYPE` or
`AGE_REBUILD_INVALID_EDGE_TYPE`, a producer wrote a non-identifier
type into the canonical table; the rebuild aborts before any
malformed Cypher is injected.

## Validation and smoke checks

### 3. Smoke / byte-equivalence

Apply `003_age_rebuild_smoke.sql`. The smoke computes two SHA-256
digests over the identity tuple `(operator_id|graph_scope|
graph_version|id|type|...)` — once against `public.graph_nodes` /
`public.graph_edges` and once against the AGE projection's stored
properties. The B30 gate is "canonical and AGE digests match".

NOTICE outcomes:

- `AGE_REBUILD_SMOKE_OK` — counts + digests captured.
- `AGE_REBUILD_SMOKE_MISMATCH` — node or edge count drift
  (necessary but not sufficient).
- `AGE_REBUILD_SMOKE_DIGEST_MISMATCH` — node or edge identity
  tuple drift. **Hard fail**: a single-side regression — wrong
  endpoints, mislabeled edges, dropped or invented rows — surfaces
  here that a count-only check would miss. Roll back to the prior
  projection (see Rollback / fallback below).

### 4. Tripwire / B42 health

Apply `004_age_rebuild_tripwire.sql`. The tripwire reads canonical
tables directly with `GROUP BY (operator_id, graph_scope,
graph_version)` and emits one NOTICE per active
`(operator_id, graph_scope, graph_version)` row plus a single
roll-up line. The migration's `public.graph_health_metrics()`
function exists as a tenant-scoped helper for ad-hoc queries — it
aggregates by `(graph_scope, graph_version)` and intentionally does
not surface `operator_id`, so it is unsuitable for forge_admin
BYPASSRLS reads where the B42 archived contract requires
per-operator scoping. The rebuild's tripwire avoids it deliberately
so a forge_admin run reports per-tenant rows.

Per-row NOTICE format (B42 contract — the proxy `/health` route the
11A.5 / 11A.6 dashboards consume reuses these key names verbatim):

```
AGE_TRIPWIRE: operator="<uuid>" scope="<scope>" version="<version>"
  status=<green|yellow|red>
  graph_node_count=<N> graph_edge_count=<M>
  graph_active_edges_count=<M>
  graph_traversal_latency_ms=null
  graph_p95_traversal_latency_ms=null
  graph_timeout_rate=null
  graph_high_degree_count=null
  graph_last_projection_build_seconds_ago=null
  yellow_at=3000000 red_at=4000000
  last_projection_built_at=null last_benchmark_at=null.
```

Roll-up NOTICE:

```
AGE_TRIPWIRE_TOTALS: graph_node_count=<sum> graph_edge_count=<sum>
  graph_active_edges_count=<sum>
  graph_traversal_latency_ms=null
  graph_p95_traversal_latency_ms=null
  graph_timeout_rate=null
  graph_high_degree_count=null
  graph_last_projection_build_seconds_ago=null
  yellow_threshold_active_edges=3000000
  red_threshold_active_edges=4000000
  operator_scope_version_row_count=<N>
  last_projection_built_at=null last_benchmark_at=null
  overall_status=<green|yellow|red>.
```

Closing banner:

- `AGE_TRIPWIRE_GREEN` — every (operator, scope, version) row below
  3,000,000 active edges.
- `AGE_TRIPWIRE_YELLOW` — at least one row between 3,000,000 and
  4,000,000 active edges. Schedule the Q19 rollover plan before red
  fires.
- `AGE_TRIPWIRE_RED` — at least one row at or above 4,000,000 active
  edges. Execute Q19 rollover immediately.

Capture the per-row + roll-up NOTICEs as 9.0Σ.i acceptance evidence.
The B42 `/health` route, when it lands, parses these NOTICEs
directly so 11A.5 wiring does not need to translate column aliases.

The B42 contract reserves a wider key set than this slice fills
today. Active vs reserved-null split:

| Status | Keys |
| ------ | ---- |
| Active (filled today) | `graph_node_count`, `graph_edge_count`, `graph_active_edges_count` |
| Reserved-null today (filled by a later benchmark / runtime telemetry slice) | `graph_traversal_latency_ms`, `graph_p95_traversal_latency_ms`, `graph_timeout_rate`, `graph_high_degree_count`, `graph_last_projection_build_seconds_ago` |

Each reserved-null key is emitted as `<key>=null` in every NOTICE
line so the proxy parser-side schema is stable today; a later slice
flips individual keys from `null` to numeric without breaking the
proxy or 11A.5.

## Rollback / fallback

The rebuild is non-destructive against canonical truth. Rolling back
means restoring the prior AGE projection state, not touching
`graph_nodes` / `graph_edges`.

Options, in order of preference:

1. **Prior-version re-projection.** Each canonical row carries a
   `graph_version`. If the new version's projection is bad and the
   prior version's rows are still present (Q19 archive-not-delete),
   re-run `prepare-rebuild` with `--scope=<scope>:<prior-version>`
   (e.g. `--scope=methodology:v2` to roll back from `v3` to `v2`)
   and apply the resulting SQL. **The scope segment is required**:
   `--scope=<prior-version>` alone parses as a scope filter and
   would narrow `graph_scope = '<prior-version>'`, which is the
   wrong axis. The bounded drop's Cypher `DETACH DELETE` removes
   only the matched `(graph_scope, graph_version)` subgraph; every
   other operator/scope/version remains intact, so the previous
   projection is restored without touching canonical truth.
2. **Drop without rebuild.** Apply `001_age_drop_projection.sql` only,
   leaving the AGE graph absent. The advisor falls back to vector-only
   retrieval (the launch fallback path). Record the blocker as
   acceptance evidence and schedule a follow-up rebuild.
3. **Restore-point rollback (Production1 only).** If a step before
   the rebuild already mutated the AGE catalog and the script cannot
   reach a clean exit, restore from the captured Production1 restore
   point. Canonical rows were never modified by the rebuild, so the
   restore is a projection-only correction.

Forbidden rollback paths:

- `UPDATE` / `DELETE` against `public.graph_nodes` or
  `public.graph_edges`. Canonical truth is the system of record;
  rolling back the rebuild does not authorize canonical mutation.
  Use the soft-delete / archive paths defined by the migration if a
  canonical correction is needed — but that is a different slice
  with its own approval gate.
- Rewriting the migration SQL. Canonical schema changes go through a
  new timestamped migration file; the rebuild artifact never edits
  applied migrations.

## How B42 graph health keys consume this status

The proxy `/health` route locked in B42 (queued) reserves a set of
graph metric keys; the archived B42 backlog enumerates the full set,
the slice's authority block (Block 2) names a narrower core. The
rebuild's tripwire emits the union so the proxy never needs to
ingest two shapes:

| Key | Status | Source |
| --- | ------ | ------ |
| `graph_node_count` | Active | Canonical aggregation (tripwire) |
| `graph_edge_count` | Active | Canonical aggregation (tripwire) |
| `graph_active_edges_count` | Active | Canonical aggregation; alias of edge_count for Q19 tripwire wording |
| `graph_traversal_latency_ms` | Reserved-null today | Later benchmark slice |
| `graph_p95_traversal_latency_ms` | Reserved-null today | Later benchmark slice |
| `graph_timeout_rate` | Reserved-null today | Later runtime telemetry slice |
| `graph_high_degree_count` | Reserved-null today | Later benchmark slice |
| `graph_last_projection_build_seconds_ago` | Reserved-null today | Later benchmark / projection-state slice |
| `last_projection_built_at` | Reserved-null today | Later projection-state slice |
| `last_benchmark_at` | Reserved-null today | Later benchmark slice |

The tripwire artifact emits every key verbatim in the
`AGE_TRIPWIRE` and `AGE_TRIPWIRE_TOTALS` NOTICE lines. When the B42
route lands:

- The proxy reads the NOTICE shape from the most recent rebuild's
  tripwire output (or from a live aggregation against canonical
  tables — same shape) and exposes the keys to the 11A.5 Graph
  Health surface and 11A.6 observability dashboard.
- The proxy is operator-scoped: rows are keyed by `(operator_id,
  graph_scope, graph_version)`. forge_admin BYPASSRLS reads see
  one row per tenant; tenant-scoped reads see only the caller's
  rows via RLS on the underlying canonical tables.
- Reserved-null keys return `null` until the benchmark / runtime
  telemetry slice fills them; the proxy returns null for those keys
  in the meantime and 11A.5 renders an "awaiting benchmark"
  placeholder. Once the benchmark slice ships, individual keys flip
  from null to numeric without breaking the parser-side schema.
- Threshold context (yellow at 3,000,000 active edges, red at
  4,000,000) flows from the manifest's `tripwire_surface` block so
  the proxy does not re-implement the rule.
- Tenant-scoped helper: the migration's
  `public.graph_health_metrics()` function exists for ad-hoc tenant
  queries (it aggregates by `(graph_scope, graph_version)` only).
  The proxy and the rebuild's tripwire both prefer the canonical
  tables direct read because forge_admin views require operator-
  scoped rows.

Until the B42 route ships, the tripwire NOTICE output is the
acceptance evidence the operator captures by hand. The `/health`
route wiring (proxy code in `tool/advisor_proxy/advisor_proxy.dart`
plus a contract doc at `docs/contracts/proxy_health_contract.md`)
is intentionally deferred to B42; this slice does not add any
proxy routes.

## Out of scope for this runbook

- The proxy `/health` route itself (B42) — separately tracked.
- The graph traversal benchmark slice that populates
  `graph_traversal_latency_ms` and `last_benchmark_at`. Reserved
  slots stay null until that slice lands.
- AGE topology changes (new label types, new edge cardinalities) —
  those are Phase 11b advisor causal-traversal work, not a rebuild.
- Cross-cloud projection (Neo4j, managed graph) — Q19 calls out
  shadow-querying as a future option; the canonical schema is host-
  agnostic but no rebuild path other than AGE is in scope today.
- Operator-data hard-delete — Q21 sensitive-information redaction
  governs that surface. The rebuild participates by re-projecting
  redacted rows on the next run; it does not initiate redaction.
