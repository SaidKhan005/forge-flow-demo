# Forge & Flow Project Tracker

Updated: 2026-05-03
Owner: You · Execution: We think, Claude codes

This is a routing map, not the full plan. Slice scopes live in their phase doc.

## Now

- **Active**: `10.5.0` daypart toggle scaffold, `10.5.1` bucketing
  engine, and `10.5.2` per-period read service + Shift cards + Variance
  lens accepted; `10.5.3+` primary-driver teaching is next. Evidence:
  `docs/_walkthroughs/10.5.0.md`, `docs/_walkthroughs/10.5.1.md`,
  `docs/_walkthroughs/10.5.2.md`; 10.5.2 closeout:
  `docs/archive/phases/phase_10_5/10_5_2_per_period_read_service_closeout.md`.
- 11A Operations Console foundation now spans `11A.0`–`5`/`6`/`7`/`UX.health`
  accepted. `11A.5` Debug Console (per-operator request log) and `11A.6`
  observability dashboard (bounded cost telemetry, dormancy, margin, cap
  events, graph, Cloud Run) both ship live HTTP gateways; walkthroughs at
  `docs/_walkthroughs/11A.5.md` and `docs/_walkthroughs/11A.6.md`.
- **2026-05-03 staging runtime/perf remediation**: graph candidates packaging,
  staging audit-anchor recovery, manual Health diagnostics, and perf guardrails
  are captured in `docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`.
  Durable future-slice rules live in
  `docs/contracts/slice_runtime_acceptance_contract.md`. Authenticated
  screen/action timing still needs explicit credential-send approval.
- **Recent accepted batches**: PRs #41-66 closed HARD-A-H, 7.58/7.61.0,
  10a.0, 10.5.0/1, 11A foundation/B44, admin MFA/staging stabilization,
  and postgres/MFA test parcels. PRs #70-73 (2026-05-03) closed 7.61.1
  (driver-key F-1), 11A.5 Debug Console, 11A.6 Observability, and 10.5.2
  per-period read service. Details live in phase docs, walkthroughs, and
  `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`.
- **`cutover.0a` + `cutover.0a.pg` complete (2026-05-01)**. Production1
  Postgres on CMK (`forge-flow-production1-pg-cmk`); post-baseline migration
  apply remains the top operational gate.
- **Production cloud setup lane paused** per operator direction 2026-05-03:
  Production1 has a GCP/Firebase shell, but no production runtime setup.
  Current staging parity is captured in
  `docs/phases/phase_production_cutover/production1_staging_parity_baseline_2026-05-03.md`.
  Production still needs Firebase apps/client config/flavors, runtime APIs,
  deploy service account, Secret Manager namespace, static egress, DNS, and
  Azure firewall allowlist before traffic cutover. New staging additions after
  this baseline are explicit production-readiness deltas.
- **Cloud Armor**: preview-only at sensitivity 2; awaits ≥3 clean post-tuning
  days + approval before enforcement.
- **iOS physical device matrix**: deferred until Apple device/signing lane
  returns. Automated GitHub Actions iOS sim builds green on master.
- **Notify before** any live Firebase mutation, key/account request, billing
  setup, provider call, or product decision.

## Active Authority (read in this order when prompting)

1. `PROJECT_TRACKER.md` (this file) — routing.
2. `docs/contracts/**` — durable rules.
3. `docs/POST_HARDENING_FOLLOWUPS.md` — open P0–P3 items not in any contract.
4. The active phase doc named for the slice (see Prompt Fetch Map).
5. Decision registers when the slice needs architecture/cost/security rationale:
   `docs/phases/phase_11a/phase_11a_decision_register.md`,
   `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`,
   `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md`.
6. `docs/CODEX_PROMPT_GENERATION_STANDARD.md` — prompt shape, parallel-lane rules.

`docs/archive/**` is history; ignore unless explicitly named.

Codex users: invoke `$forge-flow` when available for Forge & Flow work. The
local skill mirrors this authority path, phase routing, live-mutation
boundaries, migration/runtime gates, walkthrough evidence, and tracker closeout
rules. Prefer the local MCP servers in `.mcp.json` for orientation when
available: `forgeflow_docs` for active docs/contracts/phase/runbook lookup,
`forgeflow_sqlite_schema` for read-only local SQLite schema inspection, and
`graphify` for graph context.

