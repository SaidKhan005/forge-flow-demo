# Phase 11a Decision Register

Updated: 2026-04-26 (architecture lock-sweep)
Status: Active decision authority for 11a infrastructure prompts and
forward-phase architecture (11b, 11b.1, 11b.2, 12.x)

This file holds the decisions that were removed from the lean
`PROJECT_TRACKER.md`. Read it when a prompt needs architecture rationale,
guardrails, live-service decisions, or parked follow-ups. For normal code-only
slice prompts, the active phase plan is usually enough.

## Architecture Lock (2026-04-26)

Decision: build the F&F advisor + workflow platform as a **Modular Adaptive
Agentic RAG system on Azure DB Flexible Server with native Anthropic tool
use, AGE for graph reasoning, pgvector + tsvector for hybrid retrieval, and
five cost-discipline levers wired before launch.**

The decision balances three constraints simultaneously:
1. Best-in-class retrieval quality (the "ridiculously elite product" goal)
2. Phase 12 workflow platform non-negotiable (graphs are workflow-shaped)
3. 75-95% gross margin maintained at scale (cost discipline as
   infrastructure, not afterthought)

Cheaper paths sacrificed quality (Plan A vector-only on Supabase). More
expensive paths added vendor sprawl (Neo4j AuraDB sidecar). Self-host on
GCE saves $50-100/mo at the cost of solo-founder ops time, which is
worth more.

## Retrieval Pattern: Modular Adaptive Agentic RAG

Anthropic's "Contextual Retrieval" (Sept 2024, measured 67% reduction in
retrieval failure) is the launch retrieval pattern. AGE traversal augments
incrementally for the query classes it actually wins on.

### Layered design

**Layer 1 — Query classifier (Haiku, ~$0.0001/call)**: routes intent into
one or more of: `personal_metric` (SQL only), `comparative_metric` (SQL
only), `methodology_lookup` (Contextual Retrieval), `causal_chain`
(AGE + Contextual Retrieval), `recommendation` (all three + synthesis),
`workflow_action` (Phase 12 tools).

**Layer 2a — Contextual Retrieval (the methodology leg)**: indexing-time
work. Each chunk gets a 50-100 token Claude-Haiku-generated context
prepended before embedding (`chunk_context` column on
`advisor_source_chunks`). Indexing cost ~$1/M-tokens-of-corpus, one-time
plus on corpus updates. Query-time work: hybrid (dense pgvector + sparse
`tsvector` BM25) with Reciprocal Rank Fusion (`rrf_k=60`), then Voyage
`rerank-2.5` over the fused top-N.

**Layer 2b — AGE Cypher traversal (the multi-hop leg)**: for causal-chain
or schema-bound questions where vector RAG measurably loses. Used
incrementally — `11b.2` opens it for causal/multi-hop methodology
questions; Phase 12 fully exercises it for staff-coaching relational
queries (server↔training↔metrics) and workflow definitions (workflows
ARE graphs).

**Layer 2c — Structured SQL (the personal data leg)**: tools call
materialized views directly (`staff_metrics_daily`,
`staff_metrics_comparative`, etc.). Sub-100ms; no LLM in the path.

**Layer 3 — Synthesis (Sonnet)**: assembles SQL + retrieved chunks +
graph traversal results with provenance markers, prompt-cached
methodology context (90% input discount on cache hits), Microsoft
Spotlighting encoding on operator-supplied content (Hard Promise #5
prompt-injection stack). Output: grounded recommendation with
citations.

**Layer 4 — Tool-using agent (Anthropic native function calling)**: the
orchestrator. Tools are SQL queries, Contextual Retrieval calls, AGE
traversals, Phase 12 workflow proposals. Plan-Then-Execute pattern for
write actions; CaMeL two-LLM separation when write paths touch
operator content.

### Why not pure GraphRAG, why not pure vector

Research synthesis (April 2026):
- Vector RAG wins on specific document lookup (54% vs 35% graph) and is
  much cheaper to maintain.
- Graph RAG wins on multi-hop reasoning (4×) and aggregation (3×) and is
  the only path that hits 90% on schema-bound queries (vector RAG = 0%
  on schema-bound).
- The split: "If fewer than 20% of queries require multi-hop reasoning,
  the operational overhead of maintaining a knowledge graph is probably
  not justified" — but Phase 12 puts F&F well over that threshold (every
  workflow definition is a graph; every "why was my SPLH low" personal
  query needs causal traversal).
- LazyGraphRAG (Microsoft, June 2025) cut indexing cost to 0.1% of full
  GraphRAG cost, removing the entity-extraction-cost objection.
- Apache AGE momentum is questionable (slow PR velocity, no enterprise
  version) but Microsoft Azure backing + GA + perf docs are strong
  signals; **Path A escape hatch documented below**.

### AGE escape hatch (parked Future Decision)

Trigger: AGE upstream stalls OR Phase 12 graph workloads exceed AGE
edge-performance limits OR a blocker bug surfaces.

Paths in priority order:
1. Pin to a known-good AGE fork; community-maintained
2. Migrate graph layer only to Neo4j AuraDB (Canada region available,
   ~$65-200/mo small workloads); keep pgvector + relational on Azure DB
3. Drop graph entirely; Q12 vector-only fallback flag becomes default

Estimated migration cost (path 2): 4-6 weeks of engineering when
triggered. Acceptable as future optionality.

## Real-Time Pattern: Postgres NOTIFY → Cloud Pub/Sub → WebSocket Bridge

(Locked 2026-04-26; replaces both Supabase Realtime and raw multi-instance
LISTEN/NOTIFY.)

Research surfaced: raw `LISTEN/NOTIFY` from multi-instance Cloud Run
breaks at scale. Each instance opens its own LISTEN connection;
auto-scaling exhausts Postgres connection limits; messages get lost
between instances. Documented failure mode.

Phase 10a pattern instead:
1. Postgres triggers fire `NOTIFY shared_state:<restaurant_id>:<table>,
   <payload>` on shared-state mutations.
2. **Single dedicated subscriber** Cloud Run instance (always-warm,
   `min-instances=1`) holds the LISTEN connection and bridges events to
   **Cloud Pub/Sub** topics keyed by `(operator_id, location_id)`.
3. WebSocket-handling Cloud Run instances subscribe to relevant Pub/Sub
   topics filtered by JWT-derived scoping; fan out to authenticated
   WebSocket clients.
4. Polling fallback at 30-60s remains the safety net.

MVP exception: single-operator beta can ship raw LISTEN/NOTIFY initially.
Pub/Sub fan-out becomes mandatory before multi-operator launch (any
scenario where Cloud Run scales to >1 WebSocket-handling instance).

Cost: Cloud Pub/Sub free tier covers MVP; ~$5-30/mo at mid-scale.
Memorystore Redis is NOT used for fan-out (Pub/Sub fits the pattern
better); Memorystore is only for response caching (lever 3 below).

