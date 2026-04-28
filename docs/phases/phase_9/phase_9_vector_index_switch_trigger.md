# Phase 9.0Σ.j — Vector Index Switch Trigger (HNSW default; DiskANN dormant)

Status: locked posture per Q20 in
`phase_9_scalability_decisions_2026-04-27.md` (item 31), B31 in
`phase_9_execution_backlog.md`. Companion to migration
`db/migrations/202604280009_phase_9_0sigma_j_diskann_install.sql`.

This document records the posture for vector index choice. It does
not authorize DiskANN as default and does not create indexes. It
governs **when** the operator-facing decision to consider a cutover
fires, and **how** that cutover may be performed when it does.

## Default posture

- **HNSW remains the default** vector index for active corpora and
  the advisor retrieval hot path. The partial HNSW pgvector cosine
  index from `202604250003_advisor_vector_search.sql`
  (`advisor_source_chunks_voyage_hnsw_idx`, scoped to
  `embedding_status = 'ready'`, the locked Voyage `voyage-4-large`
  1024-dim provider/model/dimension triple, and `active = true`)
  continues to back `public.advisor_search_chunks` candidate
  retrieval unchanged.
- **DiskANN is installed but dormant.** The `pg_diskann` extension is
  installed via 9.0Σ.j so the `CREATE INDEX ... USING diskann` path
  is reachable when a cutover is later approved. No DiskANN index
  exists in this slice. No retrieval code routes to DiskANN.
- **Live apply path.** The `pg_diskann` extension only goes live on
  staging and Production1 through the approved Phase 9 migration
  path. There are no out-of-band live database commands tied to this
  posture.

## Switch triggers

Triggers fire on the **per-searchable-embedding-space / per-index**
metric, not on aggregate row counts across all corpora. "One
searchable embedding space" is a single
`(provider_id, model_id, dimension)` partial-index slice such as the
Voyage `voyage-4-large` 1024-dim corpus.

### Yellow — investigate, plan a cutover dry run

Any of the following is enough to raise the decision to plan a
non-destructive cutover:

- **5M active vectors** in one searchable embedding space / index.
- **Sustained latency regression** at p50, p95, or p99 against the
  rolling baseline benchmark.
- **Rebuilds exceeding the maintenance window** (full HNSW rebuild
  cannot complete inside the agreed maintenance budget).
- **Memory pressure** on the host attributable to HNSW resident
  graph size.

Yellow does not flip the default. It opens the cutover playbook
(shadow → benchmark → canary).

### Red — initiate non-destructive cutover

Any of the following moves the decision from "plan" to "execute the
cutover playbook":

- **8M active vectors** in one searchable embedding space / index.
- **Projected growth crossing 10M** within the operational planning
  window for that index (the internal HNSW risk line per Q20).
- **Repeated timeouts** on candidate retrieval against the same
  index.
- **Unacceptable recall or latency** that the rolling benchmark
  confirms is not transient.
- **Operationally unsafe rebuilds** — rebuild windows that cannot be
  completed without exceeding maintenance, replication, or memory
  budgets.

Red still does not authorize a destructive switch. It authorizes the
non-destructive cutover playbook in the next section.

## Vector Index Health observability

Before a cutover decision can advance past Yellow, the Vector Index
Health surface must report the following fields per searchable
embedding space / index. These are the Q20 observability fields and
the trigger evidence the cutover playbook reads from:

- **active_vectors** — count of rows currently included in the
  partial-index predicate (status ready, embedding present, active
  true, matching provider/model/dimension).
- **index_type** — `hnsw` today; `diskann` only after a cutover.
- **index_size** — on-disk size of the index pages.
- **build_status** — `ready`, `building`, `failed`, or `pending`.
- **last_build** — timestamp of the most recent successful build.
- **benchmark_timestamp** — timestamp of the latest recorded
  benchmark run that produced the latency / recall numbers below.
