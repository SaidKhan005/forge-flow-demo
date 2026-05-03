# Phase 11b - Agentic Advisor UX

Updated: 2026-05-03
Status: Planned (gated on B43 prod anchor deploy; `11A.5` Debug Console and `11A.6` observability dashboard both accepted)
Owner: Future advisor UX lane

## 2026-04-28 - Phase 9 Foundation Dependencies

`9.0Σ.h` `advisor_conversation_log` table is merged via `fe14b31` (B29 in
`phase_9_execution_backlog.md`). Before any advisor turn writes a row:

- B46 is local/code/test complete: encryption-key reference, audit-privacy
  permission gate, and paired audit-on-read are documented in
  `docs/contracts/advisor_conversation_log_contract.md`.
- Before live advisor writes depend on this path, apply
  `202604280014_phase_9_0sigma_h2_audit_privacy_role.sql` to staging +
  Production1 under a fresh live-mutation gate. CMK provisioning
  (`cutover.0a`) must be live before encrypted writes start.

`11b.2` causal traversal depends on `9.0Σ.i` graph_canonical (B30
merged) plus the tripwire metric exposure + projection rebuild runbook
in B44. B44 helper/runbook evidence and producer wiring into the B42
health envelope exist; `11A.6` now has the bounded observability surface.
Read both before drafting `11b.2` prompts.

`11b` advisor retrieval depends on `9.0Σ.j` pgvector HNSW (B31 merged)
plus B47 vector health helper + filtered-search benchmark artifact. The
helper/benchmark shape and producer wiring into the B42 health envelope
exist; live benchmark evidence remains a producer/proxy cutover concern. The
HNSW->DiskANN switch trigger doc names exact thresholds.

## Goal

Ship the agentic advisor as an operator-facing product: a stateless agent
runtime that reasons over the Phase 11a knowledge graph plus per-operator
live data via MCP tools, surfaced through Coach Chatbot UIs inside Barrio
and Forge & Flow. Every query assembles fresh context; the model retains
nothing.

This is the product's core differentiator: an assistant that understands
how each restaurant actually operates, not one that retrieves similar text.

## Decisions Locked (2026-04-22 review)

- **Sequence:** 11b ships after Phase 11a (infrastructure) and Phase 9
  (auth) per the sequential build cadence locked 2026-04-25. Forge &
  Flow manager chat can ship before Phase 9.75; the Barrio manager /
  staff chat surfaces light up once the Barrio shell exists. With
  Phase 11a's infrastructure (graph + proxy + MCP tool layer) closed
  before 11b opens, 11b is a small UX lift, not a from-scratch build.
- **Operator isolation:** enforced via Phase 9 auth. No query can retrieve
  or reason about another operator's numbers. This is a non-negotiable.
- **Stateless reasoning:** the model retains nothing between queries. Every
  answer assembles context fresh from 11a's graph + tools.
- **Model lane:** advisor answers run through Claude / Anthropic. Phase 11a
  ships the **Modular Adaptive Agentic RAG** stack locked 2026-04-26
  (`phase_11a_decision_register.md` "Retrieval Posture"): Haiku classifier
  routes the question to one of three retrievers — (a) **Anthropic Contextual
  Retrieval** (Voyage `voyage-4-large` vector + BM25 + RRF + Voyage
  `rerank-2.5`) for methodology Q&A at launch, (b) **AGE traversal** for
  causal/multi-hop (incremental, `11b.2`), (c) SQL for personal metrics —
  before Claude (Sonnet, with prompt cache) synthesizes the answer. Phase 11b
  consumes this through 11a's proxy contract; it does not own retriever
  selection.
- **First-surface order:** Forge & Flow manager chat ships first (simplest
  permission model), then Barrio manager chat, then Barrio staff chat.
  Staff chat depends on Phase 9.5 for staff-level identity.

## Scope

Phase 11b owns:

- Agent runtime
  - stateless per-query context assembly
  - agentic loop that calls tools dynamically based on the question, not
    a hardcoded sequence
  - no permanent operator-data storage on the model side
- Retrieval behavior layered on Phase 11a
  - graph traversal retrieval at query time against 11a's graph
  - per-operator isolation enforced via the authenticated operator scope
    from Phase 9
  - provenance in every answer: which graph nodes were traversed, which
    tools were called, which values the answer is grounded in
- Coach Chatbot UI surfaces (hosted inside existing apps; no new app)
  - Forge & Flow manager chat: P&L summaries, variance explanation,
    termination-letter drafting, manager permission set
  - Barrio manager chat: same manager-level capability surfaced inside
    the staff-facing product
  - Barrio staff chat: "why was my PPA low?", grounded in training +
    personal numbers; suggested starter questions + free text
