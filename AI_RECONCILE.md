# AI Reconcile

Updated: 2026-04-27

Purpose: reconcile the current AI/advisor architecture with the product goal:
the AI should answer operator, web-reporting, and F&F dev/admin questions in
the right style, with the right facts, and with enough provenance to be trusted.

## Plain-English Goal

F&F should not ship one generic chatbot everywhere.

It should have one shared advisor backend, but the answer should change based
on where the question is asked:

```text
Phone app
-> short daily operator guidance

Operator web console
-> deeper reporting explanations with evidence and drill-down context

F&F dev/admin web
-> technical health, debug, impact, and runbook answers
```

Same truth. Same proxy. Same permissions. Different answer depth and format.

Example question:

```text
Why is Region East labor high this week?
```

Phone app answer:

```text
Dinner BOH is the main issue. King Street and Queen Street are over plan.
Focus on prep hours tonight.
```

Operator web answer:

```text
Region East is $4,200 over labor plan. 62% comes from Friday/Saturday dinner
BOH. This is compared against WeeklyPlanSnapshot W17 and TargetCycle
March-April. King Street is the biggest driver.
```

F&F dev/admin answer:

```text
Labor variance rollup is fresh. Sales rollup is 3 minutes stale.
No rebuild needed. Last processed sequence: 982104.
Affected reports: Region Dashboard, Labor Variance.
```

## Where We Are

The AI foundation exists. The finished advisor does not.

Already present:

- Server-side advisor proxy boundary.
- Firebase/JWT scope guard.
- Production provider keys kept off the client.
- Advisor corpus storage tables.
- pgvector search function.
- BM25 retrieval columns.
- Voyage embedding/rerank abstractions.
- Claude/LLM abstraction.
- Usage cap/accounting/idempotency scaffolding.
- Health endpoint scaffold.
- Phase 11b advisor UX plan.
- App-side locked business truth: `TargetCycle`, `WeeklyPlanSnapshot`,
  closed shifts, Variance, History, and Learn.

Important current files:

- `tool/advisor_proxy/advisor_proxy.dart`
- `tool/advisor_proxy/main.dart`
- `docs/archive/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md` (substrate accepted)
- `docs/phases/phase_11b/phase_11b_advisor_ux_plan.md`
- `db/migrations/202604250001_advisor_corpus_storage_schema.sql`
- `db/migrations/202604250003_advisor_vector_search.sql`
- `db/migrations/202604250006_advisor_contextual_retrieval_telemetry.sql`
- `lib/domain/services/llm_provider.dart`
- `lib/domain/services/embedding_provider.dart`
- `lib/domain/services/rerank_provider.dart`
- `lib/services/claude_llm_provider.dart`
- `lib/services/voyage_embedding_provider.dart`

## Current Reality

The current proxy has a smoke route:

```text
GET /v1/advisor-smoke
```

That route is useful for proving scaffolding:

- auth scope
- idempotency
- usage accounting shape
- prompt cache block shape
- tier routing
- model telemetry

But it is not the real advisor.

Current limitations:

- It uses placeholder methodology context.
- It uses placeholder tool definitions.
- It does not run real retrieval.
- It does not call live operational/reporting tools.
- Production `main.dart` wires a rejecting LLM provider scaffold.
- It does not write the new per-conversation advisor log.

So the architecture is promising, but the actual product path still needs the
answer router, real endpoint, real tools, and surface-specific response
contract.

## What The AI Must Support

The advisor needs to answer different kinds of questions.

Operator/phone examples:

- "What should I focus on today?"
- "Why was lunch bad yesterday?"
- "Are we over labor right now?"
- "What is my main leak this week?"

Operator web examples:

- "Why is Region East labor high this week?"
- "Which location drove the COGS increase?"
- "Why did this report change after yesterday?"
- "What does this variance compare against?"
- "Which weekly plan and target cycle was this based on?"

F&F dev/admin examples:

