# Phase Production Cutover

Updated: 2026-04-29
Status: Planned (opens after `11b` ships against staging and `11A.0-6`,
`9`, `9.8` accept)
Owner: F&F launch lane

## 2026-04-28 - Phase 9 Foundation Dependencies

`cutover.0a` CMK at provisioning pairs with `9.0Σ.h`
advisor_conversation_log encryption-key reference (B46 follow-on for
B29 in `phase_9_execution_backlog.md`). The CMK key ID is stored on
each row; provisioning must be live before the table receives encrypted
content.

`cutover.0b` perf-gate matrix row 8 (rollup recomputation) depends on
B38 (queued) — Tier-M load test extending `9.0Σ.k` rollups foundation.
Without B38 results, row 8 cannot clear.

`cutover.0` pre-flight no longer needs the B35 apply itself: staging and
Production1 applied `202604280000` through `202604280013` on 2026-04-29 after
explicit approval. Keep
`runbooks/phase_9_production1_migration_apply_runbook.md` as the audit trail
and template for any future Production1 mutation gate.

This plan formalizes the production cutover gate that was previously
described as "a later explicit cutover gate" without a slice number.
It is a launch operation, not feature work — it lives in its own phase
so the gates are discoverable and reusable for future cutovers
(initial beta with Vanessa, wider pilot, GA launch).

## Why This Phase Exists

Production1 (`forge-flow-production1-pg`) is provisioned with the full
schema applied through `202604250007_advisor_rls_index_hardening.sql`,
35-day backups, and built-in PgBouncer enabled — but it is intentionally
empty. No corpus, no operator data, no live traffic. That state is
deliberate: schema flexibility ends the moment real operator data lands.

Phase Production Cutover is the launch operation that:

- loads the corpus to production1
- onboards the first operator (Vanessa beta)
- captures legal acceptance (T&Cs)
- switches client traffic from staging to production
- watches stability for a defined window before declaring "live"

After this phase closes, every subsequent schema change must follow the
locked online-migration discipline. Before this phase opens, all schema
discovery from `11A`, `9.8`, `9`, `10a`, `10.5`, `9.5`, `7.58`, `11b`,
and `11b.1` has already swept up into deterministic migrations.

## Goal

Move from "production schema is correct and empty" to "Vanessa is using
the product on production, and we have evidence the system is stable."

## Non-Negotiables

- **No cutover step is irreversible without a documented rollback.**
  Every traffic switch has a documented "point back at staging" path.
- **No customer data is loaded before T&Cs acceptance is captured
  against `operator_id`.** Hard Promise #6 (advisor speaks in
  recommendations, not commands) requires the legal envelope before
  the advisor speaks to the operator.
- **All billable provider calls (Voyage, Anthropic) require explicit
  user approval before each cutover slice runs.** Cutover slices are
  multi-thousand-dollar potential spend events, not routine code work.
- **RLS isolation must be verified live on production before traffic
  switch.** Same audit query that runs on staging.
- **Cap counters must increment correctly on first production
  request.** No silent meter failures.
- **Stability watch window cannot be skipped.** Minimum 7 days before
  the cutover is declared stable.

## Sub-Slice Sequence

Order is sequential. Do not start the next slice until the prior
accepts.

### `cutover.0` Pre-flight readiness (~2-3 days)

Read-only verification slice. No live mutation.

- Verify all prerequisite phases accepted: `11A.0-6`, `9`, `9.8`,
  `11b` (against staging), plus everything else in the locked queue
  up to this point.
- Re-run all production1 smoke tests:
  - Postgres `SELECT 1`
  - AGE Cypher `MATCH` smoke
  - pgvector cosine similarity smoke
  - `/health` endpoint hits production proxy + DB and returns 200
  - RLS-leading-column audit reports 0 violations
  - `pg_partman` config + `pg_cron` job both active
- Verify Cloud Run production proxy deployment exists and routes
  to production1 (not staging).
- Verify production secrets in place: Anthropic prod key, Voyage prod
  key, Postgres prod URL, KMS access. No staging keys leaking into
  production env.
- Verify production1 firewall accepts only Cloud Run egress IPs (or
  Private Link).
- Document rollback plan: explicit DNS / env var revert path back
  to staging if cutover fails at any later slice.
- Output: `phase_production_cutover_0_preflight_result.md` with
  go / no-go verdict.

Acceptance: every check passes, rollback plan documented, user
explicitly approves moving to `cutover.1`.

### `cutover.1` Production corpus load (~3-5 days)

Live, billable. Mirror of staging load with explicit approval gates.

- Verify all `db/migrations/*` applied to production1 (already done;
  re-confirm).
