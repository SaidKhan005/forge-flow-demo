# Phase 12 — Workflow Platform Program

Updated: 2026-04-29
Status: Planned (multi-quarter program, opens after `8.5` close)
Owner: Future workflow automation lane

## 2026-04-28 - Phase 9 Foundation Dependencies

`12.0` workflow platform foundation depends on:

- `9.0Σ.d` `service_principals` table (merged via `fe14b31`; B25 in
  `phase_9_execution_backlog.md`).
- `9.0Σ.d.1` `sp:`-prefixed JWT verifier (verified at
  `tool/advisor_proxy/advisor_proxy.dart` lines 353-462).
- B41 `service_principal` JWT issuance proxy route/client/tests are local
  complete. Before Phase 12 depends on live issuance, apply
  `202604290000_phase_9_b41_service_principal_issue_permission.sql` to staging
  + Production1 and smoke the route with the deployed proxy.

Workflows authenticate as service principals; the audit trail uses
`actor_kind='service'` per `auth_events_audit` and `actor_principal_id`
per `audit_logs` (see B34 in `phase_9_execution_backlog.md` for the
attribution-naming contract).

This is the active execution plan for Phase 12. Architecture rationale, cost
posture, and pricing implications live in
`docs/phases/phase_11a/phase_11a_decision_register.md` (Phase 12 Workflow
Platform Program section).

## Why Phase 12 is a program, not a phase

Phase 12 ships **the workflow platform** F&F sells as the Pro and Enterprise
tier differentiator. The vision spans:

- Scheduled agentic workflows (Weekly P&L, monthly variance review, daily
  prep checklist)
- Event-triggered workflows (Friday close → weekend recap; new invoice →
  categorize and route)
- Relational reasoning queries (server↔training↔metrics) — the staff-coaching
  vision ("why was my SPLH low last week?")

These capabilities don't fit one phase doc. The program is split into
sub-slices `12.0–12.5` (foundation) plus an open-ended `12.x+` workflow
catalog backlog.

## Goal

Build the workflow platform substrate so any AI surface (advisor 11b, future
Barrio coaching, server-facing personal coaching, scheduled and event-driven
agents) reuses the same plumbing: tool registry, agent loop, approval gates,
audit log, integration calls, and cost discipline.