## Prompt Fetch Map

| Slice prefix | Read |
| --- | --- |
| `11a.*` | substrate accepted (no new slices expected); historical plan at `docs/archive/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`; live decision register at `phase_11a/phase_11a_decision_register.md` for architecture/cost/security rationale |
| `11A.*` | `phase_11A_operations_console/phase_11A_operations_console_plan.md` |
| `cutover.*` | `phase_production_cutover/phase_production_cutover_plan.md` (+ scalability decisions for 0a; perf audit for 0b) |
| `9.0Σ.*`, `9.live-closeout`, `9.0-9.10` | `phase_9/phase_9_auth_plan.md` + `phase_9_execution_backlog.md` (+ scalability decisions doc for `0Σ`) |
| `9.8`, `10a`/`10b`/`10.5`, `9.5`/`9.75`, `7.58`/`7.61`, `8`/`8R`/`8.5`, `11b*`, `12.*` | that phase's doc under `docs/phases/**` |

## North Star

POS + Labor + Reservation → Canonical Operational Facts → 60-Day Benchmark
Snapshot → TargetCycle + DemandForecastContext → SchedulePlan →
WeeklyPlanSnapshot → Shift → Variance → History → Learn.

## Active Lanes

Codex on master; Claude in `.claude/worktrees/<lane>`. Multiple phases may run
in parallel. File ownership, walkthrough, merge sequencing:
`docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Parallel Worktrees".

Sprints PRs #50-66 closed `7.58.UX.5`, `10.5.0`, `10.5.1`, `7.61.0`,
`10a.0`, B44 graph producers, postgres repo + MFA adapter test parcels,
admin MFA challenge parity, staging admin stabilization, and the runbook
companion. PRs #70-73 (2026-05-03) closed `7.61.1` (driver-key F-1
HistoryTeachingAnalyzer cleanup), `11A.5` Debug Console (per-operator
request log viewer), `11A.6` Observability dashboard (cost telemetry +
dormancy + cap events + graph + Cloud Run), and `10.5.2` per-period read
service + Shift cards + Variance lens. Phase 7.58 is zero-DRIFT. Next
candidates by readiness:

1. **Production1 migration apply event** — 27 migrations queued
   (`202604280014`–`202605021900`); runbook now refreshed.
   Operator-driven; no code change needed.
2. **Production1 GCP/Firebase/proxy/DNS setup** — project/Firebase shell exists;
   runtime setup is paused. Remaining: Firebase apps/configs, runtime APIs,
   deploy service account, static egress, DNS, secrets, Azure firewall allowlist.
3. **B43 Production1 anchor deploy** — needs Production1 runtime APIs,
   Secret Manager namespace, static egress, and Azure audit-anchor secrets.
4. **`10a` follow-on UX surfaces** — `10a.0` scaffold accepted; `10a.UX.0`
   sync-state badge and `10a.UX.1` peer-edit toast + Settings freshness rows
   queued; Pub/Sub adapter + dead-letter + retention sweep + tripwires also
   queued.
5. **`10.5.3+` daypart-live primary-driver teaching** — `10.5.0`/`.1`/`.2`
   accepted; `.3+` next per phase doc; coordinates with `7.61.2` empty-state
   default fix.
6. **`7.61` pre-Phase-8 cleanup** — driver-key audit; `.1` accepted, `.2`
   (F-2 empty-state default in `history_teaching_analyzer.dart`) and `.3`
   (F-3 dev-fixture cleanup in `demo_fixture_data.dart`) queued; `.4`
   deferred; gated before Phase 8.

**Then queued (rough order):** `9.5`, `9.75`, `8`/`8R`/`8.5`,
`11b`/`11b.1`/`11b.2`, `12.*`, `9.8`, `cutover.0b`–`0-5`.

## Phase Board

Accepted phases retire to `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.
Live board lists active + queued only.