## Five Cost-Discipline Levers (Hard Promise #9)

Locked 2026-04-26. These are infrastructure, not best-effort.

### Lever 1 — Aggressive Anthropic prompt caching (default-on)

90% input-token discount on cache hits within Anthropic's TTL. Stable
content (system prompt, tool definitions, methodology context, operator
context) is prepended with cache breakpoints; per-corpus-version cache
keys invalidate when corpus changes (`advisor_source_chunks.corpus_version`).

Saves: 60-85% of Anthropic input-token cost on warm queries.
Wired in: `11a.11d` (proxy counter wiring slice). Code-level capability
already exposed via `LLMProvider.Capability.promptCaching`.

### Lever 2 — Tier routing (Haiku does most of the work)

`LLMProvider.complete(..., tier)` routes by query class:
- Haiku for: query classification, tool dispatch, simple synthesis
  ("here's your SPLH"), each step inside a workflow loop
- Sonnet for: nuanced multi-source synthesis, advisor answers with
  provenance, workflow planning, operator-facing P&L narrative
- Per-tier model routing tied to subscription: Basic→Haiku only;
  Premium→Sonnet for advisor; Elite→Sonnet broadly; Pro→Sonnet+Batch;
  Enterprise→broadest

Saves: 50-70% on routine work. Already locked via Hard Promise #8;
enforcement formalized in `11a.11d`.

### Lever 3 — Response cache + semantic cache (Cloud Memorystore Redis)

- **Exact-match cache**: hash of `(query_text, operator_id,
  corpus_version)` → response. 5-15 min TTL. In-process LRU first, then
  Memorystore Redis.
- **Semantic cache**: embed query, lookup nearest-neighbor in
  `query_response_cache` Postgres table with cosine ≥ 0.95 threshold;
  return cached response. Catches paraphrases.

Privacy gate: cache scope is `(operator_id, staff_id)` for personal
queries; shared methodology answers can cache at `operator_id=NULL`
and serve cross-operator (the answer is non-personal).

Saves: 30-50% LLM volume reduction.
Wired in: `11b.1` schema-foundation slice. Memorystore deferred until
~25 operators or ~10K queries/mo. Until then, Postgres-table cache
suffices (slower but free).

### Lever 4 — Pre-computed answers for top-N recurring queries

80%+ of advisor queries are some variant of: "what's my SPLH this week?"
"how am I doing vs last month?" "what should I focus on tomorrow?" These
are pre-computable per `(operator_id, staff_id)`.

Pattern: nightly Cloud Run job iterates active operators × top-N query
classes, runs the agent with Anthropic Batch API (50% discount),
persists to `precomputed_summaries(operator_id, staff_id NULL,
query_class, computed_at, data_as_of, response JSONB, ...)`.

Query path: SELECT from `precomputed_summaries` first; if hit and not
stale, return at $0. Fall back to live agent only on miss or staleness.

Saves: 70-80% of personal queries served at $0.
Wired in: `11b.1` schema-foundation slice + nightly Cloud Run job.
Operator dormancy rule (below) prevents waste on inactive operators.

### Lever 5 — Anthropic Batch API for asynchronous workloads (50% discount)

Anything not user-facing real-time uses Anthropic's Message Batches API:
- Weekly P&L generation (Phase 12)
- Nightly precompute runs (lever 4)
- Performance review summaries (monthly)
- Inventory recommender (daily off-hours)
- Vendor reconciliation (per-invoice, batched)
- Marketing email drafts

Pattern: workflow row inserted to `workflow_runs` (status
`AWAITING_BATCH`) → poller worker reads pending rows with
`SELECT ... FOR UPDATE SKIP LOCKED` (no `pgmq`; Azure does not
expose it) → submits batch to Anthropic → polls for results → writes
to `workflow_runs.output_artifact_url`. Webhook-style HTTP delivery
to downstream Cloud Run services uses Google Cloud Tasks.

Saves: 50% on every async workflow run.
Wired in: Phase 12.0 (workflow foundation prerequisite). `LLMProvider`
adds `submitBatch(...)` extension method.

## Pricing Tier Model (concrete; replaces parked "F&F pricing tiers")

(Locked 2026-04-26; replaces the abstract "F&F pricing tier model" parked
in older trackers.)

External-facing tiers stay simple (operators see Basic/Premium/Elite/
Pro/Enterprise). Internal metering is decomposed via `usage_class` so
F&F can attribute cost per surface and adjust caps per tier without
restructuring SKUs.

### Public tiers

| Tier | Pricing | Includes | Internal cap |
|---|---|---|---|
| **Pilot** (NEW pay-as-you-go) | $0/mo + $0.10/advisor query, $0.50/workflow run; capped at $50/mo | Methodology Q&A only; advisor with full Modular Adaptive RAG | Hard $50/mo cap; auto-converts to Starter |
| **Starter (Basic)** | $250/mo | KPI Dashboard, Back Office Reporting, Branded App, 4 Manager Logins, Manager Chatbot, Automated Manager Feedback | 500 q/op/mo, Haiku-only |
| **Premium** | $250 + $5/seat/mo | Above + LMS Platform, Scoreboard, Performance Tracking; Sonnet for advisor synthesis | 1,000 q/op + 500 q/seat/mo |
| **Elite** | $250 + $10/seat first 20 + $5/seat after | Above + Staff Chatbot, Automated Staff Feedback, SOP Templates, Training Manual Library | 2,000 q/op + 1,500 q/seat/mo |
| **Pro** (NEW workflow tier) | $500 + $15/seat first 20 + $8/seat after; includes 100 workflow runs/op/mo | Above + Workflow Catalog (Weekly P&L, schedule generator, inventory recommender, vendor reconciliation, customer feedback synthesis, performance reviews, marketing drafts) | 3,000 q/op + 2,000 q/seat/mo + workflow allowance; $5/run overage |
| **Enterprise** | Custom contract | Above + Custom Workflows, Multi-location, SLA, Priority Support, Dedicated CSM | Custom |

### Onboarding pricing

| Tier | Onboarding range |
|---|---|
| Pilot | $0 (self-serve) |
| Starter | $500-1,000 |
| Premium | $750-2,000 |
| Elite | $1,500-3,500 |
| Pro | $2,500-5,000 |
| Enterprise | Custom (typically $10K-50K) |

### Why this works economically