- "Why is this operator's report stale?"
- "Can I safely rebuild this rollup?"
- "Is AGE graph health okay?"
- "Is pgvector still under the HNSW threshold?"
- "Which dashboards are affected by this failed job?"
- "Did this advisor answer use the right chunks/model/version?"

## Main Architecture Gap

The missing layer is an `AdvisorAnswerRouter`.

It should sit inside the proxy between the request route and the retrieval /
tool / LLM providers.

```text
advisor request
-> auth/scope guard
-> usage guard
-> AdvisorAnswerRouter
-> query classifier
-> tool registry
-> retrieval / SQL / health tools
-> Claude synthesis
-> structured answer
-> advisor_conversation_log
```

The answer router decides:

- what kind of question this is
- which tools are required
- whether methodology retrieval is needed
- whether AGE traversal is needed
- whether SQL/reporting data is enough
- what response style to use
- what evidence/provenance must be returned
- whether the request is allowed for that actor/surface

## Gap 1: No Real Advisor Endpoint

Needed endpoint:

```text
POST /v1/advisor/query
```

Suggested request shape:

```json
{
  "conversation_id": "conv_123",
  "question": "Why is labor high this week?",
  "surface": "operator_web",
  "scope": {
    "org_unit_id": "org_123",
    "location_id": null,
    "grain": "week",
    "period": "current_week"
  },
  "locale": "en-CA"
}
```

The route should:

- authenticate the user
- resolve operator/location/org scope
- enforce permissions
- enforce usage caps
- call the answer router
- write the advisor conversation log
- return a structured answer

## Gap 2: No Surface-Specific Answer Contract

Every advisor query should carry:

```text
surface = phone_app | operator_web | ff_dev_web
```

Surface behavior:

```text
phone_app
-> concise, daily, practical, action-oriented

operator_web
-> report-aware, evidence-backed, drill-down friendly

ff_dev_web
-> technical, health-aware, impact + runbook oriented
```

This prevents one generic answer style from leaking into every product surface.

## Gap 3: Query Classes Are Too Broad

Current classes are a good start:

```text
methodology_lookup
personal_metric
comparative_metric
causal_chain
recommendation
workflow_action
```

F&F now needs more granular classes for the reporting/dev-health questions the
user is locking:

```text
variance_explanation
reporting_rollup
locked_snapshot_explanation
late_arriving_data
rollup_freshness
rollup_rebuild
rollup_error
integration_health
graph_health
vector_health
event_bridge_health
usage_cap_status
provider_health
audit_replay
```

These query classes let the router choose the right tools and answer format.

## Gap 4: No Operator Reporting Tools Yet

Operator web reporting needs tools like:

```text
get_sales_rollup
get_labor_rollup
get_cogs_rollup
get_variance_summary
get_variance_drivers
get_report_freshness
get_late_arriving_data_events
get_weekly_plan_snapshot
get_target_cycle
get_rollup_rebuild_status
```

These tools should read the same source truth and rollups used by the web UI.

The AI should not recalculate from raw facts when a trusted rollup/read model
already exists.

## Gap 5: No Dev/Admin Health Tools Yet

F&F dev/admin web needs tools like:

```text
get_rollup_health
get_graph_health
get_vector_index_health
get_provider_health
get_integration_health
get_event_bridge_health
get_usage_health
get_recent_failures
get_affected_reports
get_safe_actions
```

These power the F&F standard:

```text
What is happening?
Who is affected?
Which surface/report is affected?
How stale or risky is it?
What action should F&F take?
Is retry/rebuild/promote safe?
```

## Gap 6: No Structured Response Shape

The advisor should not return only plain text.

It should return human text plus machine-readable metadata.

Suggested response:

