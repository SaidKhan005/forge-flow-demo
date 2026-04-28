# Forge & Flow Project Tracker

Updated: 2026-04-28
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
- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md` - 35
  locked scalability decisions (Q1-Q22 + Q3.1-Q3.10) absorbed into the
  pre-launch sequence on 2026-04-28. Freshest architecture direction;
  supersedes anything older if it conflicts with a Q-locked item.
- `docs/phases/phase_9/phase_9_scalability_performance_audit_2026-04-27.md`
  - CONDITIONAL PASS verdict, 3 load profiles, hot-path inventory,
  Bottleneck Ranking, and the 14-row Prelaunch Performance Test Matrix
  that is the launch gate (now `cutover.0b`).
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md` - prompt shape and human
  prerequisite / decision-block rules.
- `docs/CODEX_LEAN_PROMPT_GENERATOR.md` - compact copy/paste generator for
  next-slice prompts, stale-finding filtering, live gates, and doc hygiene.
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
- `9.0Σ.b` … `9.0Σ.k`: read
  `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md` (the
  Q-decision that owns the slice) and
  `docs/phases/phase_9/phase_9_execution_backlog.md` (the matching B23+
  parcel). Add `phase_9_scalability_performance_audit_2026-04-27.md` only if
  the slice has a perf-gate row in the 14-row matrix.
- `cutover.0a`, `cutover.0b`: read
  `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`
  PLUS `phase_9_scalability_decisions_2026-04-27.md` (CMK / item 8 for 0a)
  or `phase_9_scalability_performance_audit_2026-04-27.md` (the 14-row
  perf-gate matrix for 0b).
- `9.8`, `10a`, `10.5`, `9.5`, `7.58`, `11b`, `9.75`, `10b`, `7.61`,
  `8`, `8R`: read that phase's doc under `docs/phases/**` when it opens.

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day
Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan ->
WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn.

## Now

- **Current phase:** `9` live-closeout, then 9.0Σ.b-k (queued), then
  `11A.0-6`. Sequence realigned 2026-04-28 to absorb the 35 4-27 locks
  + perf-audit CONDITIONAL PASS. Detail per slice in its phase doc.
- **Next slice:** Phase 9 in-app auth smoke (`auth-smoke@forgeflow.dev`
  login/logout through the deployed staging proxy). Prereq state +
  result docs: `phase_9/phase_9_auth_plan.md` +
  `phase_9/phase_9_in_app_auth_smoke_prereq_result.md`. Do not paste
  secrets in chat; flow through `$HOME/.forge_flow/forge_flow.secrets.ps1`.
- **Notify the user before** any live Firebase mutation, key/account
  request, billing setup, provider call, or product decision.

Phase 9 setup state, decisions, and full auth context:
`phase_9/phase_9_auth_plan.md` + `phase_9/phase_9_decision_lock_2026-04-26.md`.
Architecture rationale, cost levers, pricing tiers, dormancy rules:
`phase_11a/phase_11a_decision_register.md`. 35 scalability locks:
`phase_9/phase_9_scalability_decisions_2026-04-27.md`. Load only
when a prompt needs that depth.

## Current Slice Queue

Locked 2026-04-26 under "full proper dev before launch — no shortcuts":
the entire product (advisor + workflows + vendor data + compliance)
ships before any operator goes live on production. No friend-beta, no
demo-mode launch, no split-and-defer of compliance.

Realigned 2026-04-28 to absorb the 35 locked scalability decisions and
the CONDITIONAL PASS perf audit. Ten 9.0Σ sub-slices land before
`11A.0-6`; two new cutover sub-slices gate launch.

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
4. **9.0Σ.b-k** — Ten queued scalability foundation sub-slices
   absorbing the 4-27 locks before any consumer touches them.
   `9.0b` RLS UUID wrappers, `9.0c` org_units ltree + data_region,
   `9.0d` service_principals, `9.0e` event_outbox, `9.0f`
   hash-chained audit_logs, `9.0g` usage_caps two-slot,
   `9.0h` advisor_conversation_log, `9.0i` graph_nodes/edges,
   `9.0j` vector indexing, `9.0k` rollups foundation. Per-slice
   scope, files, and gate: `phase_9_execution_backlog.md` parcels
   B23-B32. Rationale + Q-decision items:
   `phase_9_scalability_decisions_2026-04-27.md`.