- Answer-confidence surfacing in the UI
  - tier the answer by provenance strength
  - refusal policy when confidence is too low

## Scope Does Not Own

Phase 11b does not own:

- knowledge graph, content ingestion, proxy backend (`11a.10`), MCP
  tool layer (`Phase 11a`)
- POS + Labor connector transport (`Phase 8`)
- reservation connector transport (`Phase 8R`)
- auth, roles, permission keys (`Phase 9`)
- El Podio learning identity (`Phase 9.5`)
- Barrio staff UX shell, Team Board, Schedule surfaces (`Phase 9.75`);
  11b provides the chat UI that lives inside the Barrio shell but does
  not own Barrio's non-chat surfaces

## Frontend Exposure

Phase 11b IS the agentic advisor UX. Coach Chatbot surfaces are
embedded inside the existing Forge & Flow and Barrio apps — no new
app, no new shell. This section makes the surfaces explicit per Hard
Promise #10.

**Operator/staff-facing surfaces this phase requires:**

- Forge & Flow manager Coach Chatbot:
  `lib/screens/advisor/coach_chat_screen.dart` (new). Entry point in
  app shell (icon button or pill in app bar).
- Barrio manager Coach Chatbot: same component, mounted under Barrio
  manager-mode shell.
- Barrio staff Coach Chatbot: same component, gated by
  `barrio.advisor.staff_chat` permission and a different system-prompt
  configuration. Suggested-question starters render above the input.
- Citation rendering: every answer surfaces "Where this came from"
  affordance — graph nodes traversed, MCP tools called, source
  document IDs.
- Answer-confidence chip: "High / Medium / Low" tier with hover
  explainer. Refusal copy when below threshold.
- Conversation history (per actor, paginated; reads
  `advisor_conversation_log` gated by audit-privacy permission per
  B46).
- `11b.2` causal-chain renderer: when the advisor used AGE traversal
  on the canonical graph, render the traversed-node sequence as a
  collapsible chain ("here's why I said that"). Lives inside the
  citation panel.

**Admin (11A) surfaces this phase requires:** conversation review
+ audit-privacy gate live in `11A.9` audit log review. Refusal-rate
+ confidence-distribution tiles live in `11A.6` observability.

**UX sub-slice family:** owned inline by existing `11b.x` slices.

- `11b` core ships the chat surface in F&F manager + Barrio manager +
  Barrio staff variants.
- `11b.1` schema-foundation sweep is structural — no UX surface.
- `11b.2` adds the causal-chain renderer in the citation panel
  (carve-out: `11b.2.UX.0`).

**Demo-mode walkthrough (`kDemoMode = true`; advisor uses staging
proxy + corpus loaded):**

- F&F → Coach icon → chat opens → ask "Why was my Tuesday lunch
  PPA low?" → answer renders with confidence chip → tap "Where this
  came from" → see citations + graph nodes + tool calls.
- For `11b.2.UX.0`: same flow but the advisor used AGE traversal →
  causal-chain renderer renders a node sequence inside the citation
  panel.
- Barrio staff → suggested-question starter "Why was my SPLH low?"
  → answer renders → confidence + citations visible.
- Refusal path: ask a question outside corpus → answer renders
  refusal copy + suggestion to reach out to manager.
- Settings → Account → Audit Log → see own advisor-conversation
  events (per B46 audit-privacy role).

Walkthrough evidence required at slice acceptance per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Runtime Contract

```text
operator query (Forge & Flow manager / Barrio manager / Barrio staff)
-> agent runtime
-> knowledge graph traversal (shared methodology, per Phase 11a)
-> pgvector cosine candidate retrieval
-> Voyage rerank-2.5
-> MCP tool calls (per-operator live + historical data, isolated)
-> context assembled fresh
-> Claude reasons, returns answer with provenance
-> no operator data retained by the model
```

## `11b.2` Graphify-Informed Traversal Contract

Graphify can inform the advisor graph, but it does not run in the
advisor hot path. By the time `11b.2` executes, every relationship the
advisor can traverse must already be approved through `11A.3.x` and
stored in canonical Postgres graph rows.

Runtime rule:

```text
Graphify proposal
-> 11A.3.x admin review
-> approved graph_nodes / graph_edges
-> AGE projection
-> 11b.2 traversal
-> advisor answer with provenance
```

The advisor must not read from `graphify-out/graph.json`, Graphify MCP,
or any unapproved draft artifact. Draft candidates are admin data, not
answer data.

Implementation details for `11b.2`:

- Traversal source of truth is `public.graph_nodes` /
  `public.graph_edges`, projected into AGE by the graph projection
  tooling.