```json
{
  "answer": "Region East labor is high because dinner BOH ran over plan...",
  "surface": "operator_web",
  "query_class": "variance_explanation",
  "confidence": "high",
  "data_as_of": "2026-04-27T14:03:00Z",
  "freshness_status": "fresh",
  "warnings": [],
  "evidence": {
    "weekly_plan_snapshot_id": "wps_123",
    "target_cycle_id": "tc_456",
    "retrieved_chunk_ids": ["chunk_1", "chunk_2"],
    "retrieved_graph_paths": [],
    "tool_calls": [
      "get_variance_summary",
      "get_target_cycle"
    ]
  },
  "recommended_actions": [
    {
      "label": "Review BOH prep hours for Friday dinner",
      "action_type": "operator_review",
      "safe_to_execute": false
    }
  ]
}
```

For launch, actions are recommendations only. F&F does not act on behalf of the
operator unless a later workflow approval path explicitly allows it.

## Gap 7: Advisor Conversation Log Not Implemented Yet

The decision is locked, but the table/writer still need to be built.

Needed table:

```text
advisor_conversation_log
```

Every advisor turn should store:

- `conversation_id`
- `turn_id`
- `operator_id`
- `location_id`
- `actor_user_id`
- question hash
- encrypted raw question
- retrieved chunk IDs
- graph paths
- query class
- model ID/version
- system prompt hash
- prompt cache hit
- answer/recommendation hash
- encrypted raw answer/recommendation
- tokens in/out
- latency
- created at

This supports deterministic replay:

```text
What did the operator ask?
What did the advisor retrieve?
Which model answered?
What did it say?
Was the answer grounded?
```

This protects both directions:

- protects F&F when the advisor was right
- protects the operator when the advisor was wrong

## Gap 8: Dev UX Health Standard Needs To Be AI-Readable

The user has set a product standard:

Every technical alert/tripwire needs:

- explanation
- affected functionality
- affected operator/scope
- severity
- recommended action
- owner
- runbook
- audit/rebuild status

This applies to:

- rollups
- AGE graph health
- pgvector/DiskANN vector health
- provider health
- integration sync health
- NOTIFY/Pub/Sub bridge health
- usage caps
- cache health
- rebuild jobs

The AI can only answer dev/admin questions correctly if those health states
exist in structured tables/views/tools.

## How To Get There

Recommended build sequence:

```text
1. Define advisor request/response contract
2. Add surface modes
3. Expand query-class taxonomy
4. Add advisor answer router
5. Add tool registry
6. Add operator reporting tools
7. Add dev/admin health tools
8. Add real /v1/advisor/query endpoint
9. Add structured response format
10. Add advisor_conversation_log table + writer
11. Build phone app advisor UI
12. Build operator web "ask this report" UI
13. Build F&F dev/admin ask-health/debug UI
14. Add advisor learned-insights candidate table
15. Build F&F dev/admin learned-insights review/search/approval UX
16. Add approved-lesson-to-corpus promotion workflow
```

## Proposed Lock

```text
AI Advisor Surface-Aware Answering — Locked.

F&F uses one shared advisor backend through the proxy, but every advisor
request carries a surface field: phone_app, operator_web, or ff_dev_web.

The AdvisorAnswerRouter uses surface + query_class + actor permissions +
operator/location/org scope to choose retrieval, SQL/reporting tools,
health tools, model tier, response depth, evidence detail, and allowed
recommended actions.

Phone app answers are short, practical, and daily-operations oriented.
Operator web answers are report-aware, evidence-backed, and include relevant
locked plan/target/freshness provenance. F&F dev/admin web answers are
technical, health-aware, and include affected functionality, safe actions,
runbook pointers, and escalation state.

All advisor turns return structured metadata and write an
advisor_conversation_log row for deterministic replay.
```

## Practical Product Rule

The advisor should always know five things before answering:

```text
1. Who is asking?
2. Where are they asking from?
3. What kind of question is this?
4. Which facts/tools are authoritative?
5. How fresh and trustworthy is the data?
```

If it does not know those things, it should say what is missing instead of
guessing.

## Advisor Learned Insights

The user wants F&F to keep what the AI learns.

This is plausible, but the architecture should not mean that Claude/the model
silently remembers everything forever.

The correct model is:

```text
AI proposes lessons
-> F&F shows them in dev/admin UX
-> human edits / amends / approves
-> approved lesson enters the corpus
-> future advisor answers can retrieve it with provenance
```

