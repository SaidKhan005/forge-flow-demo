# Phase 11a - Agentic Advisor Infrastructure

Updated: 2026-04-23
Status: Planned
Owner: Future advisor infrastructure lane

Last review: 2026-04-23 - Backend stack pivoted from Firestore to Supabase Postgres with Apache AGE (graph) + pgvector (vectors). Rationale: native graph traversal via Cypher queries, native vector similarity, SQL for analytics, all in a single Postgres instance. Documented production pattern for "operational analytics + knowledge graph + semantic intelligence in a single engine" per Microsoft Azure's AGE + pgvector architecture guidance.

## Goal

Build the backend substrate for the agentic advisor: a knowledge graph of
shared methodology, a content ingestion pipeline so founders can keep
expanding the corpus, and an MCP tool layer exposing per-operator live
data. No user-facing surface; purely infrastructure.

Phase 11a runs in parallel with Phase 8 / 8R / 9 since it is backend-only
and does not gate on auth or vendor transport. By the time Phase 9 lands,
the graph and tool layer are ready so Phase 11b (Advisor UX) is a small
lift instead of a from-scratch build.

## Decisions Locked (2026-04-22 review)

- **Sequence:** 11a runs in parallel with Phase 8 / 8R / 9. Does not wait
  on auth or vendor selection. Phase 8 is blocked on vendor picks anyway,
  so 11a uses that time to build the knowledge substrate.
- **Content model:** founder-authored methodology, SOPs, handbooks, and
  training material form a shared corpus. Uploading new content expands
  the graph; new nodes + edges get discovered through ingestion. One
  canonical store, many consumers (Barrio coaching, Forge & Flow advisor).
- **Content authorship:** Vanessa primary for restaurant SOPs + training
  material. Jim Taylor + Preston Lee methodology is founder-synthesized
  from public writing (same approach as existing
  `docs/internal/barrio/jim_taylor_labor_model_deep_dive.html`). No
  licensed third-party content.

- **Preston Lee methodology source:** Said will author a Preston Lee
  deep-dive doc, synthesized from public Preston Lee writing. Phase 11a
  can seed ingestion with Jim Taylor content first; Preston Lee ingests
  when the doc lands. Both co-exist in the same corpus location
  (`docs/internal/barrio/` or whatever corpus location gets decided).

- **Corpus format standard: Markdown only.** All ingestion material must
  be Markdown. Applies to Jim Taylor deep-dive (existing HTML gets
  converted to Markdown before ingestion), Preston Lee deep-dive
  (authored in Markdown from day one), Vanessa's SOPs + training
  material, and any future methodology content. Non-Markdown inputs
  (HTML, `.docx`, PDF, Google Docs) raise a flag in the ingestion pipeline
  for conversion-before-ingest; they do not silently bypass the standard.

- **Vanessa's SOP + training backlog:** Vanessa authors in docs
  (Google Docs / `.docx`). A backlog of existing material has already
  been sent to Said but not yet uploaded to the repo. Initial ingestion
  is a bulk dump of that backlog, followed by incremental additions over
  time as Vanessa produces new material. Phase 11a ingestion pipeline
  must support both the one-time bulk seed and the ongoing incremental
  add-to-corpus flow, with docs-to-Markdown conversion in-line.
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

operator repositories (POS, labor, canonical facts, variance)
-> MCP tool layer (read-only, per-operator scoping hooks)
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
- [rag_stack.svg](C:/Git%20Local%20Repos/forge_flow_demo/docs/business/rag_stack.svg)
- [jim_taylor_labor_model_deep_dive.html](C:/Git%20Local%20Repos/forge_flow_demo/docs/internal/barrio/jim_taylor_labor_model_deep_dive.html)
- [phase_11b_advisor_ux_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_11b/phase_11b_advisor_ux_plan.md)

## Placeholder Notes

- Graph schema design pending (node types, edge types, property
  conventions on Apache AGE); decision during implementation spec pass
- Vector embedding model choice pending (OpenAI, Cohere, Voyage, or
  local); affects pgvector dimension and retrieval quality; decision
  during implementation spec pass
- Tracker folding: add to `PROJECT_TRACKER.md` Active Planning Docs list
  on next Codex pass

### Pre-ingest conversion task (Jim Taylor HTML -> Markdown)

Before 11a ingestion starts, the existing HTML deep-dive must be converted
to Markdown per the corpus-format standard. Touched surfaces:

- `docs/internal/barrio/jim_taylor_labor_model_deep_dive.html` -> convert
  to `jim_taylor_labor_model_deep_dive.md` (keep filename stem, change
  extension)
- `lib/internal/barrio/content/jim_taylor_model_content.dart` - update
  `// Source:` comment path (provenance metadata only; no runtime impact)
- `lib/internal/barrio/content/barrio_source_material.dart` - update
  `repoPath:` field to the new `.md` path
- `README.md` - update the repo-guide link
- Archive docs under `docs/archive/**` reference the HTML path
  historically; leave as-is (historical truth, not active authority)

This task is small but should land before ingestion runs so the corpus
is consistent from day one.
