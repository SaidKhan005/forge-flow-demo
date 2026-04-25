# Forge & Flow Agentic RAG - Architecture Roadmap

## 2026-04-25 Alignment Note

This document is retained as the early Graphify/MCP roadmap, but the active
implementation authority is now `docs/phases/phase_11a/`. The current lane is:

```text
Markdown corpus in docs/Knowledge_graph_docs
-> Supabase Postgres corpus tables
-> pgvector cosine candidate retrieval with Voyage voyage-4-large embeddings
-> Voyage rerank-2.5
-> Claude / Anthropic advisor answer runtime with citations
```

Graphify remains useful dev-time context. It is no longer the production
retrieval plan by itself.

## Context

The long-term goal is to turn Forge & Flow into an agentic system with
three layers:

1. **RAG (Knowledge Graph)** — Jim Taylor's methodology, operator SOPs,
   and location baselines stored as nodes and edges. Shifts connect to
   managers, managers to locations, locations to baselines, baselines to
   methodology. Query-time graph traversal pulls relevant context.

2. **Tools** — Live and historical operational data (CPLH, SPLH, POS,
   scheduled headcount) fetched in real time during the agentic loop.
   Called dynamically based on what the question requires.

3. **Agentic Model** — Reasons over graph knowledge + live tool data.
   Never permanently stores data. Every query assembles context fresh.
   Per-operator data isolation and privacy.

## What's Already Active

| Capability | Status | What It Does |
|-----------|--------|--------------|
| `post-commit` hook | ACTIVE | Rebuilds graph (code files only, no LLM) after every commit |
| `post-checkout` hook | ACTIVE | Rebuilds graph when switching branches |
| `pre-commit` hook | ACTIVE | Runs `flutter analyze` before allowing commits |
| PostToolUse hook | ACTIVE | Notifies when Barrio content / teaching / LaborModel files are edited |
| `/graphify` skill | ACTIVE | Available in Claude Code sessions |
| `graphify-out/` | ACTIVE | 364 nodes, 409 edges, 54 communities, HTML viz, audit report |

| Capability | Status | Notes |
|-----------|--------|-------|
| `graphify claude install` | NOT DONE | Would add PreToolUse hook (graph-aware assistant) |
| `graphify --mcp` | NOT CONFIGURED | Would start MCP server exposing graph query tools |
| `graphify --wiki` | NOT RUN | Would generate agent-crawlable wiki from communities |
| `graphify --directed` | NOT RUN | Would preserve edge direction (source->target) |
| `graphify --neo4j` | NOT NEEDED YET | Production graph database — Phase 5 |
| `graphify --obsidian` | OPTIONAL | Visual knowledge management — nice-to-have |

---

## Phase 0: Activate Now

These four actions wire graphify into the daily workflow and lay the
foundation for the RAG roadmap. No new code. Just configuration.

### 0.1 — `graphify claude install`

**What it does:** Adds a PreToolUse hook to `.claude/settings.json` and
a graphify section to CLAUDE.md. This makes Claude graph-aware in every
session — before modifying code, Claude checks the knowledge graph for
relevant context.

**Why now:** The graph already has 364 nodes of domain knowledge. Making
Claude consult it before changes means better-informed edits today, and
validates the graph quality as you build toward full RAG.

**Command:** `graphify claude install`

### 0.2 — `graphify --mcp` (MCP server)

**What it does:** Starts a graphify MCP stdio server that exposes graph
query tools (`query`, `path`, `explain`, `community_list`) to Claude.
Configure it in `.claude/settings.json` so it launches automatically.

**Why now:** This is literally Phase 2 of the roadmap — a working MCP
server for graph queries. graphify already ships it. Instead of building
a custom MCP server from scratch, start with graphify's built-in one
and extend it later with SQLite operational tools.

**Configuration (add to `.claude/settings.json`):**
```json
"mcpServers": {
  "graphify": {
    "command": "graphify",
    "args": [".", "--mcp"]
  }
}
```

### 0.3 — `graphify --wiki`

**What it does:** Generates an agent-crawlable wiki — one markdown
article per community, plus an index. Organized by topic, not by file.

**Why now:** The wiki is a human-readable validation of graph quality.
If the communities make sense (Jim Taylor methodology in one cluster,
domain models in another, time boundary rules in another), the graph
is ready for RAG retrieval. If they don't, you know what to fix before
building tools on top.

**Command:** `graphify . --wiki`

### 0.4 — `graphify --directed` (next full rebuild)

**What it does:** Preserves edge direction (source -> target) instead
of treating all edges as bidirectional. This matters for traversal
queries like "what does CPLH depend on?" vs "what depends on CPLH?"

**Why now:** Directional edges are required for the coaching traversal
path in Phase 1.5 (`CPLH metric -> Ch5 teaching -> formula -> coaching`).
Run this on the next full rebuild, not as a separate step.

