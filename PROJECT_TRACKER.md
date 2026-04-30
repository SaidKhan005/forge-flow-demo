# Forge & Flow Project Tracker

Updated: 2026-04-30
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
- `docs/phases/phase_9/phase_9_ios_device_matrix_qa_plan.md` - physical iOS
  device QA matrix and blocker checklist.
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
- `runbooks/phase_9_production1_migration_apply_runbook.md` only for future
  Production1 database mutation gates or audit trace.

Archive for history, not normal prompting:

- `docs/archive/trackers/PROJECT_TRACKER_2026-04-26_PRE_LEAN_AZURE_PIVOT.md`
  - full pre-lean tracker with all prior detail.
- `docs/archive/phases/phase_11a/phase_11a_advisor_infrastructure_plan_2026-04-26_PRE_LEAN_AZURE_PIVOT.md`
  - full pre-lean 11a plan.
- `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md` - older completed phase
  history.
- `docs/archive/trackers/PROJECT_TRACKER_2026-04-29_PRE_PHASE9_CLOSEOUT_LEAN.md`
  - tracker snapshot before this closeout lean pass.
- `docs/archive/phases/phase_9/` - completed Phase 9 result reports, including
  auth-operation, MFA/recovery, Cloud Armor/iOS simulator, maintenance, and
  Production1 migration apply evidence.

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

- **Current phase:** `9` accepted for next-phase handoff on 2026-04-29.
  Cloud Armor enforcement is monitored by the `cloud-armor-preview-review`
  heartbeat; physical iOS device QA is deferred until the user returns with
  an Apple device/signing lane.
- **Done in this session:** B17 custom role catalog CRUD is implemented for
  `GET/POST/PATCH/DELETE /v1/admin/auth/roles`, deployed to staging revision
  `forge-flow-staging-proxy-00018-ztq`, and smoke-passed through
  `https://staging-api.feflow.org`. Staging and Production1 applied and
  verified `202604280000` through `202604280013`; Azure `ltree` allow-listing
  and `pg_cron` maintenance-database scheduling are documented in the runbook.
- **Phase 9 audit cleanup:** B42 proxy `/health` now returns the
  `proxy_health.v1` envelope with compatibility aliases, dependency checks,
  reserved metric keys, and reserved surface keys. B41 service-principal JWT
  issuance and B46 audit-privacy are local/code/test complete, but their
  additive live migrations (`202604290000`, `202604280014`) still need fresh
  staging + Production1 apply evidence before live phases depend on them.
- **Auth/MFA pressure-test routing:** `9.UX.1a` is now the Phase 9 MFA
  production-hardening slice: backend-scheduled 24h removals, fresh-auth +
  opaque proof for self/admin reset, recovery queued vs not-queued messaging,
  Firebase/local drift repair for self-removal, no recovery-code UX,
  self/admin pending-removal cancel, and no phone/SMS MFA. Mandatory
  admin-tier MFA enforcement is deferred until post-launch stability and
  explicit approval. B48 password-reset parity maps to `9.UX.7`; broader MFA
  support tooling and notification delivery map to Phase 11A/10a.
- **Health producer status:** B44 graph tripwire/runbook, B45 rollup freshness
  reporter/runbook, and B47 vector health helper/benchmark artifact exist;
  producer wiring that fills the B42 reserved metric values remains follow-on
  work for the 11A health surface.
- **Cloud Armor status:** staging WAF remains preview-only. B17 role CRUD
  found false positives in the original SQLi/XSS preview rule, so the policy
  was tuned to sensitivity 2 with the B17 false-positive SQLi signatures
  opted out. After tuning, normal role CRUD had zero preview hits and a
  controlled SQLi probe still produced a preview signal. Enforcement waits for
  at least 3 clean days of post-tuning preview logs plus explicit approval.
- **Accepted follow-ups:** Cloud Armor enforcement decision after the required
  clean preview-log window, and physical iOS device-matrix QA when the user
  resumes that lane.
- **Apple automated lane:** fresh GitHub Actions run `25087331405` passed on
  `master`: macOS host tests, ForgeFlow iOS simulator build, and Barrio iOS
  simulator build. Physical QA still needs the Apple device/signing lane.
- **Maintenance baseline:** green after the staging deploy/smoke/tuning pass:
  `flutter analyze --fatal-infos`, `dart run tool/rls_policy_lint.dart`,
  focused B17 auth/proxy tests, `git diff --check`, and full
  `flutter test --reporter compact` passed (`2544/2544`).
- **Notify the user before** any live Firebase mutation, key/account
  request, billing setup, provider call, or product decision.

Phase 9 setup state, decisions, and full auth context:
`phase_9/phase_9_auth_plan.md` + `phase_9/phase_9_decision_lock_2026-04-26.md`.
Architecture rationale, cost levers, pricing tiers, dormancy rules:
`phase_11a/phase_11a_decision_register.md`. 35 scalability locks:
`phase_9/phase_9_scalability_decisions_2026-04-27.md`. Load only
when a prompt needs that depth.

## Current Slice Queue

Locked 2026-04-26 under "full proper dev before launch - no shortcuts": the
entire product ships before any operator goes live on production. No
friend-beta, no demo-mode launch, no split-and-defer of compliance.

Realigned 2026-04-29 after the Production1 apply, B17 staging smoke, Cloud
Armor preview tuning, Apple simulator recheck, and docs lean pass.

