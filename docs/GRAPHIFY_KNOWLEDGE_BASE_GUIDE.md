# Graphify Knowledge Base Guide

## What It Is

A persistent knowledge graph (`graphify-out/graph.json`) mapping every concept, relationship, and rationale across the Forge & Flow / Barrio codebase and documents. It survives across sessions and grows incrementally.

**Current state:** 312 nodes, 611 edges, 28 communities.
**Token benchmark:** 593x reduction — queries cost ~1,400 tokens vs ~830K to read the full corpus.

## Outputs

All outputs live in `graphify-out/`:

| File | What It Is |
|------|-----------|
| `graph.html` | Interactive visual graph — open in any browser |
| `graph.json` | Raw graph data (nodes, edges, communities) — the persistent store |
| `GRAPH_REPORT.md` | Audit report with god nodes, surprising connections, community clusters |
| `cost.json` | Cumulative token cost tracker across all runs |

## Daily Usage

### Query the knowledge base
```
/graphify query "how does PPA connect to the Jim Taylor model"
/graphify query "what does the interview playbook share with the handbook" --dfs
/graphify explain "LaborModel"
/graphify path "CPLH" "Dollar Gap"
```

### Add new knowledge
When you add new files to the repo (coaching content, PDFs, teaching modules):
```
/graphify C:\Git Local Repos\forge_flow_demo --update
```
Only re-extracts changed/new files. The graph grows without rebuilding.

To add a URL (article, paper, tweet):
```
/graphify add https://example.com/article --author "Author Name"
```

### Rebuild from scratch
```
/graphify C:\Git Local Repos\forge_flow_demo
```

### Re-cluster without re-extracting
```
/graphify C:\Git Local Repos\forge_flow_demo --cluster-only
```

## Key Communities (What the Graph Knows)

| Community | Nodes | Domain |
|-----------|-------|--------|
| SQLite + Persistence Layer | 55 | Schema, migrations, DAOs, repositories, notifiers, services |
| Shift Data Pipeline | 41 | ShiftRecord, ClosedShiftInput, ShiftFact, ActiveTargetProfile, canonical data flow |
| Barrio UI System | 35 | Jim Taylor Model Screen, Barrio widgets, destinations, navigation, celebration overlay |
| Jim Taylor Teaching Content | 24 | CPLH, SPLH, PPA, OPZ, Dollar Gap, labor %, death spiral, 60-day tracking |
| Legacy Fixture + Presentation | 22 | MeridianConfig, BaselineData, AppTheme, screens, widgets consuming design tokens |
| Barrio App + Vendor Integrations | 20 | BarrioApp root, Oracle Simphony, Push Operations, Firebase Auth, ExternalIdentityLink |
| Company Handbook Content | 20 | Handbook chapters, mission/values, conduct, safety, operations, scheduling |
| Interview Playbook Content | 18 | Hiring principles, 5-stage flow, green/red flags, position-based questions |

## How This Feeds Phase 10

The graph is the structured knowledge layer for the AI Coaching Agent:

1. **Staff asks "why was my PPA low?"** -> Agent traverses: PPA node -> Jim Taylor Ch. 5 -> LaborModel formulas -> grounded in actual shift data
2. **Manager asks "draft interview questions for a bartender"** -> Agent traverses: Bartender Questions node -> Interview Playbook -> Green/Red Flags Framework -> Core Values
3. **Workflow generates weekly P&L summary** -> Agent traverses: Dollar Gap -> LaborModel -> CPLH/SPLH -> shift pipeline

Instead of dumping 2,000+ lines of raw content into a system prompt, the agent queries a graph it can navigate — finding relevant knowledge in ~1,400 tokens.

## Known Gaps (To Fix)

- **App-to-teaching-content links missing:** The Barrio App node has no path to Jim Taylor, Company Handbook, or Interview Playbook. The connection lives in Dart screen files that import content files — needs an `--update` run targeting `lib/internal/barrio/`.
- **Barrio content files not yet in graph:** `jim_taylor_model_content.dart`, `company_handbook_content.dart`, `interview_playbook_content.dart` (2,155 lines of structured teaching units) need explicit extraction.
- **Jim Taylor deep dive HTML** (`docs/internal/barrio/jim_taylor_labor_model_deep_dive.html`) not yet ingested.

## Evolving the Knowledge Base

As content grows, run `/graphify --update` after adding:
- New coaching tactic libraries
- Restaurant-specific coaching notes from managers
- New PDF training materials
- Updated handbook or playbook content
- Menu knowledge docs
- New teaching modules in `lib/internal/barrio/content/`

The graph captures what changed and merges it into the existing structure. Queries against older content still work — new content just adds more nodes and edges.