Gross-margin sanity check (cost = Anthropic + Voyage + share of fixed
infra):
- Pilot at zero usage: $0 cost / $0 revenue → break-even by definition
- Starter at single user, 50 q/mo: ~$13 cost / $250 revenue = 95% margin
- Premium at 20 users, 1K q/op + 500 q/seat: ~$25 cost / $350 revenue = 93% margin
- Elite at 20 users: ~$98 cost / $450 revenue = 78% margin
- Elite at 100 users: ~$420 cost / $850 revenue = 50% margin (workable)
- Pro at 20 users with 50 workflow runs: ~$200 cost / $800 revenue = 75% margin
- Pro at 100 users with 200 workflow runs: ~$580 cost / $1,440 revenue = 60% margin
- Enterprise: 80%+ margin (custom contracts justify it)

The Elite incremental price was raised from $7/$3 (the original marketing
one-pager pricing) to $10/$5 because $3/seat below 20 was below
marginal Anthropic cost and broke margin past ~30 active staff.

The Pro tier above Elite separates **workflow-heavy operators** into
their own SKU. Workflows are high-cost-per-execution; bundling them into
Elite's flat rate would have broken margin at any operator running
>5 workflows/mo.

### Hard Promise #9 implementation

Schema extension to `usage_caps`:
```sql
usage_caps(
  operator_id, location_id,
  staff_id UUID NULL,         -- NEW: per-staff caps
  workflow_id UUID NULL,      -- NEW: per-workflow caps
  usage_class TEXT,
  monthly_cap_usd DECIMAL,
  per_invocation_cap_usd DECIMAL,
  ...
)
```

Schema extension to `usage_logs`:
```sql
usage_logs(
  ...,
  query_class TEXT,           -- NEW: 'advisor_qa', 'coach_qa', 'wf_pl', etc.
  cache_hit BOOL,             -- NEW: lever-3 telemetry
  llm_tier TEXT,              -- NEW: 'haiku' | 'sonnet'
  model_used TEXT,            -- NEW: actual model identifier
  batch_mode BOOL,            -- NEW: lever-5 telemetry
  ...
)
```

`11A.6` Observability Dashboard surfaces: per-class cost, cache hit
rate, model mix, top-spending operators / staff / workflows. `11A.2`
Pricing Tier Admin lets F&F admin adjust caps per `(operator, tier,
class)`.

## Fixed-Cost Deferral Discipline (Pay-As-You-Go Posture)

Locked 2026-04-26. The architecture is ~70-80% pay-as-you-go because the
expensive components (Anthropic, Voyage, Cloud Run requests) are
per-use. The minority of fixed-cost services are deferred until
variable usage justifies them.

| Fixed-cost service | Provisioned at | Rationale |
|---|---|---|
| Cloud Run `min-instances=0` (proxy) | Stay at zero through MVP single-operator beta | $0 fixed; ~5-15s cold start acceptable for beta |
| Cloud Run `min-instances=1` (proxy) | Multi-operator launch | ~$15-30/mo per warm instance; eliminates first-request lag |
| Cloud Memorystore Redis Basic | ~25 operators or ~10K queries/mo | $15-30/mo; Postgres-table cache suffices below threshold |
| Azure DB tier upgrade B2s → D2s_v3 | ~10 active operators or query volume justifies | $25 → $180/mo step; right-size as growth happens |
| Azure DB Reserved Instance (1Y/3Y) | Production tier stable past 25-50 operators | 30-50% discount but locks-in spend |
| Cloud Run admin console always-warm | When admin team uses it daily | $15/mo; otherwise scale-to-zero |
| Sentry paid tier | Error volume exceeds free tier (~5K events/mo) | $26/mo; free tier covers MVP |

**True fixed-cost floor at MVP**: ~$25-40/mo. If F&F has zero active
operators, F&F pays $25-40/mo. Variable cost only fires on actual usage.

## Operator Dormancy Management

Locked 2026-04-26. Saves both fixed and variable costs on inactive
accounts.

| Trigger | Action | Saves |
|---|---|---|
| Operator has not queried in 30 days (`last_active_at`) | Skip nightly precompute job for that operator | $0.50-2/op/mo |
| New operator | Default workflows = OFF (must explicitly enable scheduled workflows) | Avoids ~$5-15/op/mo of unused workflow execution |
| Operator inactive 60 days | Require re-auth on next login | Reduces stale-session risk |
| Operator unpaid 90 days | Suspend access (read-only, no AI calls) | Eliminates variable cost on non-paying account |

Schema additions:
- `operators.last_active_at TIMESTAMPTZ` (updated on any authenticated
  request)
- `operators.workflows_enabled BOOL DEFAULT false`
- `operators.subscription_status TEXT` ('active' | 'suspended' | 'churned')

Implementation: `11A.1` Operator + Location Management + `11A.4`
Integration Management surface dormancy state; nightly precompute job
checks `last_active_at` before running per-operator.

## Schema-Foundation Slice (NEW: `11b.1`)

Locked 2026-04-26. Inserted between `11b` and `11b.2` because Phase 11b
advisor can ship without operator fact data in cloud (advisor passes
context inline), but `11b.2` personal-query surface needs cloud-side
data, and Phase 12 server-facing coaching mandates it.

Scope:
- **Operator fact tables in cloud Postgres**: `shifts`, `shift_sales`,
  `shift_labor`, `shift_tips`, `shift_customers` — all carry
  `(operator_id, location_id, staff_id)` with RLS
- **`staff_id` axis added** to all relevant fact tables (not yet in
  current schema; today fact tables are `(operator_id, location_id)`-scoped
  only)
- **Materialized metrics views**: `staff_metrics_daily`,
  `staff_metrics_weekly_rolling7`, `staff_metrics_period_60d`,
  `staff_metrics_comparative` (with `pg_cron` nightly refresh)
- **Response cache + semantic cache wiring**: Cloud Memorystore Redis
  Basic provisioned; `query_response_cache` Postgres table created;
  proxy reads cache before LLM call
- **Pre-computed summaries**: `precomputed_summaries` table created;
  nightly Cloud Run job submits batch to Anthropic for top-N query
  classes per active operator
- **Operator fact data sync mechanism**: write-through-on-commit from
  operator app to Postgres via `/v1/...` proxy routes (already
  established by 11a.10); operator-side SQLite stays as cache (per
  Phase 10a pattern)
- **Per-staff caps** added to `usage_caps`; per-class telemetry
  (`query_class`, `cache_hit`, `llm_tier`, `model_used`, `batch_mode`)
  added to `usage_logs`

## Phase 8.5 Lane (NEW: External Integrations)

Locked 2026-04-26. Sits between Phase 8/8R (POS/Labor connectors) and
Phase 12 (workflow platform consuming integrations). `IntegrationProvider<T>`
abstraction following the same pattern as `LLMProvider`/`EmbeddingProvider`.

Initial integrations needed for Phase 12 flagship workflows:
- **QuickBooks Online (QBO)** — accounting GL, invoices, vendor bills
  (~2-3 weeks)
- **Xero** — alternative accounting; same shape as QBO (~2 weeks once
  QBO done)