- Run corpus build pipeline against production1:
  - `dart run tool/advisor_corpus/main.dart prepare-load`
  - psql apply for ingestion run, source documents, source chunks,
    graph node seeds, graph edge hints
- **APPROVAL GATE**: Voyage embedding execution against production
  (~$X estimated; surface estimate before approval).
  - Run `prepare-embeddings` then `execute-embeddings` against the
    production-target DB
  - Apply embedding updates SQL
- **APPROVAL GATE**: Anthropic Contextual Retrieval pass against
  production (~$Y estimated).
  - Generate `chunk_context` for every active chunk via
    `claude-haiku-4-5`
  - Apply context updates SQL
- Run context-enriched Voyage embedding refresh:
  - Apply refreshed `embedding_updates.sql`
- Apply AGE projection + index strategy SQL on production1.
- Apply BM25 vector population.
- Smoke tests on production1:
  - pgvector candidate query returns expected count
  - AGE Document → Chunk traversal returns expected count
  - Voyage rerank live smoke returns scored results
  - Claude answer smoke returns `end_turn`
- Verify counts match staging shape (8 docs, 233 chunks at current
  corpus size).
- Output: `phase_production_cutover_1_corpus_load_result.md` with
  execution IDs, token counts, costs incurred, smoke results.

Acceptance: all smokes pass on production1 with the same shape as
staging, costs reconcile against estimate, no secrets logged.

### `cutover.2` First operator onboarding (~1-2 days)

Uses 11A admin console — no manual SQL.

- In 11A admin console, create operator row for Vanessa on production1:
  - Operator name, contact, billing address
  - Subscription tier (per launch decision: Pilot / Starter / Premium)
  - `preferred_currency`, `business_day_rollover_hour` defaults
- Create primary location row:
  - Location name, IANA timezone, business_day_rollover_hour override
    if needed
  - `primary_location_id` set on operator
- Capture T&Cs acceptance:
  - T&Cs version (per `9.8`)
  - Acceptance timestamp
  - IP address / user agent if applicable
  - Stored against `operator_id`
- Seed `usage_caps` rows from the chosen tier template
  (`phase_11a_decision_register.md` Pricing Tier Model).
- Generate API access / client config for her advisor client.
- Verify RLS isolation:
  - Run query as her authenticated role; confirm she sees only her
    operator data.
  - Run query as her authenticated role; confirm she sees zero rows
    on any operator-scoped table outside her `operator_id`.
- Output: `phase_production_cutover_2_first_operator_onboarding_result.md`
  with operator_id, location_id, T&Cs version, tier, RLS verification
  evidence (no PII captured in the doc).

Acceptance: operator + location + caps + T&Cs acceptance all present
on production1, RLS isolation verified live, no plaintext secrets in
output.

### `cutover.3` Traffic switch (~1 day)

The actual go-live moment.

- Update Vanessa's client / beta build environment to point at the
  production proxy URL.
- End-to-end smoke from her actual client → production proxy →
  production1 DB:
  - Authenticated request succeeds
  - Cap counter increments by 1 in `usage_logs`
  - Idempotent retry returns the cached prior result
  - `/health` from her network reachable and returns 200
  - First real advisor question returns a citation-bearing answer
- Verify proxy logs show only meta-level fields by default (full
  content logging off unless feature flag opts her in).
- Document the rollback path explicitly: how to revert her client
  env from production proxy URL to staging proxy URL if needed.
- Output: `phase_production_cutover_3_traffic_switch_result.md`.

Acceptance: real traffic flows, all telemetry correct, rollback path
verified executable.

### `cutover.4` Stability watch window (~7-14 days)

Operating slice. Mostly passive monitoring.

