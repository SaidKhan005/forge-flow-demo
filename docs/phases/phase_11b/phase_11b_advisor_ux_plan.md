# Phase 11b - Agentic Advisor UX

Updated: 2026-04-25
Status: Planned
Owner: Future advisor UX lane

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
- **Model lane:** advisor answers run through Claude / Anthropic. Phase 11a's
  retrieval substrate uses Voyage `voyage-4-large` embeddings in pgvector and
  Voyage `rerank-2.5` before Claude receives grounded context.
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

- [phase_11a_advisor_infrastructure_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md)
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