- **Bill.com or MarginEdge** — AP/invoicing (~3 weeks)
- **Plaid** — banking feed for cash reconciliation (optional, ~2 weeks)

Plan: `docs/phases/phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md`.

## Phase 12 Workflow Platform Program (NEW)

Locked 2026-04-26. Frame as a multi-quarter program, not a single phase.
Sub-slices:

- **12.0 Foundation**: `workflow_definitions`, `workflow_runs`,
  `workflow_steps`, `workflow_audit_log` schema; in-DB queue via
  `FOR UPDATE SKIP LOCKED` against `workflow_runs` (no `pgmq` —
  Azure does not expose it); Cloud Tasks for HTTP-delivery to
  downstream Cloud Run services; Cloud Run jobs sibling service for
  execution; scheduled trigger via `pg_cron` + Cloud Scheduler;
  per-task caps. ~3-5 weeks.
- **12.1 Tool Registry**: catalog of read-only and write-tool functions
  with input/output JSON schemas; tool discovery API; per-operator
  tool allowlist. ~2-3 weeks.
- **12.2 Plan-Then-Execute Orchestrator**: agent loop with planning
  step, execution step, result observation, summary; CaMeL-style
  two-LLM separation for write paths. ~3-4 weeks.
- **12.3 Approval Gate UI**: operator preview of agent plan + per-action
  consent + approve/reject; lives in 11A admin or as ops-app surface.
  ~2 weeks.
- **12.4 Weekly P&L Workflow** (flagship): data fetcher tools (consuming
  Phase 8.5 integrations), anomaly detector, narrative generator,
  PDF + email delivery. ~3-4 weeks.
- **12.5 Workflow Catalog**: operator browses + enables workflows;
  per-workflow usage tracking; per-tier feature flag enforcement. ~2 weeks.
- **12.x+** (ongoing): each additional workflow (schedule generator,
  inventory recommender, vendor recon, customer feedback synthesis,
  performance reviews, marketing drafts, etc.) ~1-3 weeks each.

Plan: `docs/phases/phase_12_workflow_platform/phase_12_workflow_platform_plan.md`.

## Infrastructure Lock

- Postgres host: Azure Database for PostgreSQL Flexible Server.
- Region: Canada Central.
- Postgres version: PG 16.
- Reason: Apache AGE is mandatory for the knowledge-graph direction. AGE is
  unavailable on the linked Supabase project and not on Supabase's supported
  extension surface, while Azure DB Flexible Server supports AGE.
- Path chosen: full Postgres host migration to Azure.
- Rejected path: hybrid Supabase + Azure AGE sidecar, because it adds a
  dual-write and reconciliation tax before there is production data.
- Supabase status: historical only after Azure staging accepts. The `11a.11c.3`
  Supabase verification remains useful as SQL-portability evidence.

## Graph And Retrieval Posture (revised 2026-04-26)

**Revised 2026-04-26 alongside the Modular Adaptive RAG architecture lock
above.** AGE is no longer the launch retrieval differentiator; it is part
of the launch retrieval mix, used adaptively for the query classes it wins
on. Previous "graph-first default" framing replaced by Modular Adaptive
RAG.

- Apache AGE infrastructure must be live before `11b` opens (Hard
  Promise #5 revised: schema applied + extensions verified + benchmark
  passed against Azure DB Flexible Server).
- Launch retrieval pattern: **Modular Adaptive Agentic RAG** (see
  Architecture Lock section above). Haiku query classifier routes to
  appropriate retrieval mix; AGE traversal augments incrementally.
- Default retrieval mix per query class:
  - Methodology Q&A → Anthropic Contextual Retrieval (vector + BM25 +
    rerank). AGE NOT used. Phase 11b launch.
  - Causal / multi-hop methodology questions → Contextual Retrieval +
    AGE traversal merged. Phase 11b.2 lights this up.
  - Personal / comparative metrics → SQL only, no LLM in retrieval.
  - Server-facing relational coaching (server↔training↔metrics) → SQL +
    AGE traversal + Contextual Retrieval. Phase 12 lights this up.
  - Workflow definitions → AGE subgraphs (workflows ARE graphs).
    Phase 12 baseline.
- Vector-only Q12 fallback flag (`graph_retrieval_mode = 'vector_only'`)
  remains in `feature_flags` as resilience insurance. Activates if AGE
  benchmark fails at production scale OR a production incident requires
  it. NOT the launch posture.
- Benchmark gate: isolated p95 must be <= 500ms and 10x concurrent p95
  must be <= 1000ms before AGE is trusted at launch scale. If this
  fails, first try an Azure tier upgrade before flipping the resilience
  flag to vector-only.
- AGE projection artifacts already exist from `7.57.4`; live apply
  happens for the first time in `11a.11c.6`. Live traversal in advisor
  hot path lights up at `11b.2`.

## Data And Schema Guardrails

- Per-operator isolation is non-negotiable.
- Operator/location-scoped tables carry `(operator_id, location_id)`.
- Cross-tenant location mismatches are rejected with composite FKs.
- RLS is enabled from table creation; Phase 9 turns real enforcement on.
- Supabase-era policy role names remain part of the compatibility surface on
  Azure: bootstrap `service_role` and `authenticated` roles before applying the
  existing advisor migrations unless/until a later auth/RLS slice replaces
  them deliberately.
- App code reaches operator-scoped Postgres through repository/proxy patterns,
  not direct SQL imports.
- Source-truth instants use `TIMESTAMPTZ`; `TIMESTAMP WITHOUT TIME ZONE` is
  banned in operator-scoped cloud tables.
- `business_date` is denormalized at write using location timezone plus
  business-day rollover hour.
- Operator deletion cascades through operator-scoped rows where appropriate.

## Proxy And Cost Controls

- Proxy routes use `/v1/...` at launch.
- Breaking API changes ship under `/v2/...`; `/v1/...` remains live until an
  explicit deprecation policy exists.
- Per-request idempotency uses `proxy_requests.idempotency_key`.
- Usage counters use `usage_logs` keyed by `(operator_id, location_id,
  usage_class, period_start)`.
- Caps use `usage_caps` keyed by `(operator_id, location_id, usage_class)`.
- Cap refusals return machine-readable JSON with current usage, cap, and reset
  information.
- Cost accounting is internal USD. Operator display currency comes from
  `operators.preferred_currency`, default `CAD`, with FX snapshots in
  `fx_rates`.
- Per-request logging is meta-only by default: operator, location, usage class,
  token counts, latency, status. Question and answer text require explicit
  per-operator opt-in.
- Cap-event notifications should reach F&F admin before multi-operator launch.

## Provider And Model Decisions

- Claude/Anthropic is the first advisor-answer provider.
- Voyage `voyage-4-large` is the first embedding model, 1024 dimensions.
- Voyage `rerank-2.5` is the first reranker.
- Provider abstraction remains generic: `LLMProvider`, `EmbeddingProvider`,
  `RerankProvider`.
