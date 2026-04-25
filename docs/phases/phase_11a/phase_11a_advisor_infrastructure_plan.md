# Phase 11a - Agentic Advisor Infrastructure

Updated: 2026-04-25
Status: Active - 11a.7 local Voyage embeddings loaded
Owner: Future advisor infrastructure lane

Last review: 2026-04-23 - Backend stack pivoted from Firestore to Supabase Postgres with Apache AGE (graph) + pgvector (vectors). Rationale: native graph traversal via Cypher queries, native vector similarity, SQL for analytics, all in a single Postgres instance. Documented production pattern for "operational analytics + knowledge graph + semantic intelligence in a single engine" per Microsoft Azure's AGE + pgvector architecture guidance.

Current review: 2026-04-25 - `11a.0` established the active Markdown corpus
location, manifest authority, source inclusion/exclusion rules, chunking
profiles, graph node/edge taxonomy, and retrieval provenance contract. `11a.1`
added the local manifest validator plus chunk-plan dry run. `11a.2` added a
deterministic build-only materializer that emits source document, source chunk,
graph node seed, and graph edge hint records under `build/advisor_corpus/`.
`11a.3` added the Supabase/Postgres schema scaffold for those record families,
including extension prep, RLS enablement, indexes, and placeholder policies.
`11a.4` added deterministic build-only SQL load preparation: ordered upsert
files plus a load manifest under `build/advisor_corpus/load/`. `11a.5` loaded
those records into a local Supabase Postgres container and verified counts,
pending embedding state, RLS enablement, and reference integrity. `11a.6`
added a dry-run embedding job preparer, then `11a.6a` revised the provider
contract to the Claude-aligned lane: Claude/Anthropic for future advisor
answers, Voyage `voyage-4-large` for embeddings, Voyage `rerank-2.5` for
candidate reranking, and `vector(1024)` in pgvector.
Local Voyage embedding generation is now complete and loaded into the local
Supabase/Postgres container. Cloud database apply, vector search functions,
rerank calls, AGE graph creation, MCP tools, and agent UX remain future 11a/11b
work.

## Goal

Build the backend substrate for the agentic advisor: a knowledge graph of
shared methodology, a content ingestion pipeline so founders can keep
expanding the corpus, and a proxy backend + MCP tool layer (`11a.10`,
split into `10a` infra + `10b` per-operator enforcement; `10c` admin
dashboards flagged for post-100-locations; `10d` provider fallback as
locked future capability, off by default) brokering all LLM / embedding
calls and exposing per-operator live data. No user-facing surface;
purely infrastructure.

**Cadence superseded 2026-04-25.** Original 2026-04-22 framing was
"Phase 11a runs in parallel with Phase 8 / 8R / 9." That parallel
framing is now obsolete. Phase 11a now runs sequentially: resume after
`7.57` stabilization closes, run before `9.8`, per the locked build
order in `docs/phases/post_11a7_stabilization_plan.md`. By the time
Phase 9 lands, the graph + proxy + tool layer are ready so Phase 11b
(Advisor UX) is a small lift instead of a from-scratch build.

## Decisions Locked (2026-04-22 review)

- **Sequence (superseded 2026-04-25):** original framing was "11a runs
  in parallel with Phase 8 / 8R / 9." Now: 11a runs sequentially
  between `7.57` and `9.8` per the locked build cadence. Does not wait
  on auth or vendor selection. Phase 8 is blocked on vendor picks anyway,
  so 11a uses that time to build the knowledge substrate.
- **Content model:** founder-authored methodology, SOPs, handbooks, and
  training material form a shared corpus. Uploading new content expands
  the graph; new nodes + edges get discovered through ingestion. One
  canonical store, many consumers (Barrio coaching, Forge & Flow advisor).
- **Content authorship:** Vanessa primary for restaurant SOPs + training
  material. Jim Taylor + Preston Lee methodology is founder-synthesized
  from public writing. The active Jim Taylor source for 11a is the Markdown
  corpus file in `docs/Knowledge_graph_docs/`. No licensed third-party content.

- **Preston Lee methodology source:** Said will author a Preston Lee
  deep-dive doc, synthesized from public Preston Lee writing. Phase 11a
  can seed ingestion with Jim Taylor content first; Preston Lee ingests
  when the doc lands. Both co-exist in the same corpus location
  (`docs/Knowledge_graph_docs/`).

- **Corpus format standard: Markdown only.** All ingestion material must
  be Markdown. Applies to Jim Taylor deep-dive, Preston Lee deep-dive
  (authored in Markdown when it lands), Vanessa's SOPs + training
  material, and any future methodology content. Non-Markdown inputs
  (HTML, `.docx`, PDF, Google Docs) raise a flag in the ingestion pipeline
  for conversion-before-ingest; they do not silently bypass the standard.

- **Vanessa's SOP + training backlog:** The current active corpus is already
  Markdown under `docs/Knowledge_graph_docs/`, including Vanessa / operator
  training material provided for this lane. Future non-Markdown additions
  (Google Docs / `.docx` / PDF) still go through conversion-before-ingest and
  require a manifest update before they become active corpus rows.
