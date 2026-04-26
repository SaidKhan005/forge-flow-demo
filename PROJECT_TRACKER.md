# Forge & Flow Project Tracker

Updated: 2026-04-26
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

- `11a.11c.5`, `11a.11c.6`, `11a.11d`, `11a.11e`: read
  `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`; add
  `docs/phases/phase_11a/phase_11a_decision_register.md` only when the prompt
  needs Azure/AGE rationale, fallback posture, or parked decisions.
- `11A.*`: read
  `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`.
- `9.8`, `9`, `10a`, `10.5`, `9.5`, `7.58`, `11b`, `9.75`, `10b`, `7.61`,
  `8`, `8R`: read that phase's doc under `docs/phases/**` when it opens.

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day
Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan ->
WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn.

## Now

- Current phase: `11a` live-infrastructure sequence is active.
- Postgres host: Azure DB Flexible Server, Canada Central, PG 16.
- Retrieval pattern: Modular Adaptive Agentic RAG.
- Cost discipline: 5 levers locked (Hard Promise #9).
- Next slice for Claude: `11a.11c.5` repo tooling re-target to Azure
  (code-only, no live apply).
- Next live gate: `11a.11c.6` Azure provisioning + extension verify +
  schema apply + AGE benchmark.

Architecture rationale, retrieval-pattern detail, cost levers, pricing tier
numbers, dormancy rules, and parked decisions live in
`docs/phases/phase_11a/phase_11a_decision_register.md`. Load it only when a
prompt needs that depth.

## Current Slice Queue

1. `11a.11c.5` - repo tooling re-target to Azure (code-only)
2. `11a.11c.6` - Azure provisioning + extension verify + schema apply + AGE
   benchmark
3. `11a.11d` - proxy counter wiring + smoke; locks levers 1-2 (prompt
   caching, tier routing)
4. `11a.11e` - corpus + embedding live load; runs Contextual Retrieval
   indexing
5. `11A.0-6` - F&F Operations Console foundation
6. Resume: `9.8 → 9 → 10a → 10.5 → 9.5 → 7.58 → 11b → 11b.1 (NEW
   schema-foundation slice) → 9.75 → 11b.2 → 11A.7-10 → 10b → 7.61 → 8 →
   8R → 8.5 (NEW external integrations) → 12.0-12.5 (workflow platform
   program) → 12.x+`

Slice scopes in their phase plans. Architecture rationale in
`phase_11a_decision_register.md`.

## Phase Board

| Phase | Status | Plan |
| --- | --- | --- |
| `7.57` | complete | archived |
| `11a` | active | `phase_11a_advisor_infrastructure_plan.md` |
| `11A` | queued | `phase_11A_operations_console_plan.md` |
| `11b` / `11b.1` (NEW) / `11b.2` | queued | `phase_11b/phase_11b_advisor_ux_plan.md` |
| `9.8` | queued | `phase_9_8/phase_9_8_compliance_and_legal_plan.md` |
| `8.5` (NEW) | queued | `phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md` |
| `12.0–12.5` (NEW program) | queued | `phase_12_workflow_platform/phase_12_workflow_platform_plan.md` |
| `7.58`, `7.61`, `8`, `8R` | queued | their respective plans |

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
  exists.

## Decision Locations

- All architecture rationale, retrieval pattern detail, cost levers, pricing
  tiers, dormancy rules, fallbacks, prompt-injection posture, and forward
  design gaps: `phase_11a/phase_11a_decision_register.md`.
- Active `11a` slice tasks: `phase_11a/phase_11a_advisor_infrastructure_plan.md`.
- Operations Console: `phase_11A_operations_console/phase_11A_operations_console_plan.md`.
- Phase 12 program: `phase_12_workflow_platform/phase_12_workflow_platform_plan.md`.
- External integrations: `phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md`.
- Pre-lean history: `docs/archive/trackers/PROJECT_TRACKER_2026-04-26_PRE_LEAN_AZURE_PIVOT.md`.

## Notes

- `.env.local` is the canonical private local env file. It is ignored,
  untracked, and must not be committed or deleted.
- Supabase reports under `docs/archive/phases/phase_11a/phase_11a_11b*` and
  `phase_11a_11c2/11c3*` are historical after the Azure pivot.
- If an active prompt seems to require a key, account, cloud project, CLI,
  billing setup, dashboard setup, or infrastructure choice, the prompt must say
  so in Block 1 before Claude receives the paste block.