- **p50_latency** — median candidate-retrieval latency from the
  benchmark.
- **p95_latency** — p95 candidate-retrieval latency from the
  benchmark.
- **p99_latency** — p99 candidate-retrieval latency from the
  benchmark.
- **timeout_rate** — fraction of candidate-retrieval calls that
  exceeded the timeout budget over the benchmark window.
- **recall_score** — recall against the held-out evaluation set for
  this index.
- **filtered_search_behavior** — recall / latency under predicate
  filters (scope, restaurant_id, provider/model/dimension), since
  filtered HNSW behavior diverges from unfiltered.
- **growth_projection** — projected `active_vectors` at the planning
  horizon, used against the 5M / 8M / 10M lines.
- **affected_functionality** — which advisor / future-surface paths
  this index serves; consumed when deciding blast radius.
- **recommended_action** — the surface's recommendation given the
  fields above (`hold`, `plan_cutover`, `execute_cutover`,
  `investigate`).

Vector Index Health is the evidence layer. Triggers fire from these
fields; the cutover playbook below consumes the same fields during
shadow and canary.

## Cutover posture (non-destructive)

When Red triggers fire and the playbook is authorized, the cutover
must be non-destructive. The HNSW index stays in place and serving
production traffic until the new DiskANN index has been validated and
canary-promoted. The required steps:

1. **Shadow query.** Build the DiskANN index on the same partial
   predicate (status ready, embedding present, active true, matching
   provider/model/dimension, tenant/operator scoping preserved).
   Issue production candidate-retrieval queries against both indexes
   in shadow; serve only the HNSW result.
2. **Benchmark comparison.** Compare DiskANN vs HNSW on the Vector
   Index Health benchmark fields: p50/p95/p99 latency, timeout rate,
   recall score, filtered search behavior. Cutover may not progress
   if DiskANN regresses on any of these against HNSW.
3. **Canary routing.** Route a defined fraction of live retrieval to
   DiskANN, monitor the same Vector Index Health fields plus
   advisor-side answer-quality signals, and ramp only on green.
4. **Non-destructive switch.** Promote DiskANN to default after
   canary is clean. The HNSW index is **not dropped** at switch time.
5. **14-day rollback window.** The HNSW index remains in place and
   queryable for at least 14 days after the switch so a rollback is
   a routing flip, not a rebuild. Drop of the retired HNSW index is
   a separate, deliberate, post-window step.

## Future vector index guidance

Any future vector index — DiskANN cutover, additional HNSW indexes
for new corpora, or other embedding-backed surfaces — must preserve
two scoping rules:

- **Tenant / operator scoping.** Per the RLS-Ready Schema and RLS
  performance discipline locks in `CLAUDE.md`, every fact-table
  index has `operator_id` (or `(operator_id, location_id)`) as the
  leading column on operator-scoped tables. Vector indexes on
  operator-scoped corpora follow the same rule. Corpus tables that
  are `operator_id`-scoped (advisor methodology) inherit that
  scoping in their partial-index predicate. Bare
  `current_setting()` reads are forbidden in any policy guarding
  these indexes; use the `app_current_operator()` family of
  wrapper functions (item 4 in the scalability decisions).
- **Provider / model / dimension scoping.** Per the 11a.8 contract
  in `202604250003_advisor_vector_search.sql`, vector indexes are
  partial on `(embedding_provider_id, embedding_model_id,
  embedding_dimension)` so a future provider, model, or dimension
  cannot silently mix into another's candidate retrieval. DiskANN
  indexes follow the same rule. The retrieval function continues to
  filter on the same triple.

## Authorization scope

This document does not authorize DiskANN as default. It does not
create indexes. It does not change RLS policies, retrieval functions,
embedding contracts, or app-side query routing. It records the
trigger thresholds, the observability fields, and the
non-destructive cutover posture so the decision can be executed
correctly when the triggers fire.
