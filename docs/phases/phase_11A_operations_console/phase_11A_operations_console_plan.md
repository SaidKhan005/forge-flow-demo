# Phase 11A - F&F Operations Console

Updated: 2026-05-07
Status: Active. Foundation slices `11A.0`/`1`/`2`/`3a`/`3b`/`4`/`4b`/`4c`/`5`/`6`/`7`/`UX.health` accepted. **Cross-operator parity slices ACCEPT 2026-05-06**: `11A.12` Members + Invites admin parity (`f84424db`), `11A.13` Roles + Hierarchy + Sessions admin parity (`d26425b3`), `11A.14` cross-operator audit log + audited support actions (`bbc6e134`; ships new `admin.users.reset_mfa_factors` permission key, hash-chained audit row shape). 348 admin tests PASS. Audit follow-up `45bdd734` cleared remaining drift on authority docs.
Remaining: `11A.8` (support audit), `11A.9` (cross-operator reads), `11A.10` (user impersonation) — not started; deferred post-launch unless escalated.
Owner: F&F admin / operations lane

## Phase 9 Foundation Dependencies (status as of 2026-05-03)

Active contract: `docs/contracts/proxy_health_contract.md` (live; consumed by
`11A.UX.health` and the remaining `11A.5` health/debug surface).

`11A.5` Debug Console owns the per-operator request-log surface; its Graph
debug tab is a future `11A.3.x` extension stub, not a health-producer
dashboard. `11A.6` observability is a separate bounded dashboard that links
to the Health viewer instead of duplicating `/health`; its live gateway
targets `GET /v1/admin/observability`. Producers from the 9.0Σ foundation
series:

- `audit_chain_lag_seconds` — **delivered** by B27 (`audit_logs` hash chain).
- `vector_index_size_per_corpus`, latency, recall — **delivered** by B47
  (`tool/advisor_proxy/health_producers/vector_producers.dart`;
  registry-wired; tests at
  `test/proxy/health_producers/vector_producers_test.dart`).
- `graph_node_count`, `graph_edge_count`, traversal latency — **delivered** by B44
  (graph health producer family at
  `tool/advisor_proxy/health_producers/graph_producers.dart`; nine metrics
  including p95/p99 latency, timeout rate, projection age, growth projection;
  catalog wired via `producer_registry.dart` `familyGraph`; bootstrap call at
  `tool/advisor_proxy/proxy_bootstrap.dart` line 1011; thresholds per Decision
  30 and Lock 3 perf gate; tests at
  `test/proxy/health_producers/graph_producers_test.dart`).
- `rollup_freshness_per_grain` — **delivered** by B45
  (`tool/advisor_proxy/health_producers/rollup_producers.dart`;
  registry-wired; tests at
  `test/proxy/health_producers/rollup_producers_test.dart`).
- `event_outbox_undelivered_count`, lag — delivered by B26 (Phase 10a bridge consumes).
- `usage_caps_breach_count` — delivered.

`11A.7-10` audit log review depends on B27 (delivered) + B37 (verifier E2E
test, delivered) + B43 (Cloud Run anchor deploy, **operational gate pending
Production1 GCP provisioning**).

Staging admin stabilization follow-up (2026-05-02): the repo now includes
`202605021600_phase_11A_7_feature_flags_forge_admin_grants.sql`,
`202605021700_phase_11A_health_age_graph_bootstrap.sql`,
`202605021710_phase_11A_health_age_runtime_grants.sql`, and
`202605021800_hardening_auth_login_attempts_index_rekey.sql`, plus
`202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`. These
were replayed/verified on staging and applied/verified on Production1 on
2026-05-03, so 11A health surfaces may treat AGE graph checks,
feature-flag runtime edits, auth lockout triage indexes, and pre-existing
corpus ledger visibility as schema-ready. B43 production anchoring remains a
separate runtime/cloud gate.

Debug Console live Browser Use QA on 2026-05-03 added
`202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql`
after staging proved `forge_admin` lacked explicit `SELECT` on
`proxy_requests` for read-only request-log inspection. The grant is applied
and verified on staging; it remains pending Production1 before Debug Console
request-log inspection can be called production-ready.
Until that Production1 apply and direct grant verification land, `11A.5`
request-log inspection remains staging-ready only; the admin UI/runtime work
is accepted, but the production database privilege is deliberately not marked
ready.