5. `11A.0-6` - F&F Operations Console foundation.
6. `7.58` - Primary Driver audit (Hard Promise #3 gate before `11b.0`).
7. `10a` - Shared state v1 (real-time `NOTIFY` -> Pub/Sub bridge —
   completes the `9.0e` outbox by adding the Cloud Pub/Sub leg).
8. `10.5` - Live daypart shift.
9. `9.5` - El Podio learning identity.
10. `9.75` - Staff daily companion (Barrio shell).
11. `7.61` - Freshness audit (Hard Gate before Phase 8).
12. `8` - POS / labor / MarginEdge / R365 inbound transport
    (Decision F 2026-04-27).
13. `8R` - Reservation transport.
14. `8.5` - External integrations narrowed to QBO / Xero /
    Bill.com / Plaid + outbound finance only.
15. `11b` - Advisor UX (with real corpus + real operator data).
16. `11b.1` - Schema-foundation sweep (consolidates everything
    learned across `11A`, `9`, `7.58`, `10a`, `10.5`, `9.5`, `9.75`,
    `8`, `8R`, `8.5`).
17. `11b.2` - Causal queries (AGE traversal in advisor hot path).
18. `12.0` - Workflow platform foundation (depends on `9.0d`
    `service_principals`).
19. `12.1` - Tool registry.
20. `12.2` - Plan-Then-Execute pattern.
21. `12.3` - Approval gate.
22. `12.4` - Weekly P&L workflow (flagship; depends on `8.5`).
23. `12.5` - Workflow catalog.
24. `11A.7-10` - Admin polish (feature flag admin, API version
    management, audit log review, status page).
25. `10b` - Full offline sync.
26. `9.8` - Full compliance package: T&Cs + DPAs + SOC2
    inheritance + cyber-liability + ZDR / TTL / PCI / CMK / Quebec
    attestations. Lands last because every named processor is real.
    Detail: `phase_9_8/phase_9_8_compliance_and_legal_plan.md`.
27. `cutover.0a` — CMK at provisioning (decisions item 8).
28. `cutover.0b` — Tier-M 14-row perf-gate run; launch blocker.
    Detail: `phase_9_scalability_performance_audit_2026-04-27.md`.
29. `cutover.0-4` - Production cutover with the full product live.

**Post-launch (additive, ongoing):**

- `cutover.5` - Beta widening to additional operators.
- `12.x+` - Additional workflow catalog entries (weekly close,
  OT alert, schedule draft, etc., on demand).

Slice scopes in their phase plans. Architecture rationale in
`phase_11a_decision_register.md` and 4-27 scalability decisions doc.

## Phase Board

| Phase | Status | Plan |
| --- | --- | --- |
| `7.57` | complete | archived |
| `11a` | accepted | `phase_11a_advisor_infrastructure_plan.md` |
| `9.0-9.10` (incl. `9.0a`) | live-closeout active | `phase_9/phase_9_auth_plan.md` + `phase_9/phase_9_execution_backlog.md` |
| `9.0Σ.b-k` | queued | `phase_9/phase_9_scalability_decisions_2026-04-27.md` + backlog B23-B32 |
| `11A.0-6` | queued | `phase_11A_operations_console_plan.md` |
| `7.58`, `7.61` | queued | their respective plans |
| `10a`, `10.5` | queued | their respective plans |
| `9.5`, `9.75` | queued | their respective plans |
| `8` | queued | phase 8 plan |
| `8R` | queued | phase 8R plan |
| `8.5` | queued | `phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md` |
| `11b` / `11b.1` / `11b.2` | queued | `phase_11b/phase_11b_advisor_ux_plan.md` |
| `12.0-12.5` | queued (gated by `9.0d`) | `phase_12_workflow_platform/phase_12_workflow_platform_plan.md` |
| `11A.7-10` | queued | `phase_11A_operations_console_plan.md` |
| `10b` | queued | `phase_10b/phase_10b_full_offline_sync_plan.md` |
| `9.8` | queued (lands last) | `phase_9_8/phase_9_8_compliance_and_legal_plan.md` |
| `cutover.0a`, `cutover.0b`, `cutover.0-5` | queued | `phase_production_cutover/phase_production_cutover_plan.md` |

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
- **Scalability locks (35 items, 2026-04-27):** detail in
  `phase_9/phase_9_scalability_decisions_2026-04-27.md`. Tier-M
  14-row perf gate is `cutover.0b` (launch blocker).

Wording / rationale: `phase_11a_decision_register.md`
and `phase_9/phase_9_scalability_decisions_2026-04-27.md`.

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

- Architecture / cost / pricing / dormancy / fallback rationale:
  `phase_11a/phase_11a_decision_register.md`.
- 35 locked scalability decisions (Q1-Q22 + Q3.1-Q3.10):
  `phase_9/phase_9_scalability_decisions_2026-04-27.md`.
- Performance audit + 14-row perf gate:
  `phase_9/phase_9_scalability_performance_audit_2026-04-27.md`.
- Active 11a tasks: `phase_11a/phase_11a_advisor_infrastructure_plan.md`.
- Other phase plans: routed via `Phase Board` above.
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
