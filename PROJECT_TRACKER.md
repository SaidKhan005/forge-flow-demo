# Forge & Flow Project Tracker

Updated: 2026-04-27
Owner: You
Execution model: We think, Claude codes

## Active Authority

Read this file first for current phase, next slice, and which phase doc to
fetch. Do not treat this tracker as the full plan. It is now the lean routing
map.

Primary active docs:

- `PROJECT_TRACKER.md` - current phase, next slice, guardrails, fetch map.
- `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md` - active
  11a execution plan and slice contracts.
- `docs/phases/phase_11a/phase_11a_decision_register.md` - 11a decisions,
  parked follow-ups, soft constraints, and AGE/Azure rationale.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`
  - capital-A admin console plan.
- `docs/phases/phase_9/phase_9_auth_plan.md` - Phase 9 framework and live
  auth acceptance plan.
- `docs/phases/phase_9/phase_9_execution_backlog.md` - Phase 9 live-closeout
  parcels that remain after framework acceptance.
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md` - prompt shape and human
  prerequisite / decision-block rules.
- `docs/DATA_ALIGNMENT_TRACKER.md` only for alignment-heavy slices.
- `docs/KNOWN_FAILING_TESTS.md` only for broad or known-red test runs.

Archive for history, not normal prompting:

- `docs/archive/trackers/PROJECT_TRACKER_2026-04-26_PRE_LEAN_AZURE_PIVOT.md`
  - full pre-lean tracker with all prior detail.
- `docs/archive/phases/phase_11a/phase_11a_advisor_infrastructure_plan_2026-04-26_PRE_LEAN_AZURE_PIVOT.md`
  - full pre-lean 11a plan.
- `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md` - older completed phase
  history.

## How To Fetch Context

Before each prompt:

1. Read `PROJECT_TRACKER.md` sections `Now`, `Current Slice Queue`, and
   `Prompt Fetch Map`.
2. Read only the phase doc named for the current slice.
3. If the slice asks for architecture, blockers, cost, security, or sequencing
   decisions, also read the relevant decision register listed in the fetch map.
4. Do not read archived docs unless there is a disputed historical question or
   a prompt explicitly targets archive history.
5. Do not let Claude infer user-owned decisions. Surface them in Block 1 under
   `Human prerequisites -> Decision needed for this slice`.

## Prompt Fetch Map

- `11a.11c.5`, `11a.11c.6*`, `11a.11d`, `11a.11e`: read
  `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`; add
  `docs/phases/phase_11a/phase_11a_decision_register.md` only when the prompt
  needs Azure/AGE rationale, fallback posture, or parked decisions.
- `11A.*`: read
  `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`.
- `cutover.*`: read
  `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`;
  add `phase_11a_decision_register.md` when the prompt needs cost
  envelopes, tier choice, or dormancy rules.
- `9.live-closeout`, `9.0-9.10` (incl. `9.0a`): read
  `docs/phases/phase_9/phase_9_auth_plan.md` and
  `docs/phases/phase_9/phase_9_execution_backlog.md`; add
  `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md` when the prompt
  touches any user-owned Phase 9 choice; add `phase_11a_decision_register.md`
  when the prompt needs Phase 9 architecture-lock rationale, RLS performance
  discipline, or repository-pattern detail.
- `9.8`, `10a`, `10.5`, `9.5`, `7.58`, `11b`, `9.75`, `10b`, `7.61`,
  `8`, `8R`: read that phase's doc under `docs/phases/**` when it opens.

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day
Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan ->
WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn.

## Now

- Current phase: `9` Auth framework is complete; move through Phase 9
  live-closeout parcels before `11A.0-6` (sequence re-locked 2026-04-26
  under "full proper dev before launch - no shortcuts").
