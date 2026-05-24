# Advisor Knowledge Activation — Master Plan

> **Created:** 2026-05-24. **Owner:** orchestrator (this session) drives
> slicing, prompt emission, audit, merge. Worker agents execute in
> isolated worktrees per CLAUDE.md "Agent-led slices".
>
> **Status:** Active. Wave 1 dispatched 2026-05-24.

Companion design artifact (the agreed look-and-feel target for the admin
surface): `docs/_mockups/knowledge_base_redesign_preview.html`.

## Why this exists

The advisor knowledge base is **schema-complete and data-loaded in
staging, but unused at runtime, and its rich layer is empty.** Verified
live against Azure staging Postgres (Canada Central) on 2026-05-24 with
read-only counts:

- `advisor_source_documents` = 8; `advisor_source_chunks` active = 233.
- Voyage embeddings ready = 233 (`voyage-4-large`, 1024-dim, HNSW cosine).
- Contextual-retrieval `chunk_context` filled on all 233.
- Extensions live: `vector` 0.8.2, `age` 1.6.0, `pg_diskann` 0.6.4.
- Simple graph seeds populated: `advisor_graph_node_seeds` = 241,
  `advisor_graph_edge_hints` = 233 (Document -CONTAINS-> Chunk); AGE
  projection has 233 doc/chunk pairs.

**The three gaps this plan closes:**

1. **Advisor does not use the knowledge.** `advisor_search_chunks()` SQL
   exists with no caller; `VoyageRerankProvider` exists but is not wired;
   the answer flow has no corpus retrieval. (Workstream A.)
2. **Admin screen is machine-flavored and only half-real.** The corpus
   admin screen works mechanically but reads as code; the document side
   has real data behind it and is buildable now. (Workstream B.)
3. **Rich graph is empty + switched off.** Canonical `public.graph_nodes`
   = 0 and `public.graph_edges` = 0; the admin graph-candidates review
   route returns 503 `graph_candidates_not_configured`; AGE rebuild is a
   501 stub; rich typed nodes/edges need semantic extraction. (Workstream
   C.)

## Authority + promises this advances

- Defers to `docs/contracts/core_app_architecture.md` and the Tier-2
  contracts (Authority Order). Advances **Phase 11b** ("Advisor launches
  with Contextual Retrieval", HP #5) and honors **HP #6** (advisor speaks
  recommendations, not commands), **HP #7** (proxy brokers all provider
  calls server-side; query embedding is server-side), **HP #9** (AI cost
  metered by class).
- **CI dark until 2026-06-01** (`feedback_ci_dark_until_2026_06_01.md`):
  high-risk merges run `tool/pre_merge_gate.sh` + `tool/verify_pr_landed.sh`.

## Hard constraints (read before dispatching any lane)

- **Proxy is at its size ceiling.** `tool/advisor_proxy/advisor_proxy.dart`
  is 18,871 lines against a 19,071 bleed-stop ceiling (~200 spare,
  enforced by `tool/advisor_proxy_size_lint.dart`). **No lane may grow the
  monolith into the ceiling.** Proxy-facing work lands in NEW sibling
  files (`tool/advisor_proxy/<feature>_*.dart`) with a thin registration.
  A `kAdvisorProxyMaxLines` raise needs explicit operator approval
  (Ceiling-raise rule R-2). If a slice cannot fit, the agent STOPS and
  reports.