In plain English:

The model remains stateless. F&F owns the memory.

The current Phase 11b plan says the model retains nothing between queries and
has no silent model memory. Keep that. It protects tenant isolation, privacy,
and explainability.

What changes is that F&F adds an approved operational memory layer in its own
database.

### What Counts As Learning

There are three different things people call "AI learning":

```text
1. Conversation log
   What did the user ask and what did the advisor answer?
   This is audit/replay evidence, not automatic memory.

2. Operational learning
   What patterns did F&F observe in closed facts, rollups, Learn, History,
   WeeklyPlanSnapshot, TargetCycle, variance, or outcomes?
   Example: "Friday dinner BOH repeatedly runs over labor plan at King Street."

3. Approved memory
   What has F&F or an authorized user reviewed and allowed the advisor to use
   again?
   Example: "King Street Wednesday trivia nights usually require one extra FOH
   closer."
```

The advisor can propose a lesson, but F&F should not automatically treat it as
truth until it is backed by data or approved by a human.

### Proposed Product Flow

```text
Advisor conversation / report pattern / operator feedback / closed outcome
-> learning candidate generated
-> candidate appears in F&F dev/admin UX
-> categorized by topic
-> searchable by keyword and semantic meaning
-> F&F staff edits or amends the lesson
-> F&F staff approves, rejects, expires, or keeps pending
-> approved lesson is promoted into the advisor corpus
-> corpus pipeline chunks, embeds, indexes, and versions it
-> future advisor answers can retrieve it with citations/provenance
```

Example:

```text
The AI notices:
"King Street keeps missing labor target on Wednesday dinner when trivia night
is active."

It creates a pending lesson:
Topic: Labor
Scope: King Street
Evidence: 6 Wednesday dinner shifts
Confidence: medium
Sensitivity: non-sensitive operational
Status: pending approval

F&F edits it to:
"King Street Wednesday trivia nights usually require one extra FOH closer."

F&F approves it.

The approved lesson enters the operator/location-scoped corpus and becomes
retrievable in future advisor answers.
```

### Dev/Admin UX Requirement

F&F dev/admin must include a Learned Insights panel.

It should show learning candidates grouped by:

```text
topic
operator
org unit
location
source surface
query class
status
confidence
sensitivity
evidence strength
created date
last updated date
approver
```

Useful topic categories:

```text
labor
sales
COGS
reservations
forecasting
service periods / dayparts
staff coaching
training / SOP
vendor integration
reporting / rollups
billing / usage
compliance / audit
operator preference
local event / context
```

Each candidate should show:

```text
proposed lesson
plain-English reason
source conversations / report IDs / rollup IDs / snapshot IDs
supporting evidence
conflicting evidence
scope where the lesson applies
whether it is safe to promote
recommended action
audit history
```

Allowed actions:

```text
edit / amend
merge with existing lesson
approve
reject
expire
mark sensitive
request more evidence
promote to corpus
```

### Search Architecture

The Learned Insights searchbar should use hybrid search, not vector-only.

Use:

```text
BM25 / text search
-> exact terms like Toast, King Street, CPLH, trivia, Wednesday

Vector semantic search
-> meaning searches like "event night labor problem" or
   "recurring dinner staffing issue"

Filters
-> topic, operator, location, status, confidence, source, sensitivity

Optional rerank
-> better ordering when search returns many candidates
```

This matches F&F's current direction:

```text
advisor_source_chunks
pgvector
BM25 tsvector
Voyage embeddings
Voyage rerank
Contextual Retrieval
corpus_version
content hashes
```

Research support:

- Anthropic Contextual Retrieval recommends combining embeddings, BM25,
  contextual chunking, and reranking to reduce retrieval failures.
- OpenAI's retrieval/vector-store model uses chunking, embedding, indexing,
  metadata attributes, and asynchronous file/index operations.