- Postgres host: Azure DB Flexible Server, Canada Central, PG 16.
- Retrieval pattern: Modular Adaptive Agentic RAG.
- Cost discipline: 5 levers locked (Hard Promise #9).
- Last completed infrastructure action: `11a.11e` staging live retrieval
  accepted end-to-end. Anthropic generated 233 chunk contexts, Voyage
  refreshed 233 context-enriched embeddings, vector/rerank smokes passed, and
  Claude answer smoke returned `end_turn`.
- Last completed auth action: Phase 9 in-app auth smoke prerequisites are
  READY as of 2026-04-27. The staging proxy is deployed, `/readyz` passes,
  the non-repo secrets loader carries the proxy URI and smoke-user password,
  and Cloud Run has `FIREBASE_PROJECT_ID`, `POSTGRES_URL`, and
  `POSTGRES_ADMIN_URL`. The proxy session-ledger endpoint also shipped on
  2026-04-27. Four POST routes
  (`/v1/auth/session/login` / `refresh` / `revoke` / `revoke-all`) on
  `tool/advisor_proxy/advisor_proxy.dart`, all auth-gated through the
  existing Firebase verifier path and delegating to an injected
  `AuthSessionLedgerWriter`; matching `ProxyAuthSessionLedgerWriter`
  in `lib/services/auth/` drives the routes from the Flutter app via
  `dart:io HttpClient`. `firebase_auth_runtime_bindings.dart` accepts
  an optional `proxyBaseUri` and entrypoints read
  `FORGE_FLOW_PROXY_BASE_URI` from `--dart-define`; without it the
  bootstrap falls back to the scaffold-failing default and sign-in
  fails closed with a calm `ledger_unavailable` message. Focused
  Phase 9 sweep passed `566/566` (+33 new tests: 13 server-side
  route + 12 client-writer + the prior tranche's audit-fix tests).
  Prior accepted slices (database closeout live on staging and
  Production1; Firebase app wiring behind `FORGE_FLOW_USE_FIREBASE_AUTH`;
  staging Firebase credential + `auth_sessions` smoke; Settings -> Team
  permission-gated Material UI foundation) remain accepted. Result
  docs: `docs/phases/phase_9/phase_9_live_database_closeout_result.md`
  and `docs/phases/phase_9/phase_9_live_runtime_closeout_result.md`.
- Current auth setup state: staging Firebase project `forge-flow-staging`
  exists, is billing-enabled, is upgraded to Identity Platform, has both
  Android apps, both iOS bundle IDs, and the admin web app registered. Email /
  password and TOTP MFA are enabled; SMS/phone auth is disabled. Local secrets
  are consolidated outside the repo in `$HOME/.forge_flow/`; the canonical
  loader is `$HOME/.forge_flow/forge_flow.secrets.ps1`, and the Firebase Admin
  SDK JSON sits beside it as `$HOME/.forge_flow/firebase-staging-adminsdk.json`.
  Phase 9 launch MFA decision: email/password + TOTP ship first; passkeys are
  a future follow-up unless an official Firebase / Identity Platform passkey
  surface appears. Auth email decision: use Firebase action links with branded
  Forge & Flow web pages, so Firebase subject/body template customization is
  not a launch blocker. FlutterFire + secure-storage packages are installed;
  Android Gradle wiring is verified; iOS config-copy wiring is written but
  awaits a macOS build check. Proxy session-ledger endpoint shipped
  2026-04-27 (four POST routes + Flutter `ProxyAuthSessionLedgerWriter`);
  proxy boot now wires `RepositoryAuthSessionLedgerWriter` over
  `PackagePostgresPool` with `POSTGRES_URL`, so the four
  `/v1/auth/session/*` routes are ready to write real Postgres rows
  when deployed.
  Full Phase 9 decision set is locked in
  `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md`.
- Next slice: run the `auth-smoke@forgeflow.dev` in-app login/logout smoke
  through the deployed staging proxy. 2026-04-27 prerequisite closeout is
  READY: the unified secrets file loads, the smoke password is present,
  `FORGE_FLOW_PROXY_BASE_URI` is present outside the repo, Cloud Run service
  `forge-flow-staging-proxy` is deployed with `FIREBASE_PROJECT_ID`,
  `POSTGRES_URL`, and `POSTGRES_ADMIN_URL`, and the app can launch with
  `FORGE_FLOW_USE_FIREBASE_AUTH=true` plus the proxy base URI define. Result
  doc: `docs/phases/phase_9/phase_9_in_app_auth_smoke_prereq_result.md`.
  Do not ask the user to paste secrets in chat; the URL/password must flow
  through the non-repo secrets file or Cloud Run state.
  After the smoke passes, group role/admin, lifecycle, password, MFA,
  and recovery-code endpoints as one or more audited proxy slices.
  Notify the user before any live Firebase account mutation,
  key/account request, billing/account setup, provider call, or
  product decision.

Architecture rationale, retrieval-pattern detail, cost levers, pricing tier
numbers, dormancy rules, and parked decisions live in
`docs/phases/phase_11a/phase_11a_decision_register.md`. Load it only when a
prompt needs that depth.

## Current Slice Queue

Locked 2026-04-26 under "full proper dev before launch — no shortcuts":
the entire product (advisor + workflows + vendor data + compliance)
ships before any operator goes live on production. No friend-beta, no
demo-mode launch, no split-and-defer of compliance.

**Pre-launch (in order):**

1. `9.live-closeout` - Phase 9 live-closeout parcels from
   `phase_9_execution_backlog.md`. Database closeout, Firebase SDK/app
   wiring, staging credential/session smoke, and Settings -> Team Material UI
   foundation are complete. Continue with the proxy auth endpoint tranche
   (session ledger first), then Cloud Armor / reCAPTCHA and remaining live MFA
   / password / lifecycle bindings.
2. `9.10` - Operator-facing Settings -> Team UX inside the Forge & Flow /
   Barrio operator app. Kernel + first Material UI foundation are complete;
   proxy-backed data/actions and dense role/audit detail views remain under
   `9.live-closeout`.
3. `9.0a` - Multi-location scale-flow additions logged
   2026-04-26 from the franchise auth audit:
   - Live migrations are applied and verified on staging + Production1.
   - `user_roles.scope_type`, `users.primary_location_id`,
     `operators.region`, 12 `team.*` permission keys, and the
     super_admin team-grant audit fix are live.
   - Detail in `phase_9/phase_9_auth_plan.md` sub-slices 9.0a + 9.10.
4. `11A.0-6` - F&F Operations Console foundation.
5. `7.58` - Primary Driver audit (Hard Promise #3 gate before `11b.0`).
6. `10a` - Shared state v1 (real-time `NOTIFY` -> Pub/Sub bridge).
7. `10.5` - Live daypart shift.
8. `9.5` - El Podio learning identity.
9. `9.75` - Staff daily companion (Barrio shell).
10. `7.61` - Freshness audit (Hard Gate before Phase 8).
11. `8` - POS / labor transport.
12. `8R` - Reservation transport.
13. `8.5` - External integrations (QBO, Xero, Bill.com, Plaid).
14. `11b` - Advisor UX (with real corpus + real operator data).
15. `11b.1` - Schema-foundation sweep (consolidates everything
    learned across `11A`, `9`, `7.58`, `10a`, `10.5`, `9.5`, `9.75`,
    `8`, `8R`, `8.5`).
16. `11b.2` - Causal queries (AGE traversal in advisor hot path).
17. `12.0` - Workflow platform foundation.
18. `12.1` - Tool registry.
19. `12.2` - Plan-Then-Execute pattern.
20. `12.3` - Approval gate.
21. `12.4` - Weekly P&L workflow (flagship; depends on `8.5`).
22. `12.5` - Workflow catalog.
23. `11A.7-10` - Admin polish (feature flag admin, API version
    management, audit log review, status page).
23. `10b` - Full offline sync.
24. `9.8` - Full compliance package: T&Cs + DPAs (Toast, 7shifts,
    OpenTable, QBO/Xero/Bill.com/Plaid, Anthropic, Voyage, Microsoft
    Azure, Google Cloud) + SOC2 inheritance memo + cyber-liability
    insurance review. Lands last because every named processor is
    now real and the chain is enumerable.
25. `cutover.0-4` - Production cutover with the full product live.

**Post-launch (additive, ongoing):**

- `cutover.5` - Beta widening to additional operators.
- `12.x+` - Additional workflow catalog entries (weekly close,
  OT alert, schedule draft, etc., on demand).

Slice scopes in their phase plans. Architecture rationale in
`phase_11a_decision_register.md`.

## Phase Board

| Phase | Status | Plan |
| --- | --- | --- |
| `7.57` | complete | archived |
| `11a` | accepted | `phase_11a_advisor_infrastructure_plan.md` |
| `9.0-9.10` (incl. `9.0a`) | framework complete; live-closeout active; database closeout, Firebase SDK/app wiring, staging credential/session smoke, and 9.10 Material UI foundation accepted | `phase_9/phase_9_auth_plan.md` + `phase_9/phase_9_execution_backlog.md` |
| `11A.0-6` | queued | `phase_11A_operations_console_plan.md` |
| `7.58`, `7.61` | queued | their respective plans |
| `10a`, `10.5` | queued | their respective plans |
| `9.5`, `9.75` | queued | their respective plans |
| `8`, `8R` | queued | their respective plans |
| `8.5` (NEW) | queued | `phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md` |
| `11b` / `11b.1` (NEW) / `11b.2` | queued | `phase_11b/phase_11b_advisor_ux_plan.md` |
| `12.0-12.5` (NEW program) | queued | `phase_12_workflow_platform/phase_12_workflow_platform_plan.md` |
| `11A.7-10` | queued (post-flagship) | `phase_11A_operations_console_plan.md` |
| `10b` | queued | `phase_10b/phase_10b_full_offline_sync_plan.md` |
| `9.8` | queued (lands last; depends on full processor chain) | `phase_9_8/phase_9_8_compliance_and_legal_plan.md` |
| `cutover.0-5` (NEW) | queued (final pre-launch slice) | `phase_production_cutover/phase_production_cutover_plan.md` |

## Hard Gates

- Tracker truth cannot move ahead of repo truth.
- Postgres host = Azure DB Flexible Server, Canada Central, PG 16.
- AGE infrastructure live before `11b` (Hard Promise #5).
- Per-operator isolation: `(operator_id, location_id, staff_id NULL)`, RLS,
  repository pattern; no retrofit. `staff_id` axis added in `11b.1`.
- `TIMESTAMP WITHOUT TIME ZONE` banned in operator-scoped cloud tables.
- AI cost metered by class (Hard Promise #9). Concrete pricing + caps in
  decision register.
- 5 cost-discipline levers wired before/alongside `11b`. Detail in decision
  register.
- Defer fixed-cost services until variable usage justifies them.
- Operator dormancy: 30d skip precompute / 60d re-auth / 90d suspend; new
  operators default workflows OFF.
- Phase 9 RLS real before `11b` multi-operator.
- All `7.58` sub-slices accept before `11b.0`; all `7.61` sub-slices accept
  before Phase 8.
- Vendor secrets stay server-side; Flutter release builds carry no real keys.
- Advisor posture is recommendation-only.
- Demo mode persists forever, behaviorally stable.
- No commits unless explicitly asked.

Wording / rationale / numbers for each gate: `phase_11a_decision_register.md`.

## Active Guardrails

- Build cadence is sequential, not parallel.
- Phase 8 is a pure transport swap. Fixture extraction, service moves,
  freshness audits, or behavior decisions belong in `7.57`, `7.58`, or `7.61`.
- No app logic changes before `7.58` except scoped additive infrastructure
  work already in the active sequence.
- Service-layer split: `lib/data/` legacy/frozen, `lib/services/` runtime
  orchestration, `lib/domain/services/` pure domain logic, `lib/state/` state
  holders.
- Production migrations use online-migration patterns once real operator data
  exists. The transition point is `cutover.4` accepting; before that, production
  schema is freely deterministic. Detail in
  `phase_production_cutover/phase_production_cutover_plan.md`.

## Decision Locations

- All architecture rationale, retrieval pattern detail, cost levers, pricing
  tiers, dormancy rules, fallbacks, prompt-injection posture, and forward
  design gaps: `phase_11a/phase_11a_decision_register.md`.
- Active `11a` slice tasks: `phase_11a/phase_11a_advisor_infrastructure_plan.md`.
- Operations Console: `phase_11A_operations_console/phase_11A_operations_console_plan.md`.
- Production cutover: `phase_production_cutover/phase_production_cutover_plan.md`.
- Phase 12 program: `phase_12_workflow_platform/phase_12_workflow_platform_plan.md`.
- External integrations: `phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md`.
- Pre-lean history: `docs/archive/trackers/PROJECT_TRACKER_2026-04-26_PRE_LEAN_AZURE_PIVOT.md`.

## Notes

- `$HOME/.forge_flow/forge_flow.secrets.ps1` is the canonical private local
  env loader. It is outside the repo and must not be committed or pasted.
  `.env.local` remains ignored if recreated, but is no longer the source of
  truth for local keys.
- Supabase reports under `docs/archive/phases/phase_11a/phase_11a_11b*` and
  `phase_11a_11c2/11c3*` are historical after the Azure pivot.
- If an active prompt seems to require a key, account, cloud project, CLI,
  billing setup, dashboard setup, or infrastructure choice, the prompt must say
  so in Block 1 before Claude receives the paste block.