- Anthropic prompt caching is exposed as a provider capability.
- Provider fallback chains are deferred until production data justifies them.
  Launch behavior is hard-fail with a clear error.
- Streaming is deferred. `LLMProvider.complete(...)` is non-streaming at
  launch; `completeStream(...)` can be added later.
- Post-launch caching for repeated advisor questions is deferred until
  production usage shows recurring question classes.

## Security And Safety Posture

- No vendor/provider secrets in Flutter.
- Local secrets are consolidated outside the repo in
  `$HOME/.forge_flow/forge_flow.secrets.ps1`; `.env.local` remains ignored
  if recreated, but is not the source of truth.
- Advisor posture is recommendation-only. F&F provides advisory information;
  operators decide whether to act.
- Prompt-injection MVP stack:
  - RLS + repository pattern + read-only retrieval + F&F-controlled corpus are
    the primary defense.
  - Base64-encode operator free-text fields injected into context.
  - Keep system prompt scoped to restaurant operations and provided context.
  - Strip or rewrite non-allowlisted links/images in model output.
  - Cap injected operator free-text lengths.
  - Use role separation as hygiene, not as the main defense.
- Multi-operator launch adds: input-side prompt-injection classifier,
  provenance markers, retrieval-scope audit, and adversarial CI tests.

## Cloud And Operations Constraints

- Cloud Run stays the backend hosting path.
- Cloud Run cold starts are accepted for MVP with `min-instances=0`; flip to
  `min-instances=1` at multi-operator launch.
- Cross-cloud egress between GCP Cloud Run Toronto and Azure DB Canada Central
  is acceptable at MVP scale.
- Azure DB is single-region for MVP. Global expansion requires read replicas or
  a separate multi-region design.
- AGE complicates in-place Postgres major version upgrades on Azure; an ops
  runbook must ritualize drop/recreate of AGE schemas during upgrade windows.
- Weekly logical `pg_dump` to GCS supplements Azure PITR.
- Base64 spotlighting increases injected-context token cost; accepted for MVP
  as a security trade-off.

### Azure constraints discovered live 2026-04-26

Live provisioning of `forge-flow-staging-pg` (Azure DB Flexible
Server, PG 16, Canada Central, `Standard_B1ms`) surfaced two
constraints that change the locked plan. These are factual host
constraints, not preferences — both are now production guardrails.

**`pgmq` is not on the Azure allowlist.** `SHOW azure.extensions` on
the staging server returned `age, vector, pg_diskann, pg_cron,
pg_partman, pg_stat_statements, pgcrypto` — `pgmq` is absent.
Decision:

- In-DB queues use `SELECT ... FOR UPDATE SKIP LOCKED` against a
  plain workflow / job table (the Phase 12 batch poller already uses
  this pattern; it stays). No `pgmq` API surface in any code path.
- HTTP-delivery queues (where the consumer is a Cloud Run service
  receiving a webhook-style push) use **Google Cloud Tasks**. F&F
  already runs on Cloud Run, so Cloud Tasks integrates with zero
  cross-cloud egress.
- `pgmq` is not reintroduced unless a new live-hosting decision lands
  (e.g., a future migration to a host that exposes it). The Phase 12
  plan and CLAUDE.md guardrail both reflect this lock.

**Built-in PgBouncer requires General Purpose or Memory Optimized
tier.** Burstable B1ms does not expose Azure's built-in PgBouncer
transaction-mode pooler. Decision:

- **Production minimum SKU: General Purpose `Standard_D2ds_v5` or
  higher.** This is no longer a preference; it is the SKU floor
  required for built-in PgBouncer.
- Staging may stay on Burstable (`Standard_B1ms` today) for cost
  reasons, but staging then does not test pooling behavior. Pooling
  rehearsal happens against a production-tier server before launch.

A separate operational note: staging backup retention defaults to
7 days on Burstable, while the production target is 35 days. The
35-day retention is a pre-production checklist item — set
`--backup-retention 35` at production provisioning time, before any
operator data is written.

## Phase 9 Architecture Lock (2026-04-26)

Five product decisions locked after deep research + codebase inventory
on 2026-04-26 under the "no shortcuts" launch model. Detail:
`phase_9/phase_9_auth_plan.md`. The user-approved full Phase 9 decision set
lives in `phase_9/phase_9_decision_lock_2026-04-26.md`.

**1. Identity layer: Firebase Identity Platform tier (not Firebase Auth
standard).** Required for TOTP enrollment, future MFA enforcement, and
future blocking-function hooks. Free up to 50k MAU; ~$0.0055/MAU above.
Live setup note
(2026-04-26): Identity Platform staging is enabled and TOTP MFA is
enabled. Official Identity Platform docs list email/password, phone,
federated/OIDC/SAML, and custom-auth integration paths, and the TOTP MFA
docs describe TOTP as a supported MFA factor; they do not expose a
first-party WebAuthn/passkey provider surface. Decision: Phase 9 launches
with email/password + TOTP MFA. Passkeys are a future follow-up, not a
launch gate, unless Firebase / Identity Platform exposes an official
supported passkey path before cutover.

**2. Permission model: enriched RBAC at launch.** Custom roles, deny
rules (deny wins over allow), location-scoped grants, time-bound grants
(`valid_from` / `valid_until`). Six seeded roles: `super_admin`
(F&F), `ff_support` (F&F support staff), `operator_owner`,
`operator_manager`, `operator_supervisor`, `operator_staff`. ~80
frozen permission keys in code-defined catalog. ReBAC graph permissions
(OpenFGA / SpiceDB) deferred to Phase 12 workflow approval chains where
graph relationships actually pay off; ReBAC at launch is over-engineering
for the multi-tenant org-hierarchy + custom-role surface.

**3. SSO / SAML / SCIM: WorkOS, deferred.** Lights up at first
Enterprise-tier customer demand. Don't build SAML in-house; WorkOS at
$125/mo/connection. The `users.external_id` column lands in 9.0 as a
zero-cost forward-compat hook; no other Phase 9 work blocks on this.

**4. MFA enrollment and future enforcement policy.** Reopened by the
user on 2026-04-30: mandatory MFA enforcement for admin-tier accounts
is deferred until post-launch stability. Launch posture is TOTP
self-enrollment, no recovery-code login/reset UX, fresh-auth checks on
sensitive actions, and 24-hour MFA removal safety. Later enforcement should roll out only
after explicit approval, starting with highest admin / owner accounts
before managers. Staff-level users do not have mandatory MFA by
subscription tier; users may opt in. Read future enforcement state from
`users.mfa_required` / operator policy state rather than hard-coding role
names. Cost remains near zero on Identity Platform free tier. SMS remains
deprecated per NIST SP 800-63B-4 and is not part of this launch track.
Passkeys remain desirable but are not a launch gate without an official
Firebase / Identity Platform support surface.