- **Corpus storage location: Supabase Postgres (same project as Phase 9).**
  Decision locked on 2026-04-23 as part of the backend stack pivot.
  Rationale: the content model is natively multi-tenant (shared
  methodology + per-operator SOPs); Postgres with RLS handles per-operator
  scoping natively; the backend aligns with Phase 9 / 9.5 / 10a
  infrastructure; non-engineer authoring becomes a clean future path
  without repo-access gymnastics.

  - Specific backend: Supabase Postgres with Apache AGE extension (for
    graph traversal via Cypher queries) and pgvector extension (for
    vector similarity search). Both extensions loaded on the same
    Postgres instance.
  - Admin-authored writes only (Said + Vanessa); Phase 9 auth roles gate
    write access via RLS policies on corpus tables.
  - Per-operator scoping baked in from day one even with a single
    operator - shared methodology documents are operator-independent
    (null `restaurant_id` or global scope); those global rows are shared
    founder-authored methodology only, never another operator's SOPs or
    metrics. SOP / training material is operator-scoped (`restaurant_id`
    set per row; RLS enforces).
  - Dev loop uses the local Supabase stack (Docker) so dev work does not
    touch real data; no parallel-sequencing blocker vs Phase 9.

- **Graph + vector architecture: Apache AGE + pgvector on single
  Postgres instance.** Following the documented Microsoft Azure
  production pattern, methodology content is stored as:
  - Nodes and edges in Apache AGE property graph (Cypher queries for
    traversal)
  - Vector embeddings in pgvector columns on related tables (HNSW or
    IVFFlat indexes for ANN search)
  - A bridge between them: cosine similarity scores written as
    `SIMILAR_TO` edges in the AGE graph, turning vector distances into
    traversable relationships
  - One Postgres query planner, one backup strategy, one monitoring
    stack, one connection pool

- **Server hosting: dedicated backend (Cloud Run), not Cloud Functions.**
  Decision locked 2026-04-22 alongside the Phase 9 mixed-backend decision.
  Reason: MCP tool serving + graph retrieval (Phase 11a) and the future
  agent runtime (Phase 11b) do not fit Cloud Functions constraints
  (request timeouts, cold starts, lack of persistent state). Cloud
  Functions (or Supabase Edge Functions) remains the path for Phase 9
  auth admin ops; 11a/11b run on Cloud Run. Both authenticate clients
  against the same Firebase Auth and read/write the same Supabase
  Postgres (with RLS enforcement for user-scoped reads, Supabase
  service-role for admin-scoped writes that bypass RLS).

- **Per-operator scoping:** designed into the tool layer from day one
  via Postgres RLS. Enforcement lights up with Phase 9 auth (JWT claims
  scope reads); scaffolding supports single-tenant mode before then
  without throwaway rework.

## Scope

Phase 11a owns:

- Knowledge graph schema + storage
  - graph model (property graph, embedded JSON, or similar; exact
    storage decision still TBD)
  - confidence tagging (EXTRACTED, INFERRED, AMBIGUOUS) preserved
    through retrieval
  - methodology-to-formula edges so reasoning can trace a metric back to
    the principle that justifies it
- Content ingestion pipeline
  - upload / add-to-corpus flow so founders can expand the knowledge base
    without a full rebuild
  - initial corpus seeding from Jim Taylor labor model content, Preston
    Lee methodology, Vanessa's SOPs + training material, industry KPI
    definitions
  - re-ingest / update semantics so stale material can be replaced
- MCP server + tool layer (backend-only; no chat UI yet)
  - knowledge tools (graph read, concept explain, path trace)
  - operational tools (CPLH, SPLH, PPA, headcount, Sales Labor %,
    Variance, open-shift context, closed history) reading from existing
    repositories
  - per-operator scoping hooks wired through from day one
- Supabase Postgres integration for corpus persistence, using Apache
  AGE for graph traversal, pgvector for vector similarity search, and
  RLS policies for per-operator scoping. Same Postgres project as
  Phase 9 / 9.5 / 10a.

## Scope Does Not Own

Phase 11a does not own:

- agent runtime / reasoning loop (`Phase 11b`)
- Coach Chatbot UI (`Phase 11b`)
- any user-facing surface
- POS + Labor connector transport (`Phase 8`)
- reservation connector transport (`Phase 8R`)
- auth, roles, permission keys (`Phase 9`)
- Barrio UX shell (`Phase 9.75`)

## Runtime Contract

```text
founder uploads methodology / SOP / training content
-> ingestion pipeline
-> knowledge graph (nodes + edges, confidence-tagged)
-> pgvector cosine candidates
-> Voyage rerank-2.5 ordering
-> Claude answer runtime with citations / provenance

operator repositories (POS, labor, canonical facts, variance)
-> proxy backend (`11a.10a`) + MCP tool layer (read-only,
   per-operator scoping hooks via `11a.10b` enforcement)
-> ready to serve the agent runtime when Phase 11b lights up
```

## Dependencies

Required before Phase 11a can ship real:

- nothing architecturally; 11a is backend-only and can run in parallel
  with Phase 8 / 8R / 9