| Phase | Status | Plan |
| --- | --- | --- |
| `11A` foundation | active; `0`–`5`/`6`/`7`/`UX.health` accepted; B44/B45/B47 producers delivered; `8`/`9`/`10` not started | `phase_11A_operations_console_plan.md` |
| `9` framework + `9.0Σ.b-l` + `9.UX.*` | accepted on master + applied to staging; phase 9 itself stays open until `9.8` lands; B41/B43/B44/B45/B46/B47/B48 are operational gates | `phase_9/*` |
| `7.58` | `7.58.0` + `7.58.5` + `7.58.UX.5` accepted; zero DRIFT. `7.58.1`/`.2`/`.3`/`.4` queued | `phase_7_58/*` |
| `10.5` | active; `10.5.0` daypart toggle scaffold + `10.5.1` bucketing engine + `10.5.2` per-period read service/Shift cards/Variance lens accepted; `10.5.3+` primary-driver teaching queued | `phase_10_5/*` |
| `7.61` | active; `7.61.0` audit pinned; `7.61.1` F-1 accepted (HistoryTeachingAnalyzer unknown-id fallthrough removed, 28 active + 1 F-2 holdout skipped, walkthrough `7.61.1.md`); `.2`/`.3` queued per F-2/F-3; `.4` deferred to `cutover.0b` (F-A); F-B (`shifts.primary_lever` lowercase migration) deferred post-`cutover.5` | `phase_7_61/*` |
| `10a` | active; `10a.0` realtime push channel scaffold (NOTIFY → claim → in-process publisher → WebSocket) — Pub/Sub adapter + dead-letter + retention sweep + tripwires + UX surfaces queued | `phase_10a/*` |
| `9.5`, `9.75`, `8`, `8R`, `8.5` | queued | their respective plans |
| `11b`/`11b.1`/`11b.2` | queued (gated on B43 prod anchor; `11A.5` and `11A.6` accepted) | `phase_11b/*` |
| `12.0`–`12.5` | queued (gated by B41 live apply) | `phase_12_workflow_platform/*` |
| `9.8` | queued (launch-blocking; sequenced after auth + vendor contracts) | `phase_9_8/*` |
| `cutover.0b` | queued — Tier-M perf gate is launch-blocking, but the current runner needs the Production1 corpus seed/harness generated by `cutover.1`; it gates first-operator/live-traffic slices | `phase_production_cutover/*` |
| `cutover.1` | queued — production corpus load generates the 0b seed/harness artifacts | same plan |
| `cutover.2`–`5` | queued (post-`0b`) | same plan |

## Hard Gates

- All `7.58.*` accept before `11b.0`; all `7.61.*` accept before Phase 8.
  `7.61.1` closed F-1. F-2/F-3 remain silent-overclaim cleanup in the
  History/Learn analyzer + dev fixture; F-A is a deferred Postgres CHECK
  constraint; F-B is the deferred `shifts.primary_lever` lowercase
  migration (post-cutover.5, no slice owner).
- `cutover.0b` Tier-M perf gate is the launch blocker before first
  operator/live traffic, but it cannot run until `cutover.1` generates the
  Production1 corpus seed/harness artifacts.
- Production migrations use online-migration patterns once real operator data
  exists; transition point is `cutover.4` accepting.
- Migration changes require
  `dart run tool/migration_drift_scanner.dart --fix --strict-docs`, then
  `dart run tool/migration_cutoff_lint.dart`.
- Runtime-exposed slices must satisfy
  `docs/contracts/slice_runtime_acceptance_contract.md`.
- Browser-exposed slices use Browser Use acceptance evidence when available:
  route sweep, primary click path, desktop/mobile evidence as applicable, and
  walkthrough attachment per `runbooks/browser_use_acceptance_harness_runbook.md`.
- Before future staging console performance claims, run
  `dart run tool/perf_gate/staging_console_probe.dart --run --admin-url=<url> --proxy-url=<url>`
  and attach the JSON output. Use `--enforce-budgets` for PR/release gates;
  use `--include-health` only for a deliberate, bounded health probe.
- 35 scalability locks (`phase_9_scalability_decisions_2026-04-27.md`) are
  authoritative; the 10 Hard Promises in `CLAUDE.md` are durable.

## Notes

- `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` is the canonical
  private env loader (outside repo, never commit).
- If a prompt requires a key, account, cloud project, billing setup, or
  infrastructure choice, surface it in Block 1 of the prompt.