Server-facing personal coaching ("why was my SPLH low?") consumes:
- SQL on `staff_metrics_*` materialized views (from `11b.1`)
- AGE traversal on the methodology + staff↔training↔metrics graph
- Anthropic Contextual Retrieval on training/SOP corpus
- Synthesis via Claude Sonnet (or Haiku for routine, per Hard Promise #8)
- Optional workflow trigger (e.g., "schedule me a wine-training drill")

Scheduled workflows like Weekly P&L consume:
- Phase 8.5 integrations (POS sales, labor costs, accounting GL, AP
  invoices, optional banking feed)
- Anomaly detection + categorization tools
- Narrative generation (Sonnet)
- PDF + email delivery
- Operator approval gate before final delivery

## Non-Negotiables

- Per-task caps (token, cost, tool-call, wallclock, parallel) enforced
  server-side; never absorbed by F&F (Hard Promise #9).
- Per-action consent for irreversible actions (schedule, comms, financial)
  per Hard Promise #6.
- Plan-Then-Execute pattern + CaMeL two-LLM separation for write paths.
- Append-only `workflow_audit_log`; never mutate or delete audit rows.
- All workflows go through the same `LLMProvider` / `EmbeddingProvider` /
  `RerankProvider` / `IntegrationProvider` abstractions (Hard Promise #8).
- Anthropic Batch API used for async workloads (lever 5; 50% discount).
- New operators default `workflows_enabled = false`; must explicitly opt in
  per workflow.
- Workflow execution runs in Cloud Run jobs sibling service; never blocks
  the request-handling proxy.

## Sub-Slice Sequence

### `12.0` Foundation (~3-5 weeks)

Schema:
- `workflow_definitions(workflow_id, operator_id NULL, name, definition_age_graph_id, ...)`
- `workflow_schedules(workflow_id, operator_id, location_id, cron_expression, timezone, enabled, last_run_at, next_run_at)`
- `workflow_runs(run_id, workflow_id, scheduled_for, started_at, completed_at, status, input_snapshot JSONB, output_artifact_url, total_cost_usd, idempotency_key TEXT UNIQUE, batch_id TEXT NULL, batch_polled_at TIMESTAMPTZ NULL, attempt_number INT, ...)`
- `workflow_steps(step_id, run_id, step_index, tool_called, args, result, llm_provider, model, batch_mode, input_tokens, cached_input_tokens, output_tokens, cost_usd, attempt_number INT, ...)`
- `workflow_audit_log(...)` append-only

**State machine (Lock 6 in decision register Production Hardening Locks)**:

```
PENDING → IN_PROGRESS → AWAITING_APPROVAL → COMPLETED
                     ↓             ↓
                   FAILED      CANCELLED
                     ↓
                   TIMEOUT
                     ↑
                AWAITING_BATCH (transitional during async LLM batch)
```

Invariants enforced via DB CHECK constraints + repository transition
methods:
- `PENDING` → `IN_PROGRESS` only
- `IN_PROGRESS` → any of `AWAITING_APPROVAL` / `AWAITING_BATCH` /
  `COMPLETED` / `FAILED` / `TIMEOUT`
- `AWAITING_APPROVAL` → `IN_PROGRESS` (operator approves) /
  `CANCELLED` (operator rejects)
- `AWAITING_BATCH` → `IN_PROGRESS` (batch completes) / `TIMEOUT`
  (>24h since `batch_polled_at`)
- `COMPLETED`, `FAILED`, `CANCELLED`, `TIMEOUT` are terminal

**Idempotency key derivation** (Lock 6):
`idempotency_key = sha256(workflow_id || canonical_json(intent_params))`.
Persisted with UNIQUE constraint. Retry with same key returns prior
`output_artifact_url` instead of re-executing.

Infrastructure:
- `pg_cron` scheduled job runner inside Postgres (already allowlisted in
  `11a.11c.6`)
- Cloud Scheduler triggers (alternative for non-Postgres-driven schedules)
- **Workflow execution queue: `SELECT ... FOR UPDATE SKIP LOCKED`
  against `workflow_runs`.** No `pgmq` extension — Azure DB Flexible
  Server does not expose it (live-verified 2026-04-26 on
  `forge-flow-staging-pg`; see
  `docs/phases/phase_11a/phase_11a_decision_register.md` →
  "Azure constraints discovered live 2026-04-26"). The batch poller
  pattern below is the canonical in-DB queue mechanism for this
  phase. HTTP-delivery queues (push to a Cloud Run sibling) use
  **Google Cloud Tasks** — Cloud Tasks integrates natively with
  Cloud Run, so there is no cross-cloud egress.
- Cloud Run jobs sibling service for execution
- `LLMProvider.submitBatch(requests)` extension (Anthropic Batch API)
- Per-task caps wired into agent loop runtime (token / cost / tool-call /
  wallclock / parallel)
- Workflow artifact storage in GCS bucket; lifecycle rules (Standard →
  Nearline 30d → Coldline 90d → Archive 1y)

**Batch poller worker (Lock 8 in decision register)**:

Runs as Cloud Run job triggered every 30 seconds via `pg_cron`. Logic:

```
1. SELECT * FROM workflow_runs
   WHERE status = 'AWAITING_BATCH'
     AND (batch_polled_at IS NULL OR batch_polled_at < now() - interval '1 minute')
   FOR UPDATE SKIP LOCKED LIMIT 50;

2. For each run:
   - Call Anthropic batch endpoint with run.batch_id
   - On batch completion:
     - Persist each result to workflow_steps
     - Transition run.status to IN_PROGRESS (continue agent loop) or
       AWAITING_APPROVAL (terminal step awaiting operator preview)
   - On batch timeout (>24h since AWAITING_BATCH transition):
     - Transition run.status to FAILED with failure_reason='batch_timeout'
     - Mark retry-eligible if attempt_number < 3
   - Update run.batch_polled_at = now()
3. Commit transaction.
```

Acceptance:
- Synthetic workflow runs end-to-end on staging through every state
  transition (PENDING → IN_PROGRESS → AWAITING_APPROVAL → COMPLETED)
- State transition invariants enforced (illegal transitions raise)
- Idempotency: re-submit same workflow + intent_params → returns prior
  output_artifact_url, does NOT re-execute
- Per-task caps enforced; runaway agent terminated gracefully with
  auto-summary at 80% of cap
- Audit log captures every step + every state transition
- Batch poller worker proven against Anthropic batch sandbox: submit →
  AWAITING_BATCH → poll → IN_PROGRESS → COMPLETED end-to-end
- Workflow artifact uploaded to GCS with operator-scoped path

### `12.1` Tool Registry (~2-3 weeks)

- Catalog of read-only and write-tool functions with input/output JSON
  schemas
- Tool function registry annotates each tool with:
  - `cost_tier` (free / cheap / medium / expensive) — agent planner prefers
    cheaper tools
  - `requires_consent` (boolean) — gates write-tools behind operator approval
  - `provider` — `LLMProvider`, `EmbeddingProvider`, `IntegrationProvider`,
    `SQLProvider`, etc.
- Tool discovery API: agents query the registry to find tools matching an
  intent
- Per-operator tool allowlist (gated by tier + feature flags)

Acceptance:
- Registry surface returns tool definitions filtered by
  `(operator_id, subscription_tier, feature_flags)`
- Write-tools can't be invoked without `requires_consent` flow

### `12.2` Plan-Then-Execute Orchestrator (~3-4 weeks)

- Agent loop: planning step (Sonnet) → execute tools (Haiku where possible) →
  observe results → summarize
- CaMeL two-LLM separation when write path touches operator-supplied content
- Per-task `max_iterations` cap (default 5)
- Auto-summary at 80% of cap (graceful failure, not hard cut-off)
- Plan artifacts persisted to `workflow_steps.args` for reproducibility

Acceptance:
- Plan-Then-Execute runs against synthetic workflow with deterministic
  outcome
- CaMeL separation proven on a write-path test (quarantined LLM extracts;
  privileged LLM acts; symbolic variables only between them)
- Reproducibility test: re-running with same `input_snapshot` produces same
  output

### `12.3` Approval Gate UI (~2 weeks)

Operator preview-and-approve UI for high-stakes workflows. Lives in:
- `11A` Operations Console for F&F admin oversight
- `lib/main_forgeflow.dart` operator app for self-serve approval

Surface:
- Plan diff: "Here's what the agent proposes to do. Approve / reject / edit
  before execution."
- Per-step preview for multi-step workflows
- Per-action consent gate for irreversible actions
- "Diff from last run" highlighting (e.g., this week's P&L vs last week's,
  with anomalies flagged)
- Re-run button if agent missed something
- Versioning ("P&L v3 finalized 2026-XX-XX after manager edit")

Acceptance:
- Workflow paused at approval gate; doesn't execute until operator confirms
- Edits flow back into plan; re-execution uses edited plan
- Audit log captures approval / edit / reject events with `approved_by_uid`

### `12.4` Weekly P&L Workflow (flagship; ~3-4 weeks)

The first end-to-end production workflow. Validates the entire 12.0–12.3
substrate.

Inputs (consumes Phase 8.5 integrations):
- POS revenue + product mix (Phase 8 — Toast/Square/etc.)
- Labor cost + hours (Phase 8 — 7shifts/Homebase/etc.)
- Accounting GL via QBO or Xero (Phase 8.5)
- AP / vendor invoices via Bill.com or QBO bills (Phase 8.5)
- Optional: banking feed for cash reconciliation via Plaid (Phase 8.5)

Pipeline:
1. Schedule fires (Sunday night, operator's local timezone)
2. Workflow run instantiates; input_snapshot captures current data fetches
3. Agent (Sonnet, batch mode) categorizes transactions, identifies anomalies,
   computes P&L line items, drafts narrative
4. PDF generated (Chrome headless in Cloud Run)
5. Approval gate: operator reviews preview Monday morning
6. Approved → email delivered (Resend or SendGrid free tier; ~3K emails/mo
   covers MVP)
7. Workflow run finalized; PDF + JSON artifact stored in GCS

Acceptance:
- End-to-end run on synthetic operator (Vanessa beta)
- Reconciliation: P&L numbers match QBO + POS + labor reports
- Anomaly detection surfaces ≥ 2 documented anomalies on a synthetic edge
  case dataset
- Operator approval flow tested
- Cost per run measured (target: ~$0.50-1.50 per P&L with batch API + tier
  routing)

### `12.5` Workflow Catalog + Per-Operator Activation (~2 weeks)

- Operator browses catalog in 11A or operator app
- Per-tier feature flag gates which workflows are visible (Pro tier sees the
  full catalog; Elite sees nothing; Enterprise sees Pro + custom)
- One-click activation creates `workflow_schedules` row with operator's
  defaults (e.g., Sunday 11pm local time for Weekly P&L)
- Per-operator overrides for cron expression, recipients, etc.
- Activation event triggers cap row in `usage_caps` for `workflow_<id>` axis

Acceptance:
- Catalog renders only allowed workflows per `operators.subscription_tier`
- Activation creates schedule + cap row + audit log entry
- Deactivation pauses schedule (doesn't delete; preserves history)

## Workflow Catalog Backlog (12.x+)

Each is a separate sub-slice. Order is roughly demand-driven:

- **Schedule Generator** — proposes weekly schedule based on demand forecast +
  staff availability + labor target. Approval gate mandatory. ~2-3 weeks.
- **Inventory Recommender** — daily ordering recommendations based on sales
  pace + par levels + vendor lead times. ~2-3 weeks. Requires inventory
  integration (Phase 8.5+).
- **Vendor Reconciliation** — invoice arrives → agent categorizes, matches
  to PO, flags discrepancies. ~2 weeks.
- **Customer Feedback Synthesis** — review-platform feeds (Yelp, Google,
  OpenTable) → agent summarizes themes + flags actionable issues. ~2 weeks.
- **Performance Reviews** — monthly per-staff narrative summary (data via
  `staff_metrics_*` views; methodology via Contextual Retrieval; AGE for
  drill recommendations). ~2-3 weeks.
- **Marketing Email Drafts** — agent drafts weekly email based on operator's
  events / specials / staff highlights. Cheaper model (Gemini Flash via
  `LLMProvider` cross-provider arbitrage) ~1-2 weeks.
- **Daily Prep Checklist** — pre-shift agent generates day's focus based on
  previous day's variance + next day's reservations. ~1-2 weeks.

Custom workflows (Enterprise tier) are quote-based; engineered per operator
via the same 12.0–12.3 substrate.

## Server-Facing Personal Coaching (consumes 12.0-12.3)

Not a workflow per se, but rides the same agent loop runtime. Server asks:
- "Why was my SPLH low last week?"
- "How can I beat Maria's tip rate?"
- "What's the one thing I should focus on Tuesday?"

Pipeline:
1. Haiku classifier identifies intent + scope (`personal_metric` /
   `comparative_metric` / `causal_chain` / `recommendation`)
2. Tools execute in parallel where possible:
   - SQL on `staff_metrics_daily` / `staff_metrics_comparative`
   - AGE traversal on staff↔training↔metrics + methodology causal chains
   - Contextual Retrieval on coaching corpus
3. Sonnet synthesizes with provenance (cited methodology chunks, traversal
   path)
4. Optional workflow proposal (e.g., "Want me to schedule a wine-training
   drill before your Friday shift?")

Per-staff caps protect operator's monthly budget (Hard Promise #9). Pre-
computed answers serve 70-80% of recurring questions at $0 (lever 4).

## Dependencies

- `11a.11c-e` complete (Azure DB live with AGE + pgvector + pg_cron +
  pg_partman + pg_diskann + pg_stat_statements + pgcrypto). `pgmq` is
  **not** required and is **not** on Azure's `azure.extensions`
  allowlist; the workflow execution queue uses
  `SELECT ... FOR UPDATE SKIP LOCKED` instead, with Cloud Tasks for
  HTTP-delivery queues.
- `11A.0-6` complete (admin console; pricing tier admin + cost telemetry
  surfaces working)
- `11b` complete (advisor + Modular Adaptive RAG retrieval pattern proven)
- `11b.1` complete (operator fact data cloud sync; `staff_id` axis;
  materialized metrics views; response cache + Memorystore wired;
  pre-computed summaries job running)
- `11b.2` complete (advisor + AGE causal traversal proven in production)
- `8.5` complete or in-flight (at minimum QBO integration done; Bill.com /
  Plaid additional workflows light up as their integrations land)
- Hard Promise #6 (recommendation-only) extends to per-action consent for
  workflow write-tools — Phase 9.8 T&Cs codify operator's consent regime

## Source Material

- `docs/phases/phase_11a/phase_11a_decision_register.md` — architecture lock,
  cost levers, pricing tier model
- `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md` — 11a.11c-e
  prerequisites for AGE + extension allowlist
- `docs/phases/phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md`
  — integration lane Phase 12 consumes
- Anthropic Message Batches API documentation
- Simon Willison "Plan-Then-Execute" design pattern paper (June 2025)
- CaMeL two-LLM separation pattern