- **One proxy-touching lane active at a time.** Proxy is a single
  high-contention surface (Cost & Convergence #3). Never run two
  proxy-editing agents in parallel.
- **One admin-screen-editing lane at a time.** Workstream B slices all
  touch `lib/admin/screens/corpus_admin_screen.dart` + siblings; serialize
  within the lane.
- **Operator-gated merges:** any slice touching the proxy, a migration
  (schema), RLS, or auth merges ONLY with explicit operator approval,
  regardless of audit verdict.

## Workstreams + slices

Gate legend: `auto` = orchestrator merges when audit clean; `op-gated` =
needs explicit operator approval to merge.

### Workstream A — Advisor actually uses the knowledge (Phase 11b)

| Slice | Scope | Surface | Gate | Depends | Parallel-safe |
|---|---|---|---|---|---|
| A1 | Corpus retrieval service + Postgres repo method calling `advisor_search_chunks()` for a supplied query embedding; unit tests with a fake gateway. NO proxy, NO schema. | `lib/services/**`, `lib/infrastructure/persistence/postgres/**`, `test/**` | auto | — | YES |
| A2 | Server-side query embedding (runtime Voyage) + a `/v1/advisor/retrieve` route as a NEW sibling proxy file; thin registration only. Respects the proxy ceiling. | new `tool/advisor_proxy/advisor_retrieve_*.dart` + minimal registration | op-gated (proxy) | A1 | NO (proxy) |
| A3 | Rerank (`voyage-rerank-2.5`) + hybrid order (vector + BM25 contextual leg) in the retrieval path. | sibling proxy file + `lib/services/voyage_rerank_provider.dart` wiring | op-gated (proxy) | A2 | NO (proxy) |
| A4 | Advisor answer generation over retrieved context (Claude tier-routed), recommendation-style per HP #6. Likely its own sub-plan. | sibling proxy file + `lib/services/claude_llm_provider.dart` | op-gated (proxy) | A2/A3 | NO (proxy) |

### Workstream B — Admin document-side redesign (buildable now, real data)

| Slice | Scope | Surface | Gate | Depends | Parallel-safe |
|---|---|---|---|---|---|
| B1 | Replace paste-markdown upload with a real file picker (reuse `lib/operator_web/services/business_logo_file_picker_web.dart` pattern) + drag-drop; wire into `_buildCorpus`. Keep demo "sample file" path for kDemoMode. | `lib/admin/screens/corpus_admin_screen.dart`, new `corpus_file_picker_web.dart`, `lib/admin/admin_routes.dart` | auto | — | YES |
| B2 | Plain-English + professional outlined-icon pass on the corpus screen; move machine IDs/hashes under an "advanced/technical details" disclosure (off by default). No em-dash law applies. | corpus admin screen + sibling widgets | auto | B1 | NO (same screen) |
| B3 | "Sections" view at scale: render a version's chunks grouped by source document with heading-path names + search/filter/grouping (on the real 8 docs / 233 chunks). | corpus admin screen + sibling widgets | auto | B2 | NO (same screen) |

### Workstream C — Rich connections + typed topics

| Slice | Scope | Surface | Gate | Depends | Parallel-safe |
|---|---|---|---|---|---|
| C1 | Un-pause graph-candidates: configure the proxy gateway so `GET /v1/admin/corpus/graph-candidates` serves the existing candidate JSONL and `commit-batch` writes approved nodes/edges to canonical `graph_nodes`/`graph_edges`. | proxy (sibling file) + `lib/infrastructure/persistence/postgres/repositories/graph_repository.dart` | op-gated (proxy + writes canonical graph) | — (but serialize vs A proxy lanes) | NO (proxy) |
| C2 | Connections review UI redesign (mockup's "Connections" tab): connection cards, plain-English relationship picker, focus map, bulk approve, scale filters. | corpus admin screen + sibling widgets | auto | C1 | NO (same screen as B) |
| C3 | Semantic extraction (Phase 12): produce typed nodes/edges (Concept/SOP/Metric/Formula; INFORMS/CAUSES/...); expand the approved node/edge vocabulary; migrations. Large; likely its own sub-plan. | `tool/advisor_corpus/**`, `db/migrations/**` | op-gated (schema) | C1 | NO (schema chain) |

## Wave schedule

The serialize-the-proxy and one-screen-at-a-time rules drive this.

- **Wave 1 (dispatched 2026-05-24, parallel, auto-merge after audit):**
  **A1** (retrieval service, new lib files) + **B1** (file picker,
  frontend). Non-overlapping surfaces, neither gated. Two agents.
- **Wave 2 (after Wave 1 merges):** **B2** (frontend, serialized on the
  screen) + **A2** (the single proxy lane this wave, op-gated). C1 waits.
- **Wave 3:** **B3** (frontend) + one proxy lane (**A3** or **C1**, not
  both). The other proxy lane moves to Wave 3b.
- **Wave 4+:** **A4**, **C2** (needs C1), **C3** (Phase 12, op-gated,
  likely sub-planned separately).

## Orchestration protocol

- Each slice = one worker agent in its own worktree. Contract:
  `branch → install hooks → implement → self-audit → commit + push →
  open PR → STOP`. Agents MUST NOT merge, MUST NOT `--no-verify`, MUST NOT
  edit trackers, MUST NOT raise the proxy ceiling.
- Orchestrator audits each PR (Pattern B: worker self-audit + independent
  audit, both with file:line citations), runs `tool/pre_merge_gate.sh`
  for high-risk PRs while CI is dark, merges clean PRs (op-gated ones only
  after operator approval), then `tool/verify_pr_landed.sh` to confirm
  content landed on `origin/master`.
- Status for each slice tracked in this doc's tables (orchestrator-owned).

## Open operator decisions (revisit as waves advance)

1. **Rich kinds vs lean** (C2/C3): expose Metric/Formula/Word-to-know/
   Coaching-move (matches the docs' `graph_profiles`, needs vocabulary
   expansion + C3 extraction) vs lean set (Concept/SOP=Procedure/Policy/
   Role/Risk only). SOP is a free relabel of the existing "Procedure".
2. **A4 scope:** is answer-generation in this initiative, or does this
   initiative stop at retrieval (A1-A3) and hand answer-generation to the
   Phase 11b advisor-launch plan?
3. **Proxy ceiling:** confirm "new sibling files only, no raise" stance,
   or pre-approve a one-time `kAdvisorProxyMaxLines` raise for A2/A3/C1.