Staging admin live Browser Use QA on 2026-05-04 then found the same grant class
for `11A.1` operator/location admin writes: list/read routes worked, but edit
operator returned Postgres `42501 permission denied for table operators`.
`202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql` grants
the `forge_admin` DML privileges those admin-pool repositories already use. It
was applied and Browser Use verified on staging the same day: operator edit and
location edit both returned live 200s. Until the same file is applied and
directly verified on Production1, operator/location admin writes are
staging-ready only.
The Business Timing Live slice adds
`202605060000_phase_business_timing_live_schema.sql` for scoped timing profiles
and live `open_shift_snapshots`. That schema must be applied and verified in
staging/review before console timing surfaces can be called live-schema-ready,
then carried into the next Production1 apply before production claims.
Phase 11A.14 adds
`202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql`, an additive
permission-key seed for the new `admin.users.reset_mfa_factors` key plus
default grants for `super_admin`/`ff_support`; apply on staging before
exercising the Reset-MFA admin path live, then carry into the next
Production1 apply.
The 2026-05-06 audit follow-up adds two additional migrations watched by this
plan's cutoff sentinel:
`202605061500_hardening_phase_8_email_index_leading_column_rekey.sql`
CONCURRENTLY-rekeys five Phase 8 / Phase 9.8 fact-table indexes to lead with
`operator_id` (preserves UNIQUE constraints + partial WHERE clauses), and
`202605061600_phase_11W_5_team_audit_log_export_key.sql` seeds the
`team.audit_log.export` permission key plus default grants for
`operator_owner`/`operator_admin` so the 11W.5 audit-log export gate has
catalog parity. Apply both on staging before claiming index hygiene parity or
live audit-log export readiness, then carry into the next Production1 apply.
The Hardening Wave B3 audit-anchor cron follow-up (punchlist §5) adds
`202605061700_hardening_audit_anchor_daily_schedule.sql` (additive pg_cron
registration for `forge_audit_anchor_daily` at `0 2 * * *` UTC; the kickoff
function `public.audit_anchor_run_daily()` is NOTIFY-only on channel
`audit_anchor_tick` and does NOT perform the anchor work — the Cloud Run
binary at `tool/audit_anchor/main.dart` remains the production executor that
B43 tracks). The migration is replay-safe via unschedule-then-reschedule and
NOTICE-and-return guarded for the Azure pg_cron split-DB case. Apply on
staging before claiming daily-cadence-from-Postgres observability parity for
the 11A audit-log review surfaces, then carry into the next Production1
apply.
Phase 8 timing provenance also adds
`202605061700_phase_8_timing_provenance_shift_records.sql`; it is not an 11A
surface, but it moves the shared Production1 follow-up cutoff watched by this
plan. Hardening Wave B1 also queues
`202605061701_phase_8_data_accuracy_service_period_settings.sql`, an additive
keyed Data Accuracy child table per
`(operator_id, location_id, service_period_key, effective_at_business_date)`
that replaces the hardcoded `covers_source_lunch`/`_dinner`/`_late_night`
columns; it is not an 11A surface either, but it moves the shared cutoff
again. Originally added under the `202605061700_…` basename (commit
`4655b484`); renumbered on 2026-05-06 to break the same-second prefix
collision with the audit-anchor + timing-provenance migrations. Phase 8
mobile core then added
`202605061800_phase_8_first_connection_backfill_jobs.sql`, an additive
server-side queue/claim seam for first-connection backfill jobs; it is not
an 11A surface but it moved the shared cutoff. Phase 11W.7 / Wave A2 then
queues `202605070000_phase_11W_7_operator_account_fields.sql`, which adds
the editable business-identity columns the operator-web `PATCH
/v1/operator/account` route writes (`logo_url`, `locale_tag`,
`week_start_day`, `rollover_hour`) plus format CHECK constraints and a
`business_name` length CHECK. Additive + default-backed; RLS on
`public.operators` is unchanged. That migration is not an 11A surface
either, but it moves the shared cutoff watched by this plan. Code Health M2
then queues `202605070100_password_history_salt_pepper.sql`, and Code Health
M3 queues `202605070200_audit_anchor_advisory_lock_infra.sql`; they are not
11A surfaces, but they move the shared cutoff watched by this plan. Phase 8
timing-provenance FK posture then queues
`202605080000_phase_8_timing_provenance_fk_posture.sql`; it is not an 11A
surface, but it preserves closed timing truth under profile deletion and
moves the shared cutoff. Code Health M1 then queues
`202605080100_admin_idempotency_expires_at.sql` for admin idempotency TTL
cleanup. Phase 8 weekly-plan server truth then queues
`202605080100_phase_8_weekly_plan_server_truth.sql`; it is not an 11A
surface, but it adds server-owned forecast contexts and weekly plan snapshots
and moves the shared cutoff. Phase 8 wage-role row server truth then queues
`202605080200_phase_8_wage_role_rows_server_truth.sql`; it is not an 11A
surface, but it adds the server-owned wage mix / role-job-code mapping table
that mobile mirrors as cache. Phase 8 data-accuracy walk-in settings then
queues `202605080300_phase_8_data_accuracy_walk_in_settings.sql`; it is not an
11A surface, but it adds server-owned reservation-demand walk-in fields that
mobile mirrors as cache. Phase 8 connector OAuth state then queues
`202605080400_phase_8_connector_oauth_state.sql`; it is not an 11A surface,
but it adds tenant-scoped state for operator-facing vendor OAuth
begin/callback flows. A1 idempotency rekey then queues
`202605080600_phase_8_idempotency_location_id_rekey.sql`; it is not an 11A
surface, but it adds `location_id` to the fact/webhook idempotency keys and
the shared migration cutoff now continues through
`202605081000_outbox_notify_channel_split.sql`.
Normal timing edits belong in the Operator Web Console. The F&F Operations
Console may expose the same effective profile for support and may write
overrides only through `/v1/admin/*` routes with a required audited admin
reason; it must not become the operator's primary hierarchy editor.

Mobile push notification work on 2026-05-06 adds
`202605060000_mobile_push_notifications.sql` for encrypted FCM/APNs token
storage and a durable mobile push sidecar queue. This is not an 11A UI surface,
but it updates the shared migration cutoff watched by this plan. It remains
staging/prod apply gated until the branch is deployed to staging and the
connected-device popup proof passes.

