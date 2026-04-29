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

## Health interpretation (B47 helper)

The `tool/vector_index_health/vector_index_health.dart` helper
materializes the field set above as `VectorIndexHealthSnapshot` and
derives `recommended_action` from the Q20 trigger families. The
helper is the data shape the B42 `/health` route will read; B47
lands the helper, B42 wires the route.

The helper requires every snapshot to carry an explicit
`VectorIndexHealthBudgets` instance and an `evaluation_time`. There
are no implicit defaults; the operator decides what counts as green
per searchable embedding space, and `recommended_action` cannot
silently grant `hold` while a Q20 family fails. The library exports
`VectorIndexHealthBudgets.exampleStartingBudgets` as a documented
starting point — it is not a contract-locked threshold.

Trigger families evaluated per snapshot (per searchable embedding
space — **not** aggregated across corpora):

- **Current state**
  - 5M active vectors → yellow.
  - 8M active vectors → red.
  - Growth projection crossing 10M over the planning horizon → red,
    treated as a **projection** trigger (a 6.5M current count with a
    10M projection is red on the projection; an 8M current count
    with an 8M projection is red on the count).
- **Sustained latency regression** — Q20 fires on p50, p95, OR p99,
  and filtered HNSW latency is its own divergent signal. The helper
  evaluates four independent percentile triggers, each with its own
  yellow / red threshold:
  - `p50_latency_ms` against `budgets.p50LatencyYellowMs` /
    `budgets.p50LatencyRedMs`.
  - `p95_latency_ms` against `budgets.p95LatencyYellowMs` /
    `budgets.p95LatencyRedMs`.
  - `p99_latency_ms` against `budgets.p99LatencyYellowMs` /
    `budgets.p99LatencyRedMs`.
  - `filtered_search_behavior.filtered_p95_latency_ms` against
    `budgets.filteredP95LatencyYellowMs` /
    `budgets.filteredP95LatencyRedMs`. Filtered p95 is its own
    trigger because filtered HNSW behaviour diverges from the
    unfiltered shape; a snapshot with green unfiltered p95 but red
    filtered p95 still escalates.
- **Repeated timeouts** — `timeout_rate` against
  `budgets.timeoutRateYellow` / `budgets.timeoutRateRed`.
- **Unacceptable recall** — `recall_score` below
  `budgets.recallScoreFloorYellow` / `budgets.recallScoreFloorRed`.
- **Filtered-search divergence** — `filtered_recall_score` below
  `budgets.filteredRecallFloorYellow` /
  `budgets.filteredRecallFloorRed`. Q20 lists filtered HNSW recall
  as its own trigger family because filtered behaviour diverges
  from unfiltered.
- **Rebuild-window overrun / unsafe rebuilds** —
  `last_rebuild_duration` against `budgets.rebuildDurationYellow` /
  `budgets.rebuildDurationRed`.
- **Memory pressure** — `memory_pressure_ratio` against
  `budgets.memoryPressureYellow` / `budgets.memoryPressureRed`.
- **Stale or missing benchmark** — when `active_vectors > 0` and
  any of `p50/p95/p99_latency_ms`, `recall_score`, `timeout_rate`,
  `benchmark_timestamp`, or `filtered_search_behavior` is missing,
  OR the benchmark is older than `budgets.benchmarkStaleAfter`,
  `recommended_action` is `investigate`. The helper refuses to
  report green without evidence.

Evaluation order (red beats investigate beats yellow):

1. Current-state count and growth projection (red).
2. Operational signals against red budgets (red).
3. Build status and benchmark completeness / freshness (investigate).
4. Current-state count against the yellow line (yellow).
5. Operational signals against yellow budgets (yellow).
6. Otherwise → `hold`.

This ordering means a non-empty index with a high `timeout_rate` is
`execute_cutover`, not `investigate` — the failing operational
signal is real evidence, not an evidence gap.

The three B42 metric keys reserved for the 11A.5 health surface map
1:1 to the snapshot, keyed by `corpus_id`:

- `vector_index_size_per_corpus` ← `index_size_bytes` plus
  `active_vectors` and the yellow / red thresholds for chart
  annotations.
- `vector_query_latency_ms` ← `p50_latency_ms`, `p95_latency_ms`,
  `p99_latency_ms`, `timeout_rate`, and `benchmark_timestamp`.
- `vector_recall` ← `recall_score`, `filtered_recall_score`,
  `filtered_p95_latency_ms`, and the `filter_predicate_summary` so
  the surface can render filtered vs unfiltered behaviour
  side-by-side.

Multi-corpus aggregation is the surface's job. The helper emits one
row per `(provider_id, model_id, dimension)` partial-index slice.

## Filtered-search benchmark procedure (dry-run only)

`buildFilteredSearchBenchmarkArtifact` (in the same helper) emits a
two-file artifact pair:

- `filtered_search_benchmark.sql` — a SQL template, designed for the
  repo's psql migration channel, that wraps every measurement step
  in a single transaction, opens with `BEGIN;`, closes with
  `ROLLBACK;`, and never `COMMIT;`s. The template targets the locked
  HNSW partial index name from
  `db/migrations/202604250003_advisor_vector_search.sql` and refuses
  to emit `USING DISKANN` (Q20 dormant posture). Each measurement
  step is `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` against the same
  partial-index predicate production candidate retrieval reads —
  status `ready`, embedding present, `active = true`, plus the
  Voyage `voyage-4-large` 1024-dim triple — and applies the locked
  filter predicates (`scope`, optional `restaurant_id`).
  - The artifact uses psql variables (`:query_embedding`,
    `:scope_filter`, `:restaurant_id_filter`, `:max_results`). Each
    has a conditional fallback `\set` at the top of the file so a
    plain `psql -f filtered_search_benchmark.sql` run substitutes a
    value before any statement reaches the server. Values passed with
    `psql -v <name>=<value>` are already defined when the file is
    processed, so the fallback `\set` is skipped and the command-line
    value is preserved.
  - `:query_embedding` defaults to the bare-identifier sentinel
    `__REPLACE_ME_QUERY_EMBEDDING__`. If the operator runs the
    template without binding a real query vector, the sentinel
    reaches the server as a bare identifier and Postgres rejects it
    at parse time ("column does not exist"). That is the intended
    dry-run safety stop — do not paper over it. A zero-vector
    copy-paste fallback for syntax-only parse checks lives only in
    comments; recording benchmark numbers from a zero-vector run is
    forbidden.
  - `:scope_filter`, `:restaurant_id_filter`, and `:max_results`
    default to the helper-validated filter inputs. The validated
    values are also recorded in a human-readable comment block at
    the top of the file so the operator can verify the binds line
    up with the intended production callsite values.
  - Filter inputs are validated against strict allowlists before
    any string interpolation happens. `filterScope` must match
    `^[a-z][a-z0-9_]{0,63}$`; `filterRestaurantId` must match the
    canonical UUID 8-4-4-4-12 hex shape; `filterMaxResults` must be
    in `[1, 100]`. Any value that does not match throws
    `VectorIndexHealthException` and the artifact is not emitted.
    A value such as `'; commit; --` is refused at this layer, not
    at SQL parse time, so the dry-run safety invariant cannot be
    bypassed by attacker-controlled inputs.
- `filtered_search_benchmark.json` — an envelope JSON whose
  `snapshots[]` list mirrors the helper's snapshot shape with every
  benchmark numeric left null. The operator records measured numbers
  under the same keys (`p50_latency_ms`, `p95_latency_ms`,
  `p99_latency_ms`, `recall_score`, `filtered_search_behavior.*`)
  so the 11A.5 surface reads them through the existing field set.

CLI usage:

```
# Print a placeholder snapshot envelope to stdout (no file I/O).
dart run tool/vector_index_health/main.dart

# Emit the dry-run benchmark template pair to a directory.
dart run tool/vector_index_health/main.dart \
  --emit-benchmark --output=build/vector_index_health
```

Operator-side procedure on staging (this tool **never** runs the
template — the operator does, through the approved Phase 9 psql
migration channel):

1. Generate the artifact pair locally with `--emit-benchmark`.
2. Bind `:query_embedding` to a real query vector recorded against
   the same Voyage `voyage-4-large` model. The recommended path is
   to pass `psql -v query_embedding="'[…]'::vector(1024)"` on the
   command line (no in-file edit needed); the alternative is to
   replace the fallback `\set query_embedding` line at the top of
   the file.
   The zero-vector literal in comments is a syntax-only parse-check
   fallback and **must not** be recorded as benchmark evidence. If
   the operator skips this step, the sentinel default reaches the
   server as a bare identifier and Postgres errors at parse — that
   is the intended safety stop.
3. Override `:scope_filter`, `:restaurant_id_filter`, and
   `:max_results` to match the production callsite values via
   `psql -v <name>=<value>` (or by editing the corresponding
   fallback `\set` lines). The defaults emitted by the helper reflect the
   validated inputs from the CLI run, but the operator confirms
   they match the production query before recording benchmark
   numbers.
4. Run the SQL inside an explicit transaction:

   ```
   psql \
     -v "query_embedding='[…]'::vector(1024)" \
     -v "scope_filter='methodology'" \
     -v "restaurant_id_filter=NULL" \
     -v "max_results=10" \
     -f filtered_search_benchmark.sql
   ```

   The template starts with `BEGIN;` and ends with `ROLLBACK;` —
   keep the rollback. No row is mutated.
5. Capture p50, p95, p99 latency from the `EXPLAIN ANALYZE` output;
   capture `timeout_rate` from the surrounding harness; capture
   `recall_score` against the held-out evaluation set; capture
   `filtered_search_behavior.filtered_p95_latency_ms` and
   `filtered_search_behavior.filtered_recall_score` from the same
   filtered run. Each percentile feeds its own Q20 trigger; do not
   record p95 alone and assume the others are green.
6. Capture `last_rebuild_duration` and `memory_pressure_ratio` from
   the host signals; the helper compares them against the budgets
   to fire the rebuild-window-overrun and memory-pressure Q20
   triggers.
7. Update the envelope JSON in place, leaving `apply_mode` at
   `dry_run_template_only`, `run_channel` at `psql`, and
   `targets_index_type` at `hnsw`.
8. Re-evaluate the snapshot through the helper, passing the
   operator-tuned `VectorIndexHealthBudgets` and the current
   `evaluation_time`. If `recommended_action` returns `plan_cutover`
   or `execute_cutover`, open the cutover playbook below; otherwise
   hold.

Hard rules carried in the artifact:

- The helper never connects to a database from this repo.
- The artifact never references DiskANN as default; it targets the
  active HNSW partial index only.
- The SQL never `COMMIT;`s; production mutations cannot escape the
  template even with attacker-controlled filter inputs.
- The executable SELECT/ORDER BY reference `:query_embedding`, not
  the zero-vector literal. Operators following the documented
  substitution actually replace something the query reads.
- The `:query_embedding` default is a bare-identifier sentinel that
  Postgres rejects at parse time. A `psql -f` run without an
  override stops at the parser; it does not silently produce
  zero-vector benchmark numbers.
- The fallback `\set` lines are conditional. Command-line `psql -v`
  values are preserved and are not overwritten by the template.
- The default index strategy stays HNSW until the cutover playbook
  has run shadow → benchmark → canary on real corpus data and the
  promotion is authorized separately. B47 does not authorize that
  switch.

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
