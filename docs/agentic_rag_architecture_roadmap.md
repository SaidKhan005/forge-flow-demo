# Forge & Flow Agentic RAG — Architecture Roadmap

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
| Agent Infrastructure | Nothing | No LLM API client, no MCP server, no tool definitions, no vector store. |

## Architecture: MCP Server

The recommended approach: a **Python MCP server** that sits between
Claude and the Forge & Flow data layer.

**Why MCP:**
- graphify is already Python — server imports it directly
- MCP is Claude's native tool protocol — tools just work
- Fastest path to a working prototype
- Per-operator isolation works naturally (each operator gets their own
  server instance scoped to their database)

**How it works:**
- Claude is the reasoning layer (the "agentic model")
- The MCP server exposes tools Claude can call
- Two data sources, one server: (a) graphify knowledge graph for
  methodology, (b) SQLite for live/historical operational data
- Graph loaded once at startup. SQLite queried live per tool call.
- No embedding, no vector store — the graph IS the retrieval layer

---

## Phase 1: Knowledge Graph Evolution

**Goal:** Turn the dev-time graphify graph into a production knowledge
base the agent can query at runtime.

1. **Re-scope to domain knowledge.** Prune code-structure nodes
   (build.gradle, native shell, iOS debug, boilerplate). Keep restaurant
   concepts, methodology, and operational entities. ~100+ nodes pruned.

2. **Ingest Jim Taylor content as first-class nodes.**
   `jim_taylor_model_content.dart` has 4 modules (Foundation, Labor %,
   CPLH, SPLH & OPZ) with ~60 teaching units. Each module becomes a
   graph node with edges to the LaborModel formulas it teaches.

3. **Ingest operator SOPs.** `company_handbook_content.dart` (31KB) and
   `interview_playbook_content.dart` (25KB) — structured Dart data,
   extract as graph nodes.

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

7. **Graph = textbook, SQLite = numbers.** Methodology graph is shared
   across all operators. Per-operator data (baselines, cycles, shifts)
   stays in their SQLite database. Agent combines both at query time.

## Phase 2: MCP Server Foundation

**Goal:** Extend graphify's built-in MCP server (activated in Phase 0.2)
with SQLite operational tools.

1. **Start with graphify `--mcp`.** This already exposes graph query
   tools (query, path, explain, community_list). Phase 0.2 activates it.

2. **Extend with operational tools.** Add a companion Python MCP server
   in `mcp-server/` that reads the operator's SQLite database. Configure
   both servers in `.claude/settings.json`.

3. **Operator scoping:** `restaurantId` read from `restaurant_locations`
   table at startup. Every tool call auto-scoped. Different operators =
   different server instances.

4. **Later: merge into one server** once the tool set stabilizes. For now,
   two servers (graphify for knowledge, custom for operations) is simpler
   to iterate on.

## Phase 3: Tool Definitions

**Knowledge tools (graph-backed):**

| Tool | Input | Returns | Graph Source |
|------|-------|---------|-------------|
| `lookup_methodology` | topic string ("CPLH", "dollar gap") | Chapter content, formula explanation, coaching | BFS from matching nodes |
| `explain_metric` | metric name | Formula, what good/bad looks like | LaborModel signatures + teaching nodes |
| `coaching_recommendation` | lever ID (covers_down, cplh_down) | Methodology-grounded action for that lever | Ch10 content + lever cards |

**Operational tools (SQLite-backed):**

| Tool | Input | Returns | SQL Source |
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

1. **No tool changes needed.** Connectors write to the same SQLite tables
   the MCP server already reads (open_shift_snapshots, shift_records).

2. **Freshness is the app's responsibility.** MCP server reads SQLite at
   query time -- always gets whatever the app last wrote. `updatedAt` and
   `lastEventAt` timestamps let the agent report data freshness.

3. **Add `get_reservation_book` tool** when reservation connectors land.
   Table already exists: `reservation_book_snapshots`.

4. **Per-operator isolation scales naturally.** Each operator has their
   own SQLite database. Their MCP server instance reads only their data.

---

## Critical Files

| File | Role in RAG System |
|------|-------------------|
| `graphify-out/graph.json` | Knowledge graph -- needs domain restructuring |
| `lib/services/labor_model.dart` | Formula source -- reimplement in Python for `calculate_labor_metrics` tool |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | Schema definition (18 tables, v18) -- defines every SQL query the MCP server runs |
| `lib/internal/barrio/content/jim_taylor_model_content.dart` | Teaching content (4 modules, 60+ units) -- ingest into graph |
| `lib/internal/barrio/content/company_handbook_content.dart` | Operator SOPs -- ingest into graph |
| `lib/internal/barrio/content/interview_playbook_content.dart` | Hiring methodology -- ingest into graph |
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