Operational runbooks added from the 2026-05-03 live staging console smoke:
provider credential/KMS rollout is owned by
`runbooks/admin_provider_credentials_kms_rollout_runbook.md`, and local
browser QA should use the static-build path in
`runbooks/admin_console_browser_qa_runbook.md` when the Flutter debug
web-server fails to bootstrap in the in-app browser. The same smoke also
confirmed Corpus -> Graph candidates must ship sanitized
`tool/advisor_proxy/graphify_candidates/candidates/*` artifacts in the proxy
image; this branch copies them to `/app/graphify-out/candidates`, which is the
path `RepositoryGraphCandidatesProxyGateway` reads in Cloud Run. The Health red
`audit_chain_lag_seconds` item is not future 11A UI wiring; it is the B43 audit
anchor ops-data gate. After action-time approval, staging execution
`forge-flow-audit-anchor-zmsvj` anchored the 2026-05-02 chain and turned that
metric green; Production1 anchoring remains the separate B43 production gate
until the production project is provisioned and exercised.

**2026-04-26 — Postgres host re-locked to Azure DB Flexible Server (Canada Central, PG 16).** Throughout this plan, "Supabase database" reads as "Azure Database for PostgreSQL Flexible Server". `11A.4` Integration management now manages Azure DB connection strings (in addition to Anthropic / Voyage keys) instead of Supabase project keys. `11A.6` Observability dashboard reads health + metrics from Azure Monitor (Postgres metrics) + Cloud Run + Anthropic / Voyage usage instead of Supabase + Cloud Run. Trigger: see `phase_9_auth_plan.md` 2026-04-26 banner.

> Naming note: capital `A` distinguishes this phase (`11A`, the F&F
> internal admin console) from `11a` (advisor infrastructure). They
> are separate surfaces with separate audiences. References elsewhere
> in the repo should use the capital-A form for this phase to avoid
> ambiguity.

## Why This Exists

`11a.11c-e` lights up the cloud infrastructure (Azure DB Flexible
Server, proxy backend, corpus). At that point, F&F has a working
back-end stack
but no human-facing way to operate it. Onboarding a new operator
means writing SQL by hand. Editing pricing means redeploying.
Debugging a customer complaint means grep-ing Cloud Run logs.
Rotating an API key means reaching into Cloud Run env vars.

Phase 11A is the F&F internal admin product that fixes this.
Web-hosted, desktop-accessible, brand-styled, lets the founder
(and eventually F&F support staff) manage operators, locations,
pricing, corpus, integrations, debugging, observability, feature
flags, and audit logs from any browser without on-premise tooling.

## Audience and Boundary

- **Audience.** F&F super-admin (Vanessa). Eventually F&F support
  staff with operator-scoped read access.
- **Boundary.** Phase 11A is **not** the operator-facing app. It
  does not own operator UX. It does not surface to operators ever.
  It is the internal back-office.
- **Auth.** Firebase Authentication admin tokens. Admin role gate
  on every `/v1/admin/*` route the proxy serves. RLS policies on
  every operator-scoped table apply same as anywhere else; admin
  role is the only role that bypasses with explicit
  `service_role` for cross-operator queries (Postgres
  `BYPASSRLS` granted only to the admin path).

## Tech Stack

**Flutter for Web.** Decided 2026-04-25. Reasons:

- Reuses the existing brand from `lib/theme/app_theme.dart`
  (Sunset / Peacock palette, Playfair Display + IBM Plex
  typography). Compiles for web identically.
- Single Dart codebase across mobile (operator app) and
  web/desktop (admin console). No new language, no new
  framework, no new hire profile to support.
- Flutter desktop targets Windows / Mac / Linux natively from
  the same codebase. Covers the desktop-access requirement
  without separate Electron / Tauri builds.
- Migration path exists: if Phase 11A outgrows Flutter for Web
  performance at very-heavy DOM scale, the proxy `/v1/admin/*`
  API contract is framework-agnostic; a React / Next.js client
  can replace the Flutter Web client without backend changes.

Hosting: separate Cloud Run service from the proxy backend, at
`admin.forgeflow.app` (or similar). The current admin service serves
static Flutter Web assets and calls the advisor proxy from the browser;
it does not open a server-side Azure connection. Azure DB cost is shared
with the proxy. ~$0-15/month at idle (Cloud Run admin service).

Staging runtime snapshot (2026-05-03): admin console is deployed as
`forge-flow-admin-console` in `forge-flow-staging` /
`northamerica-northeast2`, revision `forge-flow-admin-console-00004-6xw`,
using `forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com`.
Production1 has no admin-console Cloud Run service yet; deploy it only after
the production proxy base URI is live and documented in the cutover baseline.

## Goal

Ship the F&F Operations Console that handles every internal
operations task without shell access, manual SQL, or redeploys.
Specifically:

- Onboard new operators in seconds via a form (vs SQL INSERT)
- Edit pricing per `(operator_id, location_id, usage_class)`
- Drag-and-drop markdown corpus updates from desktop
- Debug specific operator complaints via per-operator request
  log viewer (meta by default, full content per opt-in)
- See system health at a glance (Postgres, AGE, pgvector, Cloud
  Run, latency, error rate, cost-by-operator)
- Rotate Anthropic / Voyage API keys without an engineer
- Toggle feature flags per operator
- Manage status page incidents

## Sub-Slice Sequence

### Foundation (launch-blocking before 11b)

- `11A.0` **accepted** (commit `0ca800c`) — Flutter for Web project
  bootstrap. Brand styling shared with operator app via the same
  `app_theme.dart`. Route shell. Firebase admin auth gate
  (`FirebaseAdminAuthSource` in production; demo source under
  `-DemoMode`). Deploys to a separate Cloud Run service. Six placeholder
  routes (Operators, Pricing, Corpus, Integrations, Debug,
  Observability). Walkthrough: `docs/_walkthroughs/11A.0.md`.