- Daily monitoring against the 11A.6 observability dashboard:
  - Cloud Run error rate per route
  - Latency p95 / p99 per route
  - Anthropic spend rate vs forecast
  - Voyage spend rate vs forecast
  - Cap-event triggers (any operator hitting cap)
  - `pg_stat_statements` top-N queries (any unexpected slow paths)
  - User-reported issues (Vanessa's feedback channel)
- Pass criteria for declaring stable:
  - Zero unrecovered incidents during the window
  - Latency p95 within SLO across all routes
  - Total spend within forecast envelope
  - No security/RLS audit anomalies
  - No data-loss / corruption events
- Window length default: 7 days. Extend to 14 if any partial
  incident occurs.
- Output: `phase_production_cutover_4_stability_close_report.md`
  with daily-sample evidence, incidents (if any), and final
  go/no-go verdict on declaring cutover stable.

Acceptance: window closes clean against pass criteria; user
explicitly accepts the cutover as stable.

### `cutover.5` Beta widening (optional, post-launch)

Lights up only if launch decision adds more pilot operators.

- For each new operator: rerun `cutover.2` flow (11A admin onboarding,
  T&Cs, caps, RLS verification).
- Each onboarded cohort gets its own short watch window (3-5 days
  per operator) before moving the next onboarding through.
- No corpus reload required (already loaded in `cutover.1`).
- No traffic-switch slice required (production is already live).
- Output: per-operator onboarding result + per-cohort watch close.

Acceptance: per operator, same gates as `cutover.2` + a short
watch window with no incidents.

## Acceptance (Phase Close)

Phase Production Cutover closes when:

- `cutover.0-4` all accept.
- Vanessa has been operating on production for the full watch window
  with no unrecovered incidents.
- The production system passes the same smoke-test set as staging
  (pgvector, AGE, Voyage rerank, Claude answer) on real data.
- The schema-change discipline flips: from this point forward, all
  production migrations follow the locked online-migration pattern
  (no breaking changes; backwards-compatible additions only;
  partition-aware where applicable).

## Dependencies

Locked 2026-04-26 under "full proper dev before launch — no
shortcuts." Every pre-launch phase must accept before `cutover.0`
opens. No friend-beta path, no demo-mode shortcut, no split-and-defer
of compliance.

Required before `cutover.0` can open (in build order):

- `9` accepted (Firebase auth + Postgres roles + RLS enforcement live).
- `11A.0-6` accepted (admin console foundation for operator
  onboarding, pricing tier admin, corpus admin, integration management,
  debug console, observability dashboard).
- `7.58` accepted (Primary Driver audit; Hard Promise #3 gate).
- `10a` accepted (shared state v1, real-time NOTIFY -> Pub/Sub bridge).
- `10.5` accepted (live daypart shift).
- `9.5` accepted (El Podio learning identity).
- `9.75` accepted (staff daily companion, Barrio shell).
- `7.61` accepted (freshness audit; Hard Gate before Phase 8).
- `8` accepted (POS / labor transport; real operator numbers flow).
- `8R` accepted (reservation transport).
- `8.5` accepted (external integrations: QBO, Xero, Bill.com, Plaid).
- `11b` accepted (operator-facing advisor UX shipped + tested
  end-to-end on staging Azure infrastructure with real data).
- `11b.1` accepted (schema-foundation sweep — every schema discovery
  from `9` through `8.5` consolidated into deterministic migrations
  before production schema flexibility ends).
- `11b.2` accepted (AGE traversal lit up in advisor hot path).
- `12.0`, `12.1`, `12.2`, `12.3`, `12.4`, `12.5` accepted (full
  workflow platform foundation + flagship Weekly P&L + workflow
  catalog).
- `11A.7-10` accepted (admin polish: feature flag admin, API
  version management, audit log review, status page management).
- `10b` accepted (full offline sync).
- `9.8` accepted (full compliance package: T&Cs + DPAs with every
  real processor + SOC2 inheritance memo + cyber-liability insurance
  review). Lands last because every named processor must exist for
  9.8 to enumerate honestly.
- Production1 schema clean (already true today; re-verify in
  `cutover.0`).
- Anthropic + Voyage production keys provisioned in Cloud Run env / KMS.
- Cloud Run production proxy deployment exists and routes to
  production1.
- Vendor accounts provisioned for production: Anthropic, Voyage,
  Toast, 7shifts, OpenTable, QBO/Xero, Bill.com, Plaid, Firebase,
  Microsoft Azure, Google Cloud.

After this phase closes:

- Online-migration discipline kicks in for every subsequent schema
  change.
- `cutover.5` (beta widening) onboards additional pilot operators
  using the same flow as `cutover.2`.
- `12.x+` continues building out additional workflow catalog
  entries (weekly close, OT alert, schedule draft, etc.) on demand.

## Source Material

- `PROJECT_TRACKER.md` Now / Phase Board / Slice Queue
- `docs/phases/phase_11a/phase_11a_decision_register.md` —
  pricing tiers, cost levers, dormancy rules, schema discipline
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`
  — admin onboarding flow that `cutover.2` consumes
- `docs/phases/phase_9_8/phase_9_8_compliance_and_legal_plan.md` —
  T&Cs surface that `cutover.2` records acceptance against
- `docs/phases/phase_11b/phase_11b_advisor_ux_plan.md` — UX phase
  whose acceptance gates `cutover.0`
- `docs/archive/phases/phase_11a/phase_11a_production1_provisioning_result.md`
  — current production1 state baseline (archived)
- `docs/archive/phases/phase_11a/phase_11a_11e_staging_live_load_result.md`
  — staging load result that `cutover.1` mirrors against production (archived)