- corpus content from Vanessa (SOPs + training material) for meaningful
  ingestion
- Supabase Postgres project provisioned with AGE + pgvector extensions
  enabled (can start with local Supabase Docker stack for dev before
  production project is provisioned)

Consumers of Phase 11a:

- `Phase 11b` agent runtime + Coach Chatbot UX
- `Phase 9.75` coaching retrieval surfaces (My Shift coaching tip, Focus
  picker AI-assist) once 9.75 ships - retrieval happens through 11a's
  graph + tools, not through 11b's agent runtime (coaching tips are a
  simpler retrieval case than conversational chat)

## Non-Negotiables

- no vendor secrets in Flutter; MCP server mediates all external access
- no licensed third-party content in the corpus; founder-synthesized only
- per-operator scoping hooks designed in from day one even if enforcement
  waits on Phase 9
- the graph and corpus are advisory / explanatory layers only; they do not
  replace canonical operational facts, locked plans, target authority, or
  permission truth
- no user-facing surface shipped from 11a; all UX lives in 11b or
  consuming phases
- corpus format is Markdown only; non-Markdown inputs raise a
  conversion flag rather than ingesting silently
- operator-scoped corpus writes should carry audit-style write metadata
  consistent with the Phase 10a governance pattern, even though the corpus
  tables remain separate from 10a shared-state tables

## Adjacent Phases

- `Phase 8` + `Phase 8R` populate the repositories the tool layer reads;
  11a can scaffold against demo / seeded data before they land
- `Phase 9` issues the operator scope the tool layer isolates on when
  11b ships
- `Phase 9.75` Barrio coaching surfaces consume 11a's retrieval layer
- `Phase 11b` consumes 11a's graph + tools for the agent runtime

## Source Material

- [project_rag_vision.md](C:/Users/saidu/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/project_rag_vision.md)
- [Rag_Architecture.svg](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/reference/Rag_Architecture.svg)
- [corpus_manifest.yaml](C:/Git%20Local%20Repos/forge_flow_demo/docs/Knowledge_graph_docs/corpus_manifest.yaml)
- [phase_11a_0_corpus_manifest_ingestion_contract.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_0_corpus_manifest_ingestion_contract.md)
- [phase_11a_1_manifest_validator_chunk_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_1_manifest_validator_chunk_plan.md)
- [phase_11a_2_ingestion_record_materializer.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_2_ingestion_record_materializer.md)
- [phase_11a_3_supabase_corpus_storage_schema.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_3_supabase_corpus_storage_schema.md)
- [phase_11a_4_db_loader_dry_run.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_4_db_loader_dry_run.md)
- [phase_11a_5_local_db_load_verification.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_5_local_db_load_verification.md)
- [phase_11a_6_embedding_contract_provider_prep.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_6_embedding_contract_provider_prep.md)
- [phase_11a_7_embedding_execution_local_load.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_7_embedding_execution_local_load.md)
- [phase_11b_advisor_ux_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_11b/phase_11b_advisor_ux_plan.md)

## Placeholder Notes

- Graph ingestion implementation pending. `11a.0` defines the first node /
  edge taxonomy and provenance contract, and `11a.3` stages graph seed storage,
  but AGE vertex/edge creation and Cypher query shapes remain future work.
  `11a.5` confirmed the tested Supabase Postgres image has `vector` available
  but not `age`, so the schema now treats AGE extension creation as optional
  until the graph projection environment is chosen.
- Vector embedding model choice locked for the first advisor corpus pass:
  Voyage `voyage-4-large`, 1024 dimensions, cosine retrieval. This is the
  Claude-aligned path because Anthropic does not provide native Claude
  embeddings and points Claude builders to Voyage; current Voyage docs list
  `voyage-4-large` as the best general-purpose / multilingual retrieval-quality
  option. The rerank lane is also locked for the first pass: Voyage
  `rerank-2.5` orders pgvector candidate chunks before Claude receives the
  grounded context. `11a.6a` prepares embedding inputs only; real provider
execution and rerank calls remain future slices.
- Local embedding execution status: `11a.7` executed Voyage `voyage-4-large`
  embeddings for all 233 chunks using free-tier-safe batching, generated
  `embedding_updates.sql`, and loaded the vectors into the local
  Supabase/Postgres container. The local DB now reports 233 ready,
  `voyage-4-large`, non-null `vector(1024)` embeddings.
- Corpus storage live loader status. The manifest validator, chunk planner,
  build-only materializer, Supabase/Postgres schema scaffold, build-only SQL
  load-prep files, local Supabase Postgres load verification, and dry-run
  embedding job preparation are now available. Applying those files to a
  cloud/production database or calling the embedding provider still needs a
  separately scoped slice.

### Pre-ingest conversion status

The old Jim Taylor HTML conversion task is superseded. The active Jim Taylor
source for 11a ingestion is now:

- `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`

Older archive references to the retired internal Barrio docs path remain
historical unless a later content-provenance cleanup explicitly scopes them.
Runtime Dart content references are not part of this 11a.0 corpus contract
slice.