**Auth email decision (2026-04-26).** Use Firebase action links with
Forge & Flow branded web pages for invite, verification, password reset,
and MFA-related action flows. Firebase continues to own the secure action
codes; Forge & Flow owns the user-facing pages and copy. Built-in
Firebase subject/body template customization is not a launch blocker.

**Additional Phase 9 decisions accepted 2026-04-26.** Local Firebase ID-token
verification via Firebase public keys/JWKS is the default request path; live
revocation checks are reserved for sensitive operations. Tiny Firebase custom
claims are allowed (`operator_id`, `is_super_admin`, `is_ff_support`,
`roles_version`) while Postgres remains source of truth. Staging auth smoke
uses `auth-smoke@forgeflow.dev`. Live staging RLS flip is approved once
integration tests are ready. `forge_admin` BYPASSRLS is allowed only for admin
paths and every bypass is audited. Step-up auth freshness is 5 minutes. MFA
lost-authenticator recovery uses restaurant-admin delayed removal and MFA removal
requires step-up plus a 24-hour delay. Password policy follows NIST style, HIBP k-anonymity screening
is on, Cloud Armor + reCAPTCHA are on for brute-force protection, and paid
VPN/Tor reputation vendors are deferred. Invites expire after 7 days. Only F&F
`super_admin` can create users without invite. Auth/security audit retention is
7 years. Operator owners may create/edit operator-scoped custom roles; seeded
roles remain protected. Deny rules are supported and deny wins. `ff_support`
sees assigned operators/locations only. Admin UX is dense operational tables,
filters, and audit drilldowns; CSV audit export is allowed for authorized admins
and every export is audited.

**5. GDPR right-to-erasure: redact-don't-delete with break-glass.**
PII columns redacted across `users`, `auth_events_audit`, `auth_sessions`
on erasure request; operational record (event_id, actor_user_id,
event_type, occurred_at) preserved under GDPR Art. 17(3) carve-out for
operational records. Procedure requires paired-approval (two F&F
super_admins, both with step-up MFA). Hard-delete reserved for legal-
hold release scenarios only. Documented runbook lands with 9.8.

**Phase 9 sub-slice plan: `9.0` through `9.10` (12 sub-slices).**

| Slice | Scope |
|---|---|
| `9.0` | Auth schema foundation (single migration) |
| `9.0a` | Multi-location scale-flow extensions (NEW 2026-04-26): `user_roles.scope_type`, `users.primary_location_id`, `operators.region`, plus 12 `team.*` permission keys for the operator-facing team UX |
| `9.1` | Firebase Identity Platform setup + JWT verifier wiring |
| `9.2` | Repository pattern + SET LOCAL + RLS enforcement live |
| `9.3` | Login + persistent session + step-up auth + Flutter wiring |
| `9.4` | MFA enrollment + enforcement (TOTP + admin reset/delayed removal; passkeys future follow-up if officially supported) |
| `9.5` | Password policy + HIBP + brute-force + Cloud Armor |
| `9.6` | Role + permission system runtime |
| `9.7` | Permission enforcement runtime + Forge & Flow + Barrio gates |
| `9.8` | Admin user lifecycle + GDPR erasure |
| `9.9` | F&F admin role console UX (inside `admin.forgeflow.app`) |
| `9.10` | **Operator-facing Settings → Team UX** (NEW 2026-04-26) inside the Forge & Flow / Barrio operator app. Distinct surface from `9.9`. Toast Web / Square Dashboard / 7shifts admin-style operator-self-service team management |

Estimated total: 13-17 weeks (was 12-15 before the 2026-04-26
multi-location audit additions). Future extensions slot in
`9-future-1` through `9-future-7` (see phase plan).

**Multi-location audit additions (2026-04-26).** Research on Oracle
Simphony, Toast, Square, Lightspeed, and 7shifts surfaced two
additions for franchise-scale auth that became part of the locked
Phase 9 scope:

1. **Schema extensions (`9.0a`)** — `user_roles.scope_type` ENUM
   (`operator_wide` / `location`) makes the grant-scope explicit
   instead of inferring from `location_id IS NULL` (Toast's
   group-vs-location distinction). `users.primary_location_id`
   denormalization saves a join on every page load. `operators.region`
   reserves multi-region forward-compat. Plus 12 net-new `team.*`
   permission keys consumed by `9.10`. Cheap to add now while
   production1 is empty; expensive after `cutover.4`.

2. **Operator-self-service surface (`9.10`)** — the user's stated
   requirement for "ux in settings and also in the next slice"
   distinguishes between F&F super-admin tools (`9.9`,
   `admin.forgeflow.app`) and operator-self-service team management
   (`9.10`, inside the operator app). 9.10 lets `operator_owner` /
   `operator_manager` invite, assign roles, scope to locations,
   time-bound grants, and view audit log without F&F intervention.
   Mobile read-mostly; desktop / tablet full-edit (Toast pattern).

**Schema lock: 9.0 adds 11 new tables + extends 2 existing.**
New: `roles`, `permission_keys`, `role_permissions`, `user_roles`,
`auth_sessions`, `auth_events_audit`, `mfa_factors`, `tncs_acceptances`,
`password_history`, `auth_invites`, `role_audit_log`,
`external_identity_links`. Extends: `users` (firebase_uid, external_id,
status enum, soft-delete, roles_version, profile fields), `operator_admins`
(scope_type enum + valid_until). Append-only enforcement on
`auth_events_audit` and `role_audit_log` via `REVOKE DELETE, UPDATE`
from `service_role`.

**Sequence lock: 9.0-9.9 ships before 11A.0** (admin console
acceptance gate requires real auth) **and before any other pre-launch
phase.** Production schema flexibility remains open through `cutover.4`,
so any pre-launch phase that wants to extend Phase 9 schema can do so
additively without online-migration discipline.

## Phase 11A And Admin Decisions

- `11a.12` corpus admin and `11a.13` pricing tier admin are superseded by
  capital-A Phase 11A Operations Console.
- `11A.2` owns pricing tier admin over `usage_caps`.
- `11A.3` owns corpus admin UX.
- `11A.5` owns debug console with meta-only logs by default.
- `11A.6` owns observability across Postgres, AGE, pgvector, Cloud Run, and
  provider usage.
- Admin actions go through proxy `/v1/admin/*` routes, not direct DB access from
  the admin client.

## Parked Future Decisions

- Phase 9.8: T&Cs and liability disclaimer for recommendation-only advisor.
- Phase 9.8: output link/image allowlist.
- Phase 9.8: F&F pricing tiers and cap model.
- Pre-multi-operator: Sentry or equivalent error reporting, status page, and
  cap-event notifications.