- `11A.1` **accepted** (commit `d66e3c3`) — Operator + location
  management. CRUD on `operators`, `locations`, `users`,
  `operator_admins`. Onboard new operator (creates rows, assigns
  subscription tier, sets `preferred_currency`, sets
  `primary_location_id`). Edit existing. Suspend / reactivate. Add /
  remove locations per operator. Set per-location `timezone` (IANA
  picker) and `business_day_rollover_hour`. Replaces "manual SQL
  INSERT" as the new-operator onboarding path. Migration
  `202604290100` (`operators.suspended_at`). New-operator admin
  identity goes through the Phase 9 auth gateway (Firebase user +
  custom claims + `users` + `user_roles` + invite + audit), then
  attaches `operator_admins` with `scope_type = 'operator_owner'`.
  Walkthrough: `docs/_walkthroughs/11A.1.md`.
- `11A.2` **accepted** (commit `934fc69`) — Pricing tier admin.
  Table editor for `usage_caps` per
  `(operator_id, location_id, staff_id NULL, workflow_id NULL,
  usage_class)` (Hard Promise #9 metering axes). All 6 templates
  (Pilot/Starter/Premium/Elite/Pro/Enterprise) per
  `phase_11a_decision_register.md` Pricing Tier Model. Split
  read/write role gates: `kFfPricingAdminReadRoles` (super_admin +
  ff_support) for `GET`; `kFfPricingAdminWriteRoles` (super_admin only)
  for mutations. `applyTierTemplate` validates all preconditions before
  any write. UPSERT honors `usage_caps_two_slot_uq` (UNIQUE NULLS NOT
  DISTINCT) on the post-9.0Σ.g schema with billing-owner + scoped
  org-unit axes. Walkthrough: `docs/_walkthroughs/11A.2.md`.
- `11A.3` **Corpus admin.** Drag-and-drop markdown upload.
  Per-chunk preview before commit. Diff view (what's new, what's
  changing, what's being inactivated). Rollback to prior corpus
  version. **Replaces the earlier `11a.12` cloud enablement
  scope** (same pipeline, better surface). Pipeline integrates
  with the corpus build tool (`tool/advisor_corpus/`) and
  enforces resumability + Voyage rate-limit backoff per
  `11a.11e` acceptance.

### `11A.3.x` Graphify-Assisted Corpus Graph Review

**Status (2026-05-07):** scaffolding shipped (proxy routes + admin UI +
importer plumbing + typed 503s); the operator-side **candidate bundle
staging** step is paused under the AI freeze per `PROJECT_TRACKER.md`
"Paused". Without a hand-staged bundle in
`tool/advisor_proxy/graphify_candidates/candidates/`, the proxy
deliberately returns `graph_candidates_not_configured` /
`graph_candidates_unavailable` 503s with a paused-by-design message.
First task on AI unpause: stand up the candidate-bundle staging path
(deploy automation + initial Graphify run) so the routes exit the 503
wall and the admin review surface lights up. See
`docs/archive/CODE_OPS_DEBT_FINAL_2026-05-08.md` Theme J#5 for the
closeout note.

This is the phase slice where the open-source Graphify repo can feed the
Forge & Flow advisor graph. It is an admin/review feature, not runtime
AI behavior.

Graphify's job is to propose relationships from corpus content. The F&F
admin's job is to approve, reject, or edit those relationships before
they become advisor truth. Approved records are written into the existing
Postgres graph layer; unapproved suggestions never reach the advisor.

Implementation flow:

1. Run Graphify against the advisor corpus source set.
2. Import Graphify's `graph.json` as draft graph candidates.
3. Normalize every candidate into the F&F graph vocabulary.
4. Show the candidate diff in Corpus Admin:
   - new nodes
   - changed nodes
   - new relationships
   - changed relationships
   - removed relationships
   - inferred or ambiguous relationships requiring explicit review
5. Admin approves, rejects, or edits candidates.
6. Approved records become `graph_nodes` / `graph_edges` rows.
7. AGE projection rebuild consumes `graph_nodes` / `graph_edges`.
8. `11b.2` advisor traversal can use the approved graph.

Local implementation details:

- Add a build-tool command under `tool/advisor_corpus/main.dart`, named
  `prepare-graphify-candidates`.
- Add a Dart importer in `tool/advisor_corpus/advisor_corpus.dart` that
  reads Graphify `graph.json` and emits deterministic JSONL artifacts:
  `graphify_node_candidates.jsonl`,
  `graphify_edge_candidates.jsonl`, and
  `graphify_candidate_manifest.json`.
- The importer must not write live database rows directly. It produces
  review artifacts first, matching the existing `prepare-load` pattern.
- The advisor proxy image must copy the sanitized candidate bundle from
  `tool/advisor_proxy/graphify_candidates` to `/app/graphify-out`. Missing
  artifacts still return the typed `graph_candidates_not_configured` 503, but
  staging should not depend on a local workstation `graphify-out/` directory.
- The Flutter admin client must never shell out to Graphify. The admin
  UI calls a proxy admin route, and the proxy/server-side job invokes the
  build tool.
- `docs/Knowledge_graph_docs/corpus_manifest.yaml` remains the
  authority for which corpus docs are in scope. Graphify output for
  files outside the active manifest is ignored.
- Use canonical graph storage as the destination:
  `public.graph_nodes` and `public.graph_edges`. The older
  `advisor_graph_node_seeds` / `advisor_graph_edge_hints` path remains
  a corpus-load/projection input, not the long-term source of truth.

Graphify repo details to adapt:

- `graphify/detect.py`: take the changed-file detection and ignore
  discipline. Adapt it to the corpus manifest instead of using the repo
  filesystem as the authority.
- `graphify/cache.py`: take the incremental-cache idea so unchanged
  corpus documents do not trigger full graph regeneration.
- `graphify/extract.py`: take the node/edge extraction shape:
  stable ids, labels, relation names, source file references, and source
  locations. Do not copy code that depends on a developer-only Claude
  Code session into production.
- `graphify/validate.py`: take the schema-validation posture. Every
  imported candidate must validate before it appears in the admin review
  screen.
- `graphify/security.py`: take the path/URL safety posture before any
  future external `graphify add <url>` style ingestion is allowed.
- `graphify/serve.py`: take the query primitives as inspiration for
  debug tooling (`get_node`, `get_neighbors`, graph stats, shortest
  path). Production runtime queries still go through Postgres/AGE.
- `graphify/build.py`, `graphify/cluster.py`, and `graphify/analyze.py`:
  take the build/report structure for admin summaries such as connected
  components, central nodes, isolated nodes, and surprising edges.

Candidate mapping rules:

- Graphify node id -> `graph_nodes.node_key`, prefixed with
  `graphify:` and scoped by source doc/version so ids are stable across
  re-runs.
- Graphify node label -> `graph_nodes.properties.label`.
- Graphify node type -> `graph_nodes.node_type`, normalized to the F&F
  approved type list before commit.
- Graphify edge source/target -> lookup by candidate node key, then
  write `graph_edges.from_node_id` / `graph_edges.to_node_id`.
- Graphify relation -> `graph_edges.edge_type`, normalized to the F&F
  approved relation list.
- Graphify confidence -> `graph_nodes.confidence` /
  `graph_edges.confidence` as numeric 0.000-1.000.
- Graphify source path/location -> `source = 'graphify'`,
  `source_ref`, and JSONB provenance fields.
- Graphify community/cluster ids -> JSONB properties only. They help
  review but are not semantic truth.

Approval rules:

- `EXTRACTED` relationships can be batch-approved only after a diff
  preview.
- `INFERRED` relationships require explicit per-edge approval.
- `AMBIGUOUS` relationships are debug-only until edited into a clear
  approved relationship.
- Rejected candidates stay in the review manifest for audit but are not
  written to `graph_nodes` / `graph_edges`.
- Every approved candidate records the admin actor, approval timestamp,
  source document, source line/span when available, Graphify version,
  and Graphify source commit or package version.

License and source rules:

- Graphify is MIT licensed. Any copied helper code must keep an MIT
  attribution comment and a source URL in the file header.
- Prefer a bridge/importer over vendoring the full package. The F&F app
  owns persistence, tenant isolation, approval workflow, and runtime
  traversal.
- Do not ship `graphify-out/graph.json` itself as production truth.
  It is an input artifact only. Commit only the sanitized JSONL candidate
  bundle and manifest; raw Graphify cache/source conversions stay ignored.

Acceptance:

- Corpus Admin shows a graph candidate diff before commit.
- Admin can approve, reject, and edit relationship candidates.
- Approved candidates write to canonical `graph_nodes` / `graph_edges`
  only through the proxy/admin backend path.
- AGE rebuild reads canonical rows and passes smoke traversal.
- Ambiguous and inferred edges cannot silently reach advisor runtime.
- `prepare-graphify-candidates` is deterministic for the same
  `graph.json`, manifest, and corpus version.
- Tests cover import validation, confidence handling, rejected
  candidates, source provenance, and manifest-out-of-scope filtering.

### Operations readiness (launch-blocking, lands alongside 11b)

- `11A.4` **Integration management.** View and rotate Anthropic
  and Voyage API keys (writes to Cloud Run env / KMS via admin
  API; never displays plaintext after creation). Vendor
  connector status placeholder (lights up when Phase 8 lands).
  FX-rate source status. Email provider status (when 9.8 lands).
- `11A.5` **Debug console.** *Status (2026-05-03): accepted in worktree `claude/nifty-colden-5621fa`; walkthrough `docs/_walkthroughs/11A.5.md`.* Per-operator request log viewer.
  Filter by operator / location / usage_class / time-window /
  status. View request meta by default; toggle full content per
  operator (per `feature_flags` opt-in row). Search by
  `request_id` or `idempotency_key`. Live-tail latest requests
  for the active session. **This is the "remote debug" surface**
  - accessible from any browser, no shell access required.
  Implementation adds `RequestLogEntry`/filter/opt-in models,
  `DebugConsoleAdminGateway` with HTTP and in-memory demo
  implementations, the live `/debug` admin route binding, and
  `lib/main_admin.dart` wiring so live builds use the proxy-backed
  `/v1/admin/debug/*` gateway instead of demo fixtures. Runtime posture:
  cheap initial render, opt-in live-tail, no stacked tail requests, and
  bounded list growth back to `kDebugConsoleListLimit`.
  Graph debug extends this surface for `11A.3.x`: inspect a graph
  node, inspect neighbors, inspect shortest approved path between
  two approved nodes, and see whether an edge was extracted,
  inferred-and-approved, edited, or rejected.
  Auth/MFA support diagnostics extend this surface after Phase 9
  `9.UX.1a`: view user MFA factor inventory, pending/cancelled removal
  requests, notification/outbox status, and Firebase/local drift
  flags. Full repair actions consume Phase 9 safe backend routes;
  the admin client must not perform direct DB/Firebase writes.
- `11A.6` **Observability dashboard.** *Status (2026-05-03): accepted —
  walkthrough `docs/_walkthroughs/11A.6.md`. The former scaffold route is replaced
  by a read-only `/observability` binding in `lib/admin/admin_routes.dart`.
  Production `lib/main_admin.dart` wires `HttpObservabilityAdminGateway` to
  bearer-token `GET /v1/admin/observability` with a 60s timeout and typed
  errors; demo mode uses the seeded in-memory envelope. The surface is
  manual-confirmed, has no auto-polling, prevents stacked in-flight requests,
  and keeps the Health envelope viewer separate and untouched.* Accepted
  dashboard coverage includes latency p95 / p99 charts, route error summaries,
  cap-event stream (incoming alerts when operators hit cap), Cloud Run instance
  counts, approved/inferred-approved/rejected/isolated graph counts, AGE
  projection freshness, and traversal p95.

  **Accepted cost telemetry surfaces** (Hard Promise #9 visibility; bounded by
  `kObservabilityCostTelemetryLimit = 100`, scoped with optional `query_class`
  filtering, and rendered through a fixed-height virtualized list):
  - Total cost-by-(`operator_id` / `location_id` / `staff_id` /
    `workflow_id` / `usage_class`)
  - Cost-by-`query_class` (advisor_qa / coach_qa / wf_pl /
    wf_schedule / etc.) — drives pricing-tier decisions
  - Cache hit rate per `query_class` (lever 3 effectiveness)
  - Model mix per `query_class` (Haiku vs Sonnet share — lever 2
    effectiveness)
  - Batch-mode share for async workloads (lever 5 effectiveness)
  - Top-N most-expensive operators / staff / workflows over
    rolling windows (1d / 7d / 30d)
  - Operator dormancy state (last_active_at relative to now;
    flag operators 30+ days silent for precompute skip)
  - Per-tier margin estimate (revenue from `subscription_tier`
    minus rolling cost = margin per operator)

### Polish (post-launch; can interleave with 11b.2 / 10b)

- `11A.7` **Feature flag admin.** *Status (2026-05-02): ✅ accepted (PR #41).* Edit `feature_flags` rows from
  the UX (toggle Q12 retrieval-mode, toggle streaming when it
  lands, gate Phase 12 workflows per pilot operator, etc.).
- `11A.8` **API version management.** *Status (2026-05-02): not started.* See what % of operator
  clients are on `/v1/` vs `/v2/`. Schedule deprecation
  announcements. View force-update conditions when needed.
- `11A.9` **Audit log review.** *Status (2026-05-02): not started; depends on B43 Production1 anchor deploy.* Who changed what when across
  `usage_caps`, `feature_flags`, `operators`, key rotations.
  MFA revocation initiated/pending/completed and recovery-requested
  events are included. Powered by `created_by` / `updated_by` columns;
  the UX makes the audit queryable.
- `11A.10` **Status page management.** *Status (2026-05-02): not started.* Create incidents, write
  post-mortems, sync to public `status.forgeflow.app` page.
- `11A.11` (optional) **Replay tool.** *Status (2026-05-02): not started.* Pick a past request,
  re-run it against current corpus + model, compare to original
  answer. Lights up if a real customer dispute ever surfaces.

### Cross-operator parity (un-deferred 2026-05-05; ships in lockstep with `11W.1`–`11W.6`)

Phase 11W gives operators desktop self-service for their own data via `11W.1`–`11W.6` (Members / Roles / Hierarchy / Sessions / Audit / Security). F&F support staff need cross-operator inspect + audited edit views over the same data so support escalations don't require shell access. The slice family lands in lockstep with the operator-side parity block per `project_role_hierarchy_web_migration_sequencing.md`. Both sides bind to the parity contract `docs/contracts/team_roles_hierarchy_console_parity_contract.md`.

#### `11A.12` Members + Invites parity (cross-operator)

Cross-operator member view + invite admin. F&F super-admin / `ff_support` selects an operator via the existing operator picker (`lib/admin/screens/operator_picker_screen.dart`); the screen lists that operator's users with the same filter set as `11W.1` Members and exposes the same row actions plus support-only actions (`Restore soft-deleted`, `Override role grant`). All writes flow through `/v1/admin/auth/users` + `/v1/admin/auth/invites` + `/v1/admin/auth/role-grants` (admin path; gates on `admin.users.*` + `admin.invites.*` + `admin.roles.*`). Every write writes the calling F&F admin's UID into `created_by` / `updated_by` and the operator's audit log via `audit_logs` (B27 hash-chained). RLS-bypass via `forge_admin` Postgres role; no operator `team.*` keys inspected.

Files this slice owns: `lib/admin/services/members_admin_gateway.dart`, `lib/admin/screens/members_admin_screen.dart`, `lib/admin/screens/invite_member_admin_dialog.dart`, route entry in `lib/admin/admin_routes.dart`, gateway resolver in `lib/main_admin.dart`. Walkthrough at acceptance: sign in to admin console as `super.admin@forgeflow.test` → pick a fixture operator → land on Members → filter by `mfa_enrolled=false` → invite a fixture user → restore a soft-deleted user → screenshot trace per `docs/_walkthroughs/11A.5.md` bar.

#### `11A.13` Roles + Hierarchy + Sessions inspect (cross-operator)

Cross-operator inspect for role catalog + org hierarchy + active sessions. After operator-picker, the screen renders three tabs: `Roles` (seeded + custom roles for that operator, view-only by default; edit gated on `admin.roles.edit_seeded` for seeded roles, `admin.roles.create_custom` / `delete_custom` for custom roles); `Hierarchy` (org tree + locations, read-mostly with audited edit gated on `admin.users.create` analog for hierarchy mutations — note `11A.1` already covers location admin edits; this slice adds the org-unit tree visualization and audited move actions); `Sessions` (every active session for every user in the operator, with cross-actor force-logout gated on `admin.session.force_logout`). Reads through `/v1/admin/auth/roles?operator_id=...` + `/v1/admin/auth/org-units?operator_id=...` + `/v1/admin/auth/sessions?operator_id=...`; writes via the same admin path. Every write audits with the F&F admin's UID + a mandatory `admin_reason` text field (free-form, audited).

Files this slice owns: `lib/admin/services/roles_hierarchy_sessions_admin_gateway.dart`, `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart`, route entry. Walkthrough at acceptance: sign in to admin console → pick a fixture operator → tab through Roles / Hierarchy / Sessions → force-logout a fixture session with `admin_reason="walkthrough verification"` → screenshot trace.

#### `11A.14` Audited support actions

Cross-operator audit log review + support-side MFA / password operations + hierarchy-touches-grants escalations. After operator-picker, the screen renders the operator's audit log (filters identical to `11W.5` Audit Log; export gated on `admin.audit_log.export`), plus an `Actions` panel with: `Reset member MFA` (gated on a future `admin.users.reset_mfa_factors` key — must be added to the catalog as part of this slice via additive migration), `Initiate password reset` (gated on `admin.users.reset_password`), `Issue paired-approval erasure` (gated on `admin.users.erase_pii`, MFA-required, paired-approval workflow). Every action requires a free-form `admin_reason` and writes both `audit_logs` + an `admin_action_log` provenance row capturing reader / target / records-touched.

Files this slice owns: `lib/admin/services/audited_support_actions_admin_gateway.dart`, `lib/admin/screens/audited_support_actions_admin_screen.dart`, route entry, plus the additive migration `db/migrations/<timestamp>_phase_11A_14_admin_users_reset_mfa_factors_key.sql` and the corresponding `lib/auth/permission_keys.dart` + `docs/contracts/auth_permission_key_catalog.md` updates per the catalog keep-in-sync rule. Walkthrough at acceptance: sign in to admin console → pick a fixture operator → review audit log → reset a fixture member's MFA with `admin_reason="walkthrough verification"` → confirm audit row appears with the F&F admin's UID + the reason → screenshot trace.

## Sequencing in the Build Cadence

Updated locked sequence 2026-04-25:

```text
[7.57] -> 11a.11c -> 11a.11d -> 11a.11e ->
[11A.0 -> 11A.1 -> 11A.2 -> 11A.3 -> 11A.4 -> 11A.5 -> 11A.6] ->
9.8 -> 9 -> 10a -> 10.5 -> 9.5 ->
[7.58] -> 11b -> 9.75 -> 11b.2 ->
[11A.7 -> 11A.8 -> 11A.9 -> 11A.10 (interleave with above)] ->
10b -> [7.61] -> 8 -> 8R
```

Reasoning:
- `11A.0-6` ship before any operator-facing launch (ops
  readiness)
- `11A.7-10` are post-11b polish (admin works without them at
  MVP; they make admin good)
- The operator-facing `11b` advisor still ships when planned;
  `11A` runs alongside, not in front of, `11b`'s critical path

## Scope Does Not Own

Phase 11A does not own:

- the operator-facing Forge & Flow app (`lib/main_forgeflow.dart`)
- the operator-facing Barrio app (`lib/main_barrio.dart`)
- the proxy backend itself (that's `11a.10`); this phase consumes
  proxy admin routes
- corpus pipeline internals (those are `7.57.3b` / `11a.11e`); this
  phase consumes the pipeline as a service
- Phase 12 workflow automation runtime; that's a future phase
- public status page authoring (a free service handles authoring;
  `11A.10` is the F&F-side incident-creation UX)

## Frontend Exposure

Phase 11A IS the admin frontend (Flutter for Web at
`admin.forgeflow.app`). The Sub-Slice Sequence above already enumerates
the admin surfaces; this section makes the operator-vs-admin split
explicit per Hard Promise #10.

**Admin (11A) surfaces this phase ships:** see `11A.0` through
`11A.10` above. Each sub-slice IS a UX surface:

- `11A.0` shell + auth gate
- `11A.1` operator + location management
- `11A.2` pricing tier admin + usage-cap editor
- `11A.3` corpus management (upload, diff, Graphify-assisted review)
- `11A.4` integration management (consumed by Phase 8 / 8R / 8.5)
- `11A.5` debug console request log (meta-by-default, full-content
  reveal gated by role and operator opt-in, live-tail bounded)
- `11A.6` observability dashboard (accepted; walkthrough `docs/_walkthroughs/11A.6.md`)
- `11A.7` feature flag admin
- `11A.8` API version management
- `11A.9` audit log review (consumes B27 / B37)
- `11A.10` status page management
- `11A.12` Members + Invites parity (cross-operator) — un-deferred 2026-05-05
- `11A.13` Roles + Hierarchy + Sessions inspect (cross-operator) — un-deferred 2026-05-05
- `11A.14` Audited support actions (audit log review + MFA reset + password reset + paired-approval erasure) — un-deferred 2026-05-05

**Operator-facing surfaces this phase requires:** **none**. By
design, 11A never surfaces to operators. Cross-checks: any operator-
visible feature must NOT live under `admin.forgeflow.app` or
`/v1/admin/*`; those surfaces are F&F super-admin only. Operator-side
self-service for the same operator-managed data lives in Phase 11W
(Operator Web Console) with peer backend routes (`/v1/auth/*` for
operator self-service vs `/v1/admin/auth/*` for F&F admin) and a
different host shell, operator-scope only. The cross-operator parity
slice family (`11A.12`, `11A.13`, `11A.14`) is un-deferred (2026-05-05)
and ships in lockstep with `11W.1`–`11W.6` after Phase 7 + Phase 10
close. Both sides bind to the parity contract
`docs/contracts/team_roles_hierarchy_console_parity_contract.md`.

**UX sub-slice family:** owned inline by existing `11A.x` slices —
each `11A.x` IS a UX surface. Each slice adds the `Operator
walkthrough` block (here it's an "Admin walkthrough" — same gate,
different audience) + walkthrough acceptance criterion.

**Admin walkthrough (per slice):** sign in to
`admin.forgeflow.app` → exercise the new admin surface end-to-end
against staging proxy + staging DB → verify RLS bypass works for
admin role, RLS enforcement works for non-admin → screenshot or
text trace.

Walkthrough evidence required at slice acceptance per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Dependencies

Required before Phase 11A can ship real:

- `11a.11c-e` complete (Azure DB Flexible Server live with AGE +
  pgvector + pg_diskann verified, proxy enforcement, corpus loaded)
- Firebase Authentication admin role configured
- Cloud Run service slot reserved for `admin.forgeflow.app`
- Brand assets in `lib/theme/` (already exist)

## Dev UX prerequisite — cross-cloud egress

Any new Cloud Run service in `forge-flow-staging` (or its eventual
production GCP project) that needs to reach Azure-hosted resources
(Postgres, Blob Storage, Key Vault) MUST be deployed with a static
egress IP that's allowlisted on the corresponding Azure firewall.
The default Cloud Run egress is a rotating pool of Google IPs and
will be silently rejected.

**The plumbing already exists in `forge-flow-staging` — reuse it,
do NOT re-create it:**

- VPC connector: `ff-staging-proxy-egress` (`10.8.0.0/28` on `default` network)
- NAT router: `ff-staging-nat-router` (region `northamerica-northeast2`)
- Reserved egress IP: `34.130.85.86` (`ff-staging-proxy-egress-ip`)
- Azure Postgres firewall rule: `AllowGcpCloudRunStaticEgress`
  on `forge-flow-staging-pg` (covers exactly `34.130.85.86`)

Deploy any new Cloud Run service or Job with these two flags:

```
--vpc-connector ff-staging-proxy-egress
--vpc-egress all-traffic
```

Both `forge-flow-staging-proxy` (Phase 11a.10) and
`forge-flow-audit-anchor` (Phase 9.0Σ.f) already use this connector;
the throughput envelope (200–300) is fine for an admin Cloud Run
service with bursty operator traffic.

`scripts/deploy_admin_console.ps1` intentionally omits static-egress flags today
because it only serves static web assets; all admin data access goes through
the browser to the proxy URL compiled into `ADMIN_PROXY_BASE_URI`. If a future
admin service adds server-side calls to Azure-hosted resources, its deploy
script must add the same static-egress flags before that release.

This same prerequisite applies to a future production GCP project:
that project will need its own VPC connector + NAT + reserved IP +
matching Azure firewall rule before any Cloud Run service in it
can talk to production Azure.

## Production Firebase Gap

The repo currently carries only staging Firebase client configuration:
`.firebaserc` has `default`/`staging` aliases for `forge-flow-staging`;
`web/firebase-config.js`, both Android `google-services.json` files, both
iOS `GoogleService-Info-*.plist` files, and `lib/main_admin.dart` point at
`forge-flow-staging`. Production setup must create a separate Firebase/GCP
project and add production client config/flavors before any production admin
console or operator app build is considered live. Until that lands, the
current admin console can be used for staging only.

## Non-Negotiables

- All admin actions go through the proxy backend's `/v1/admin/*`
  API. Direct database access from the admin client is forbidden;
  same repository pattern + RLS as elsewhere.
- Audit columns (`created_by`, `updated_by`) populated on every
  admin write. The UX always shows who changed what when.
- No plaintext API keys ever displayed after rotation. The UX
  shows masked values; only the operator who created the key
  sees it once at creation time.
- Per-operator opt-in required to enable full-content request
  logging; UX must surface the privacy implication when a
  super-admin toggles it on.
- Brand styling identical to operator app; same `AppColors` and
  text styles. The admin product feels like the same product.

## Adjacent Phases

- `Phase 11a` lights up the Azure DB Flexible Server + proxy +
  corpus that 11A manages
- `Phase 9` issues admin auth tokens
- `Phase 9` owns operator-facing MFA enrollment/removal. Phase 11A owns
  support-only MFA diagnostics and repair surfaces once safe backend
  routes exist.
- `Phase 9.8` provides the legal/compliance surfaces (T&Cs editor
  may live in 11A.10 or a 9.8 sub-slice)
- `Phase 11b` ships the operator-facing advisor; 11A's debug
  console is what handles 11b support tickets
- `Phase 12` workflow automation will need new admin surfaces
  (workflow registry, write-tool audit log) — extends `11A`
  rather than parallel-stacking

## Source Material

- [PROJECT_TRACKER.md](C:/Git%20Local%20Repos/forge_flow_demo/PROJECT_TRACKER.md)
- [Graphify v5 repository](https://github.com/safishamsi/graphify/tree/v5)
- [Graphify architecture](https://raw.githubusercontent.com/safishamsi/graphify/v5/ARCHITECTURE.md)
- [Graphify MIT license](https://raw.githubusercontent.com/safishamsi/graphify/v5/LICENSE)
- [phase_11a_advisor_infrastructure_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md) (substrate accepted; archive reference)
- [Architecture_Guide.pdf](C:/Git%20Local%20Repos/forge_flow_demo/Architecture_Guide.pdf)
- [lib/theme/app_theme.dart](C:/Git%20Local%20Repos/forge_flow_demo/lib/theme/app_theme.dart)