- Every traversal query is scoped by authenticated `operator_id`,
  `graph_scope`, and `graph_version`.
- Runtime relationship types are allowlisted. Suggested initial edge
  types: `CONTAINS`, `DEPENDS_ON`, `CAUSES`, `SUPPORTS`,
  `CONTRADICTS`, `REFERENCES`, `IMPLEMENTS`, `MEASURES`.
- Runtime node types are allowlisted. Suggested initial node types:
  `Document`, `Chunk`, `Concept`, `Policy`, `Metric`, `Workflow`,
  `Role`, `Tool`, `Decision`.
- The agent can request bounded graph operations:
  - get approved node by key/label
  - get approved neighbors for a node
  - find a bounded path between two approved nodes
  - expand a local neighborhood up to a fixed depth
  - return provenance for every traversed node and edge
- Depth, edge count, and token budgets are capped per query so graph
  traversal cannot flood the prompt.
- Confidence is part of answer grounding. Lower-confidence approved
  edges may support exploration, but strong claims require extracted
  or explicitly approved evidence.
- The answer provenance must include graph node labels, edge labels,
  source documents, source spans when available, and live tool values
  used by the agent.

Graphify repo details to mirror conceptually:

- Mirror `graphify/serve.py` query primitives as AGE-backed operations:
  graph stats, node lookup, neighbor lookup, and shortest/bounded path.
- Mirror Graphify's source/provenance habit from `graphify/extract.py`:
  each traversal result must be traceable back to the source document or
  reviewed candidate.
- Mirror Graphify's confidence categories from its graph/report output,
  but normalize them to the F&F numeric confidence field and admin
  approval state before runtime use.
- Do not embed Graphify's NetworkX graph as runtime state. AGE/Postgres
  remains the runtime graph engine.

Acceptance for `11b.2`:

- Advisor answers can cite approved graph paths.
- Advisor refuses or narrows when graph provenance is weak.
- Unapproved, rejected, and ambiguous Graphify candidates are absent
  from runtime traversal.
- Tests cover same-operator traversal, cross-operator isolation,
  bounded traversal limits, provenance output, and confidence-aware
  answer behavior.

## Dependencies

Required before Phase 11b can ship real:

- `Phase 11a` knowledge graph + ingestion pipeline + proxy backend
  (`11a.10`) + MCP tool layer
- `Phase 9` auth so per-operator scoping is enforceable
- `Phase 8` live POS + Labor transport so tool calls return real numbers
  for meaningful answers
- `Phase 8R` reservation transport so reservation-driven questions are
  real

Helpful but not required:

- `Phase 10a` shared multi-device state so answers are consistent across
  devices
- `Phase 10.5` live daypart Shift so service-period questions have real
  data
- `Phase 9.75` Barrio shell so the Barrio-side chat bubble has a home;
  11b can ship manager chat inside Forge & Flow first if 9.75 is not
  ready
- `Phase 9.5` El Podio identity so Barrio staff chat knows who is asking

## Non-Negotiables

- per-operator data isolation: no query can retrieve or reason about
  another operator's numbers
- no silent model memory; stateless per query
- no screen-owned reasoning logic; all reasoning runs through the agent
  runtime
- provenance is a product requirement, not a nice-to-have: answers cite
  the graph path and tool values that grounded them

## Adjacent Phases

- `Phase 11a` provides the graph + ingestion + tool layer 11b consumes
- `Phase 8` + `Phase 8R` populate the repositories the tool layer reads
- `Phase 9` issues the operator scope enforcement relies on
- `Phase 9.5` supplies staff identity for staff-level questions
- `Phase 9.75` hosts the Barrio-side chat bubble UI
- `Phase 10a` keeps per-operator data consistent across devices

## Source Material

- [phase_11a_advisor_infrastructure_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md) (substrate accepted; archive reference)
- [phase_11A_operations_console_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md)
- [Graphify v5 repository](https://github.com/safishamsi/graphify/tree/v5)
- [project_rag_vision.md](C:/Users/saidu/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/project_rag_vision.md)
- [Rag_Architecture.svg](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/reference/Rag_Architecture.svg)

## Placeholder Notes

- Agent behavior spec (system prompt, tool-selection policy, refusal
  policy, escalation to human) must be expanded before implementation
  prompts start
- Exact Claude model ID is still chosen at 11b implementation time, but the
  model family is locked to Claude / Anthropic and the retrieval lane is locked
  to Voyage embeddings + rerank from 11a.
- Tracker folding: add to `PROJECT_TRACKER.md` Active Planning Docs list
  on next Codex pass