- NIST's AI risk guidance points toward human review, tracking,
  documentation, data provenance, retention, and change-management controls
  for generative AI systems.

### Schema Shape

Add a pending-candidate table:

```text
advisor_learning_candidates
```

Suggested columns:

```text
candidate_id
operator_id
org_unit_id
location_id
topic
source_surface
source_query_class
source_conversation_id
source_turn_id
source_report_id
source_rollup_id
source_snapshot_id
proposed_lesson
amended_lesson
evidence_summary
supporting_evidence_refs[]
conflicting_evidence_refs[]
confidence
sensitivity
status
created_by_model_id
created_by_model_version
created_at
updated_at
reviewed_by_user_id
reviewed_at
review_note
expires_at
promoted_doc_id
promoted_chunk_ids[]
```

Statuses:

```text
candidate
needs_more_evidence
approved
rejected
expired
promoted
```

Add an approved memory/corpus bridge:

```text
advisor_approved_lessons
```

or promote approved lessons directly into:

```text
advisor_source_documents
advisor_source_chunks
```

through a generated Markdown document.

The safer pattern is:

```text
advisor_learning_candidates
-> approval
-> generated Markdown lesson document
-> existing corpus ingestion pipeline
-> advisor_source_documents / advisor_source_chunks
-> embeddings / BM25 / graph projection
```

That keeps one corpus path instead of inventing a second memory path.

### Markdown Promotion Format

Approved lessons should become Markdown that the current corpus pipeline can
ingest.

Example:

```markdown
---
source: advisor_learning_candidate
candidate_id: alc_123
operator_id: op_456
location_id: loc_789
topic: labor
sensitivity: non_sensitive_operational
approved_by: user_123
approved_at: 2026-04-27T14:00:00Z
corpus_version: operator_456_lessons_v3
---

# King Street Wednesday Trivia Labor Pattern

King Street Wednesday trivia nights usually require one extra FOH closer.

Evidence:
- 6 closed Wednesday dinner shifts reviewed.
- Labor variance repeatedly exceeded target during trivia-night service.
- Applies only to King Street unless promoted wider.
```

Then the existing pipeline handles:

```text
chunk
hash
embed
BM25 index
optional graph projection
version
retrieve
cite
```

### Guardrails

Do not put raw sensitive personal information into approved lessons.

Do not mix operator-specific lessons into global F&F methodology.

Do not let the AI auto-approve lessons.

Do not let learned lessons override locked facts:

```text
TargetCycle
WeeklyPlanSnapshot
closed shifts
audit logs
rollups
billing records
vendor source facts
```

Approved lessons explain and guide. They are not the source of financial or
operational truth.

If a lesson is based on sensitive raw text, redact the sensitive text and keep
only safe operational learning with provenance.

If a source conversation is redacted under Q21, the candidate should keep
safe metadata and record that full replay is limited.

### Proposed Lock

```text
Advisor Learned Insights — Proposed.

The model remains stateless and does not silently retain memory. F&F persists
AI-proposed learned insights as reviewable, operator-scoped learning
candidates. Candidates appear in the F&F dev/admin UX categorized by topic,
scope, source, confidence, sensitivity, and status. Dev/admin search uses
hybrid retrieval: keyword/BM25, vector semantic search, filters, and optional
rerank.

F&F staff may amend, approve, reject, expire, or request more evidence for
candidates. Only approved, non-sensitive lessons are promoted into the advisor
corpus through the same Markdown/chunk/embed/index/version pipeline used for
methodology documents. Approved lessons keep provenance, evidence links,
approver, version, scope, and audit history. Operator-specific lessons remain
scoped to that operator/location/org unit and never become global methodology
unless explicitly promoted by F&F.
```

## Final Critique

The architecture is pointed in the right direction.

The main risk is shipping a generic chatbot before the answer router and tool
contracts exist.

F&F needs an answering system:

```text
surface-aware
query-class-aware
permission-aware
tool-grounded
freshness-aware
provenance-logged
recommendation-only
```

That is the gap between the current foundation and the product the user is
describing.