**Command (next full rebuild):** `graphify . --directed`

---

## Current State

| Layer | Status | What Exists |
|-------|--------|-------------|
| Knowledge Graph | Dev-time only | graphify: 364 nodes, 409 edges, 54 communities in `graphify-out/graph.json`. Mostly code-structure mapping. |
| Domain Model | Production-ready | 18+ entity types, 13 repositories, full SQLite persistence (schema v18). |
| Formulas | Complete | `lib/services/labor_model.dart` — CPLH, SPLH, PPA, theoretical labor %, dollar gap, lever detection. |
| Teaching Content | Exists, not in graph | `lib/internal/barrio/content/jim_taylor_model_content.dart` (4 modules, ~60 teaching units), handbook, playbook. |
| Live Data | Models exist, no connectors | OpenShiftSnapshot, ReservationBookSnapshot tables ready. Phase 8 blocked on vendor selection. |
| Agent Infrastructure | 11a in progress | Markdown manifest, chunk planner, materializer, Supabase/Postgres staging schema, local DB load, and dry-run Voyage embedding/rerank contract are landed. No runtime MCP server or UX yet. |

## Architecture: MCP Server

The recommended approach is now a dedicated advisor tool/runtime service that
sits between Claude and the Forge & Flow data layer. The service can still use
MCP-style tools, but the production corpus is the Phase 11a Supabase/Postgres
store, not only the local graphify JSON.

**Why MCP:**
- MCP is Claude's native tool protocol - tools just work
- Fastest path to a working prototype
- Per-operator isolation works naturally (each operator gets their own
  authenticated scope against the backend data layer)

**How it works:**
- Claude is the reasoning layer (the "agentic model")
- The MCP server exposes tools Claude can call
- Two data sources, one service: (a) Phase 11a corpus retrieval for
  methodology, (b) operational repositories for live/historical data
- Retrieval is hybrid: pgvector candidates, Voyage rerank, graph/provenance
  context, then Claude answers.

---

## Phase 1: Knowledge Graph Evolution

**Goal:** Turn the dev-time graphify graph into a production knowledge
base the agent can query at runtime.

1. **Re-scope to domain knowledge.** Prune code-structure nodes
   (build.gradle, native shell, iOS debug, boilerplate). Keep restaurant
   concepts, methodology, and operational entities. ~100+ nodes pruned.

2. **Ingest Jim Taylor content as first-class nodes.**
   The active source is Markdown in
   `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`, governed
   by `corpus_manifest.yaml`.

3. **Ingest operator SOPs.** Active SOP/training material is Markdown under
   `docs/Knowledge_graph_docs/` and enters the corpus only through the
   manifest. Non-Markdown material must be converted before ingestion.

4. **Add methodology-to-formula edges.** Connect domain entities to
   teaching content: `TargetCycle --implements--> "60-day benchmark
   concept"`, `LaborModel.dollarGap --implements--> "Chapter 10
   variance"`, etc.

5. **Add baseline-to-methodology traversal path.** The core agent query
   path: operator asks "why is my CPLH low?" -> agent walks
   `CPLH metric -> Ch5 teaching -> covers/hours formula -> coaching`.

6. **Define stable query API.** graphify already has BFS/DFS/path-finding.
   Expose as `query_graph(question, budget_tokens=1500)`. Current 593x
   compression ratio means ~1,400 tokens per query vs 830K full corpus.

7. **Corpus/graph = textbook, operational repositories = numbers.**
   Methodology corpus rows are shared founder-authored truth. Per-operator
   data (baselines, cycles, shifts) stays isolated in the app/backend data
   layer. The agent combines both at query time.

## Phase 2: MCP Server Foundation

**Goal:** expose corpus retrieval and operational data as tools Claude can call.

1. **Start with Phase 11a retrieval.** Use pgvector cosine candidate search,
   Voyage rerank, and graph/provenance context from the staged corpus tables.

2. **Add operational tools.** Expose read-only tools over the canonical app
   repositories so the agent can fetch current shift, target, plan, variance,
   and history data.

3. **Operator scoping:** every tool call is scoped by the authenticated
   operator/restaurant identity from the Phase 9 auth layer.

4. **Graphify remains optional dev context.** It can help inspect graph shape,
   but it is not the only retrieval layer in production.

## Phase 3: Tool Definitions

**Knowledge tools (graph-backed):**

| Tool | Input | Returns | Graph Source |
|------|-------|---------|-------------|
| `lookup_methodology` | topic string ("CPLH", "dollar gap") | Chapter content, formula explanation, coaching | BFS from matching nodes |
| `explain_metric` | metric name | Formula, what good/bad looks like | LaborModel signatures + teaching nodes |
| `coaching_recommendation` | lever ID (covers_down, cplh_down) | Methodology-grounded action for that lever | Ch10 content + lever cards |