**Active lanes** (Codex on master; Claude in `.claude/worktrees/<lane>`):

Multiple phases may be active simultaneously. Each lane carries one
slice from one phase to acceptance. File ownership, shared-seam
serialization, walkthrough evidence per lane, and merge sequencing
follow `docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Parallel Lanes".

1. `11A.0-6` - F&F Operations Console foundation. Scope:
   `phase_11A_operations_console_plan.md`.
2. `9.UX.0-7` plus `9.UX.1a` - Phase 9 operator-facing UX family and MFA
   production-hardening sub-slice. Parallel with
   `11A.0-6` (different code surfaces). Scope:
   `phase_9_auth_plan.md` `Frontend Exposure` section. Within-family
   shared seams (e.g., `auth_operations_gateway.dart`,
   `settings_screen.dart`) require sequencing per phase doc.

Codex sets the per-lane queue; this tracker lists which phases are
active, not which slices are next per lane.

**Monitored/deferred Phase 9 follow-ups:**

1. Cloud Armor enforcement - heartbeat updates this session until there are
   at least 3 clean post-tuning preview-log days and explicit approval to
   enforce.
2. iOS physical device matrix - deferred; the user will come back to it later
   with an Apple device/signing lane.
3. `cutover.0b` - Tier-M 14-row perf-gate run; launch blocker.
4. `202604280014` + `202604290000` + `202604290001` live apply/smoke -
   required before live 11b audit-privacy reads (`202604280014`),
   Phase 12 service-principal issuance dependence (`202604290000`), or
   any consumer of `user_effective_locations` / org-unit scoped grants
   (`202604290001` hierarchy access wiring).
5. B44/B45/B47 metric producers - fill the B42 `/health` reserved values for
   the 11A.5 health surface.
6. B48 password reset email-link parity - local code complete; deploy/smoke
   the proxy + web action page before relying on email-link reset in live.
7. B49/B50 MFA hardening + notification delivery - `9.UX.1a` local code
   queues `event_outbox` rows only. True in-app/email notification delivery
   is not a background pipeline yet; Phase 10a bridge remains only if
   user-facing copy promises an email or in-app notification.
8. Mandatory admin-tier MFA enforcement - explicitly deferred until
   post-launch stability and explicit approval; do not treat as a launch
   blocker.

**Then continue:**

1. `7.58` - Primary Driver audit.
2. `10a` - Shared state v1 (`event_outbox` -> Pub/Sub/WebSocket bridge;
   `NOTIFY` is wake-up only and never the source of truth).
3. `10.5` - Live daypart shift.
4. `9.5` - El Podio learning identity.
5. `9.75` - Staff daily companion.
6. `7.61` - Freshness audit.
7. `8` and `8R` - POS/labor/finance and reservation transport.
8. `8.5` - narrowed outbound finance integrations.
9. `11b`, `11b.1`, `11b.2` - Advisor UX, schema sweep, causal queries.
10. `12.0-12.5` - Workflow platform foundation and flagship workflows.
11. `11A.7-10`, `10b`, `9.8`, `cutover.0a`, `cutover.0-5`.

Slice scopes live in their phase plans. Architecture rationale lives in
`phase_11a_decision_register.md` and the Phase 9 scalability decisions doc.

## Phase Board

| Phase | Status | Plan |
| --- | --- | --- |
| `7.57` | complete | archived |
| `11a` | accepted | `phase_11a_advisor_infrastructure_plan.md` |
| `9.0-9.10` (incl. `9.0a`) | accepted; Cloud Armor monitored, iOS physical deferred | `phase_9/phase_9_auth_plan.md` + `phase_9/phase_9_execution_backlog.md` |
| `9.0 Sigma b-k` | complete on master and applied to staging + Production1 | `phase_9/phase_9_scalability_decisions_2026-04-27.md` + backlog B23-B32 |
| `9.UX.0-7` + `9.UX.1a` | active in flight (`9.UX.0` ~50% done; `9.UX.1a` added after auth/MFA pressure test) | `phase_9/phase_9_auth_plan.md` `Frontend Exposure` |
| `11A.0-6` | next | `phase_11A_operations_console_plan.md` |
| `7.58`, `7.61` | queued | their respective plans |
| `10a`, `10.5` | queued | their respective plans |
| `9.5`, `9.75` | queued | their respective plans |
| `8` | queued | phase 8 plan |
| `8R` | queued | phase 8R plan |
| `8.5` | queued | `phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md` |
| `11b` / `11b.1` / `11b.2` | queued | `phase_11b/phase_11b_advisor_ux_plan.md` |
| `12.0-12.5` | queued (gated by B41 live apply/smoke) | `phase_12_workflow_platform/phase_12_workflow_platform_plan.md` |
| `11A.7-10` | queued | `phase_11A_operations_console_plan.md` |
| `10b` | queued | `phase_10b/phase_10b_full_offline_sync_plan.md` |
| `9.8` | queued (lands last) | `phase_9_8/phase_9_8_compliance_and_legal_plan.md` |
| `cutover.0a`, `cutover.0b`, `cutover.0-5` | queued | `phase_production_cutover/phase_production_cutover_plan.md` |

## Hard Gates

- Every backend phase ships its operator-facing UX before phase close
  (Hard Promise #10). Phase docs include a `Frontend Exposure` section;
  UX-exposing slices add a demo-mode walkthrough to acceptance. Detail:
  `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.
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