- Post-100-locations: cost observability dashboards beyond the basic counter
  tables.
- `11b.2`: light advisor audit log (question, answer, timestamp, operator,
  cost); heavier replay tooling only if a dispute creates demand.
- Phase 12: per-operator vendor credential storage, operator fact data cloud
  sync, workflow state-machine tables, long-running workflow path, outbound
  webhooks, per-task agent bounds, and stronger prompt-injection architecture
  for write tools.
- Post-launch ops: operator-scoped export, restore, and delete tooling on top
  of the repository pattern.

If a parked decision becomes necessary for the current slice, surface it in
Block 1 under `Human prerequisites -> Decision needed for this slice` before
asking Claude to implement anything.

## Production Hardening Locks (2026-04-26 audit)

A standards audit against 2026 production RAG / multi-tenant Postgres /
agentic-workflow / LLM-resilience benchmarks surfaced 10 specific
hardening locks. Every one is wired into the slice plans listed.

### Lock 1: Vector index — evaluate DiskANN at provisioning

Slice: `11a.11c.6` acceptance.

HNSW outgrows `shared_buffers` fast: 193 MB at 25K rows balloons to ~77 GB
at 10M rows on `halfvec(3072)`. DiskANN benchmarks show 471 QPS at 99%
recall on 50M vectors (11.4× Qdrant; p95 28× lower than Pinecone s1).
9× compression keeps the navigational structure cached while full vectors
stay in heap. `pgvectorscale` 0.9.0+ supports `CREATE INDEX CONCURRENTLY`.

Lock: at `11a.11c.6`, run a DiskANN-vs-HNSW benchmark on the corpus at its
expected production scale (233 chunks now, project to 10K-100K). Pick the
winner; document the choice. If DiskANN wins, build `idx_chunks_diskann`
and drop the HNSW index in the same migration. The corpus rebuild in
`11a.11e` re-indexes regardless, so the swap is essentially free at this
slice.

Live result 2026-04-26: `pg_diskann` is available on Azure and a DiskANN
candidate index can be created, but the live corpus is only 233 chunks. The
planner correctly used sequential scan/top-N sort at that size, so this is not
a meaningful production-scale DiskANN benchmark. Launch decision: keep HNSW as
the authoritative live index. Re-benchmark DiskANN when corpus size reaches a
meaningful scale.

### Lock 2: `pg_partman` for `usage_logs` partition maintenance

Slice: `11a.11c.6` extensions allowlist + scheduled job.

Declarative partitioning (locked) does not auto-create future child
partitions. Without maintenance, rows land in the default partition and
performance degrades.

Lock: add `pg_partman` to `azure.extensions` allowlist alongside
`AGE`/`pgvector`/`pg_diskann`/`pg_cron`/`pg_stat_statements`/`pgcrypto`.
(`pgmq` is **not** on the Azure allowlist — live-verified 2026-04-26;
the Phase 12 queue path uses `FOR UPDATE SKIP LOCKED` plus Cloud
Tasks instead. See "Azure constraints discovered live 2026-04-26"
in Cloud And Operations Constraints.)
After `usage_logs` parent table exists, register it with pg_partman and
schedule `SELECT public.run_maintenance(p_analyze := true)` hourly via
`pg_cron`. Live Azure installed pg_partman functions into `public`, so the
verified function names are `public.create_parent` and
`public.run_maintenance`.
Retention: 24 months hot; archive older partitions to GCS Coldline via a
weekly export job.

Live result 2026-04-26: staging and Production1 each have 1 pg_partman config
row for `public.usage_logs` and 1 active `pg_cron` maintenance job targeting
`forgeflow`.

### Lock 3: AGE index strategy

Slice: `11a.11c.6` schema apply + acceptance.

Apache AGE does not auto-create indexes. Microsoft's perf doc explicitly
flags BTree on `id`, `start_id`, `end_id` as required for every vertex/
edge table. The AGE benchmark gate (isolated p95 ≤ 500ms; 10× concurrent
p95 ≤ 1000ms) cannot pass at production scale without these.

Lock: every graph schema applied to AGE in `11a.11c.6` (the `7.57.4`
projection schema and any new graphs added later) must include:

- BTree on `id` for every vertex table
- BTree on `start_id` for every edge table
- BTree on `end_id` for every edge table
- GIN on most-queried property paths (`Concept.name`, `Staff.staff_id`,
  workflow `WorkflowStep.step_id`, etc.)

Document the convention as a hard rule for any future AGE schema
addition (Phase 12 workflow definitions, Phase 11b.2 staff-coaching
relational extensions).

### Lock 4: RLS performance discipline — composite index leading column + `SET LOCAL`

Slice: CLAUDE.md guardrail + decision register + 11a.11c.6 schema apply
discipline.

Research: missing `tenant_id` (operator_id) as leading column makes RLS
**two orders of magnitude slower**. Properly indexed RLS shows zero
measurable degradation vs application-layer filtering. `SET LOCAL`
(transaction-scoped) is mandatory in pooled connections; `SET`
(session-scoped) leaks tenant context.

Lock:
- **Every fact-table index has `operator_id` (or `(operator_id,
  location_id)`) as the leading column.** Indexes that lead with anything
  else (e.g., `business_date`) are forbidden on operator-scoped tables.
  CI lint enforces.
- **Proxy session-variable injection uses `SET LOCAL`, never `SET`.** The
  proxy injects per-request session variables (`app.current_operator_id`,
  `app.current_location_id`, `app.current_staff_id`) inside the request
  transaction; pooled connection reuse never carries tenant context.

Live result 2026-04-26: the RLS-leading-column audit initially caught three
identity indexes. `202604250007_advisor_rls_index_hardening.sql` changed
`advisor_proxy_usage_counters` and `proxy_requests` to tenant-leading primary
and idempotency keys. Staging and Production1 now report 0 audit violations.

### Lock 5: Materialized view UNIQUE INDEX requirement

Slice: `11b.1` schema-foundation slice.

`REFRESH MATERIALIZED VIEW CONCURRENTLY` requires a UNIQUE INDEX on the
view. Without it, refresh takes an exclusive lock and blocks reads.

Lock: every materialized view created in `11b.1` (`staff_metrics_daily`,
`staff_metrics_weekly_rolling7`, `staff_metrics_period_60d`,
`staff_metrics_comparative`) declares a UNIQUE INDEX on its natural key
(typically `(staff_id, business_date, location_id)` or equivalent).
`pg_cron` schedules `REFRESH MATERIALIZED VIEW CONCURRENTLY ...` during
off-peak hours (default 02:15 UTC).

### Lock 6: Workflow state enum + idempotency key derivation

Slice: Phase 12.0 Foundation.