**Operational tools (repository-backed):**

| Tool | Input | Returns | Source |
|------|-------|---------|-----------|
| `get_current_shift` | (none) | Open/projected shift state | `open_shift_snapshots` |
| `get_shift_history` | date range or week ID | Closed shift records with all metrics | `shift_records` |
| `get_active_targets` | (none) | TargetCycle: locked CPLH, SPLH, PPA, wages, OPZ | `target_cycles` |
| `get_weekly_plan` | week key or "current" | Locked plan: forecast, required hours, theoretical % | `weekly_plan_snapshots` |
| `get_variance_summary` | week ID or "current" | WTD actuals vs plan, dollar gap, primary lever | `shift_records` + `weekly_plan_snapshots` + formulas |
| `get_learn_patterns` | N weeks | Recurring leak pattern, benchmark daypart summary | `shift_records` grouped by lever |
| `calculate_labor_metrics` | covers, PPA, hours, wages, targets | CPLH, SPLH, model hours, labor %, dollar gap | Pure math (no DB) |

## Phase 4: Agent Behavior

1. **System prompt:** Claude is a labor management advisor grounded in
   Jim Taylor's methodology. Under 500 tokens. Never guesses numbers.

2. **Retrieval logic (baked into system prompt):**
   - "What does X mean?" -> `lookup_methodology` first, then optionally
     operational tool to ground in their numbers
   - "How did we do?" -> operational tools first, then
     `coaching_recommendation` with the detected lever

3. **Response format:** Plain language for restaurant operators. No code
   blocks. Use their actual numbers. Use Jim Taylor vocabulary (covers
   per labor hour, model hours, primary lever, operating zone, dollar gap).

4. **Never fabricate:** If data needed, call a tool. If no data exists
   (no closed shifts yet), say so plainly.

## Phase 5: Live Data Integration

**Goal:** When Phase 8 vendor connectors land, the agentic system
consumes live data without architectural changes.

1. **No retrieval contract changes needed.** Connectors write into the same
   canonical operational facts the advisor tools read.

2. **Freshness is the app/backend responsibility.** Advisor tools read at
   query time and report `updatedAt` / `lastEventAt` style freshness metadata.

3. **Add `get_reservation_book` tool** when reservation connectors land.
   Table already exists: `reservation_book_snapshots`.

4. **Per-operator isolation scales through auth/RLS.** Each operator's reads
   are scoped by the Phase 9 identity and backend policies.

---

## Critical Files

| File | Role in RAG System |
|------|-------------------|
| `docs/Knowledge_graph_docs/corpus_manifest.yaml` | Active corpus authority for 11a ingestion |
| `build/advisor_corpus/` | Deterministic generated corpus records and dry-run embedding job artifacts |
| `supabase/migrations/202604250001_advisor_corpus_storage_schema.sql` | Advisor corpus table schema, pgvector extension, optional AGE staging |
| `supabase/migrations/202604250002_advisor_embedding_contract.sql` | Voyage `voyage-4-large` / `vector(1024)` embedding contract |
| `lib/services/labor_model.dart` | Formula source -- reimplement in Python for `calculate_labor_metrics` tool |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | Schema definition (18 tables, v18) -- defines every SQL query the MCP server runs |
| `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md` | Active Jim Taylor methodology source for the advisor corpus |
| `docs/Knowledge_graph_docs/` | Active founder-authored global methodology / SOP corpus |
| `docs/phases/phase_8_gate/source_ownership_matrix.md` | Field-level ownership map -- governs live data integration |
| `.claude/settings.json` | Hook and MCP server configuration |
| `.claude/hooks/graphify-content-sync.sh` | PostToolUse hook -- notifies on teaching content edits |

## What NOT to Activate Yet

| Capability | Why Not |
|-----------|---------|
| `--watch` | Redundant with post-commit/post-checkout hooks. User prefers graphify on commits only. |
| `--neo4j` | Production graph database -- needed when operator data scales beyond JSON. Phase 5. |
| `--obsidian` | Nice-to-have visual reference. Not on the critical path. |
| `graphify add <url>` | Wait until specific external content is identified for ingestion. |

## Verification (Phase 0)

After running the four Phase 0 commands:

1. **`graphify claude install`** -- check that `.claude/settings.json`
   has a new PreToolUse hook and CLAUDE.md has a graphify section.
2. **`graphify --mcp`** -- restart Claude Code, check that graphify
   MCP tools appear (query, path, explain). Test with:
   `graphify query "what is CPLH?"` via the MCP tool.
3. **`graphify --wiki`** -- check `graphify-out/wiki/` exists with
   `index.md` and per-community articles. Spot-check that community
   labels make sense for domain knowledge.
4. **`graphify --directed`** -- on next full rebuild, verify edges in
   `graph.json` have `source` and `target` fields instead of just
   node pairs.