Industry-standard state model is `IN_PROGRESS → COMPLETED → FAILED` with
explicit invariants. Track 4 outcomes: success / explicit failure /
timeout / unknown. Idempotency keys derive from deterministic
flow_id + intent_params hash.

Lock: explicit `workflow_runs.status` enum:

```
PENDING → IN_PROGRESS → AWAITING_APPROVAL → COMPLETED
                     ↓             ↓
                   FAILED      CANCELLED
                     ↓
                   TIMEOUT
```

Invariants:
- `PENDING` → `IN_PROGRESS` only (worker pickup)
- `IN_PROGRESS` → any of `AWAITING_APPROVAL` / `COMPLETED` / `FAILED` /
  `TIMEOUT` / `AWAITING_BATCH`
- `AWAITING_APPROVAL` → `IN_PROGRESS` (operator approves) or
  `CANCELLED` (operator rejects)
- `AWAITING_BATCH` → `IN_PROGRESS` (batch completes) or `TIMEOUT`
  (>24h)
- `COMPLETED`, `FAILED`, `CANCELLED`, `TIMEOUT` are terminal

Idempotency key derivation: `sha256(workflow_id || canonical_json(intent_params))`.
Persisted to `workflow_runs.idempotency_key UNIQUE`. Retry with same
idempotency key returns the prior `output_artifact_url` instead of
re-executing.

`workflow_steps.attempt_number INT` tracks retries per step.

### Lock 7: Circuit breaker for LLM provider failures (BIGGEST GAP)

Slice: `11b.1` schema-foundation slice (PROMOTED from parked `11a.10d`).

Research: LLM providers run 99-99.5% uptime — 6-14× worse than cloud
infrastructure. Without circuit breaker behavior, the very first
Anthropic outage = F&F outage.

Lock: production resilience stack mandatory at `11b.1`:

1. **Per-provider circuit breaker** (Anthropic, Voyage, future Gemini):
   three states (Closed / Open / Half-Open).
2. **Open trigger**: 3 consecutive failures within 60s window OR
   rolling-100-request error rate > 25% OR p99 latency > 3× baseline.
3. **Cost-threshold trigger**: rolling-100-request average cost > 2×
   expected for that query class → open circuit on the high-cost
   provider, fall through to fallback chain.
4. **Half-open probe**: every 30s after open; single canary request;
   close on success.
5. **Fallback chain**:
   - Primary: Anthropic Sonnet (advisor) / Anthropic Haiku (classifier)
   - Secondary: Gemini 2.x Flash for routine workflows / cached
     response for advisor
   - Tertiary: graceful refusal payload with cap-status-style structure
     ("service degraded; try again shortly; here's your last cached
     answer if available")
6. **Per-failure-type handling**: 5xx → retry then trip; 429 → backoff
   then fallback; timeout → trip immediately on third occurrence; cost
   threshold → trip on the high-cost provider only.
7. **Telemetry**: `usage_logs.circuit_state TEXT` and
   `usage_logs.fallback_used TEXT` for visibility in `11A.6` dashboard.

Cost: implementation effort ~1 week; runtime cost zero (in-memory state
on each Cloud Run instance, with cross-instance sync via
Memorystore Redis if available).

### Lock 8: Anthropic Batch API poller worker

Slice: Phase 12.0 Foundation.

Lock: explicit batch poller worker as a Cloud Run jobs sibling service.
Queue mechanism is `SELECT ... FOR UPDATE SKIP LOCKED` directly
against `workflow_runs` (Azure does not expose `pgmq`; locked
2026-04-26 — see "Azure constraints discovered live 2026-04-26"
above):

```
1. Worker reads `workflow_runs WHERE status='AWAITING_BATCH'`
   AND `batch_polled_at < now() - interval '1 minute'`
   ... FOR UPDATE SKIP LOCKED LIMIT 50;
2. Calls Anthropic batch endpoint with `batch_id`
3. On batch completion:
   - Persists each result to `workflow_steps.result`
   - Transitions `workflow_runs.status` to `IN_PROGRESS`
     (continue agent loop) or `AWAITING_APPROVAL` (terminal step
     awaiting operator preview)
4. On batch timeout (>24h):
   - Transitions to `FAILED` with `failure_reason='batch_timeout'`
   - Marks retry-eligible if `attempt_number < 3`
5. Updates `batch_polled_at` to throttle polling
```

Schedule: `pg_cron` triggers worker every 30 seconds.

### Lock 9: Pub/Sub message format + topic naming + WebSocket lifecycle

Slice: Phase 10a plan.

Lock: explicit specification (prevents inconsistent payloads across
producers and consumers).

**Topic naming**: `shared_state.{operator_id}.{table}` (one topic per
operator-table pair; clients subscribe to operator-scoped topics only).

**Message payload schema** (versioned for forward compatibility):

```json
{
  "schema_version": 1,
  "operator_id": "uuid",
  "location_id": "uuid",
  "table": "weekly_plan_snapshots",
  "op": "INSERT" | "UPDATE" | "DELETE",
  "primary_key": "uuid_or_composite_string",
  "updated_at": "2026-04-26T12:34:56Z",
  "version": 47
}
```

Note: payload does NOT carry full row content; clients re-fetch the row
via `/v1/...` proxy. Reasons: (a) keeps Pub/Sub messages small;
(b) operator-scoped re-fetch goes through RLS so it's safe; (c) handles
schema changes without versioning the message body.

**Subscriber acks within 30s**; unprocessed messages route to dead-letter
topic `shared_state.deadletter` for later replay.

**WebSocket lifecycle**:
- 60-min idle timeout (Cloud Run cap); transparent client reconnect
- Last-seen-sequence in client → server resends missed messages on
  reconnect from operator's recent NOTIFY history (up to 5 min)
- Heartbeat every 30s
- Server closes connection if heartbeat missed for 90s
- Client falls back to 30-60s polling if WebSocket fails 3× consecutively

### Lock 10: Vendor token refresh `pg_cron` job

Slice: Phase 8.5.1 OAuth flow handler.

Lock: `pg_cron` runs hourly:

```sql
SELECT cron.schedule(
  'vendor_token_refresh',
  '5 * * * *',  -- 5 minutes past every hour
  $$SELECT proxy.refresh_expiring_vendor_tokens()$$
);
```

`proxy.refresh_expiring_vendor_tokens()` body:

```
For each row in vendor_credentials WHERE
  is_active = true AND token_expires_at < now() + interval '24 hours':
    - Call IntegrationProvider.refresh(vendor_id, refresh_token) via proxy
    - On success: update access_token + refresh_token + expires_at
    - On failure (3 consecutive): mark is_active=false; emit
      cap-event-style notification to F&F admin via 11A.4
      Integration Management
    - Audit row in vendor_credential_audit
```

This prevents silent token expiry → workflow failure mid-execution.
