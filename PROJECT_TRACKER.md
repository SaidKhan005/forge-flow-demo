# Forge & Flow Project Tracker

Updated: 2026-05-06
Owner: You · Execution: We think, Claude codes

Routing map only. Slice scopes live in their phase docs.

## Authority Order (Active Read Order)

1. `PROJECT_TRACKER.md` (this file) — routing.
2. `docs/contracts/**` — durable rules.
3. `docs/POST_HARDENING_FOLLOWUPS.md` — open P0–P3 items.
4. The active phase doc named for the slice (Prompt Fetch Map below).
5. Decision registers when the slice needs arch/cost/security rationale:
   `docs/phases/phase_11a/phase_11a_decision_register.md`,
   `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`,
   `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md`.
6. `docs/CODEX_PROMPT_GENERATION_STANDARD.md` — prompt shape, parallel-lane rules.
7. `docs/PERFORMANCE_FRAMEWORK.md` — performance / scale / mobile / web-console / load / health / bundle.
8. `docs/UX_ADJUSTMENT_FRAMEWORK.md` — UX polish, copy, admin-console clarity, navigation grouping, button/modal styling, filters, keys, tooltips, browser-tab polish, no-regression UX adjustment.
9. `docs/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` — Browser Use, web/admin acceptance, device QA, branch-to-runtime proof.

`docs/archive/**` is history; ignore unless explicitly named. Authority is normative in `CLAUDE.md`.

Prefer `.mcp.json` servers for orientation: `forgeflow_docs`, `forgeflow_sqlite_schema`, `graphify`.

## Now

- **V1 push direction (locked 2026-05-03)**: inbound-integration framework + two-console web management plane. See `memory/project_v1_launch_decisions_2026_05_03.md`, `project_v1_lean_scope_cut.md`, `project_phase_8_architecture.md`, `project_two_console_framing.md`, `project_ux_writing_standard.md`.
- **AI paused** — `11b/.1/.2`, `12.*`, `11A.3/.3.x`, `11A.11`, `9.8` AI portion, `10b`. See `memory/project_phase_pause_2026_05_03.md`.
- **Outward-vendor paused** — `8.5`, `11W.9`. See `memory/project_phase_pause_2026_05_03.md`.
- **Barrio paused** — `9.5.UX.*`, `9.75`, `lib/internal/barrio/**`, `lib/main_barrio.dart`. See `memory/project_barrio_paused.md`.
- **In scope** — `8.spine-bridge-sink-fanout` (2 of 14 sink lanes remain — Oracle Simphony + OpenTable — plus `.7S.upgrade` adapter capability extension), `8.star-target-server-truth` (server selected stars -> manager override -> target cycle -> active target profile -> mobile cache), Claude V1 closure dispatch (`docs/_execution/2026-05-06_v1_closure_dispatch_plan.md`) — V1.A/B/E/F/G NOW + V1.C/D queued post-Codex, `11A.10` (impersonation), `9.8` inbound T&Cs + email, Cutover.
- **Production1 paused** (2026-05-03). Pending Production1/staging apply queue (9 migrations) tracked in `docs/POST_HARDENING_FOLLOWUPS.md` "P0 - Production1 Migration Apply Gap". Baseline: `docs/phases/phase_production_cutover/production1_staging_parity_baseline_2026-05-03.md`.
- **Mobile push end-to-end** (PR #149, code-ready as of `db7ce131`): staging-proof checklist owned by the Production1 apply runbook. Production proof gated on staging-green + explicit approval. Flutter clients never carry Firebase Admin credentials / FCM server keys (lint-enforced via `test/services/mobile_push_sender_test.dart`).
- **Staging runtime/perf carry-forward** (2026-05-03): `docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`; durable rules in `docs/contracts/slice_runtime_acceptance_contract.md`.
- **Notify before** any live Firebase mutation, key/account request, billing setup, provider call, or product decision.

## Prompt Fetch Map

| Slice prefix | Read |
| --- | --- |
| `11a.*` | archived: `docs/archive/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`; live: `phase_11a/phase_11a_decision_register.md` |
| `11A.*` | `phase_11A_operations_console/phase_11A_operations_console_plan.md` |
| `cutover.*` | `phase_production_cutover/phase_production_cutover_plan.md` |
| `9.0Σ.*`, `9.live-closeout`, `9.0-9.10` | `phase_9/phase_9_auth_plan.md` + `phase_9_execution_backlog.md` |
| `7.58` / `7.61` / `10.5` (closed) | `docs/archive/phases/phase_7_58/`, `docs/archive/phases/phase_7_61/`, `docs/archive/phases/phase_10_5/` |
| `8` / `8R` / `8.S` / `8.spine-bridge*` / `8.live` | `phase_8/*`, `phase_8R/*`, `phase_8S/*`, `phase_8/phase_8_spine_bridge_plan.md`, `phase_business_timing_live/*`, `phase_8_live_rollout/*` |
| `8.5`, `9.8`, `10a`/`10b`, `9.5`/`9.75`, `11b*`, `11W*`, `12.*` | matching `docs/phases/**` doc |

## North Star

POS + Labor + Reservation → Canonical Operational Facts → 60-Day Benchmark Snapshot → TargetCycle + DemandForecastContext → SchedulePlan → WeeklyPlanSnapshot → Shift → Variance → History → Learn.

## Phase Board

Accepted phases retire to `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.

| Phase | Status | Plan |
| --- | --- | --- |
| `9` framework + `9.0Σ.b-l` + `9.UX.*` | accepted; phase stays open until `9.8` inbound T&Cs land | `phase_9/*` |
| `9.5` | `.0` accepted; `.UX.*` paused (Barrio) | `phase_9_5/*` |
| `11A` | foundation `0`–`7`/`UX.health` ACCEPT + cross-op parity `.12`/`.13`/`.14` ACCEPT 2026-05-06; `.8`/`.9`/`.10` not started | `phase_11A_operations_console/*` |
| `11W` Operator Web Console | `.0`–`.8` ACCEPT 2026-05-06 (A1 web shell `f5a94c08`, A2 Account + Business Timing `9a56cabf`, A3 Vendor Connections `075fde54`, parity `.1`–`.6`, live wiring fix `11W.7.live-wire`); `11W.9` paused (depends on 8.5) | `phase_11W/*` |
| `9.75` | paused (Barrio) | `phase_9_75/*` |
| `8` (POS) | engineering-complete (PASS 2026-05-05 via `mobile-proof.v2`); Wave B `documented` for 7 adapters; lifecycle promotion via `phase_8_live_rollout` | `phase_8/*` + `vendor_master_list.md` |
| `8R` (Reservations) | engineering-complete (PASS 2026-05-05 via `mobile-proof.v2`); Wave B `documented` for 4 adapters; lifecycle promotion via `phase_8_live_rollout` | `phase_8R/*` |
| `8.S` (Scheduling) | engineering-complete (PASS 2026-05-05 via `mobile-proof.v2`); Wave B `documented` for 6 adapters; lifecycle promotion via `phase_8_live_rollout` | `phase_8S/*` |
| `8.spine-bridge-sink-fanout` | RUNNING — 12 of 14 ACCEPT (`.1.AL`/`.TC`/`.HM`/`.SQ`/`.TS`/`.PU`/`.AG`/`.CL`/`.ADP`/`.RV`/`.SR`/`.LSK` 2026-05-06); 2 lanes remain (Oracle Simphony, OpenTable) plus the `.7S.upgrade` adapter capability extension. Plus `8.business_date_denorm` ACCEPT 2026-05-06 (`c61c2ea7`) | `phase_8/phase_8_spine_bridge_plan.md` |
| `business-timing-live` | foundation + UI shell + closed timing label stability proof merged 2026-05-06; canonical timing source is same-DB `business_timing_profiles`/service periods; first-connect wire-in now invokes the closed aggregator/open projector seams under fixture proof; future full hierarchy/settings lanes remain separate | `phase_business_timing_live/business_timing_live_plan.md` |
| `8.star-target-server-truth` | PLANNED 2026-05-06 — Codex sprint covering Doc 1 items 1–3. Moves selected star shifts, manager override, target cycles, and active target profiles from local-only/mobile cache truth to server truth. | `docs/contracts/mobile_core_star_target_truth_contract.md`, `docs/_execution/2026-05-06_mobile_core_star_target_truth_sprint_plan.md` |
| `8.weekly-plan-server-truth` | PLANNED 2026-05-06 — future Doc 1 sprint covering item 4 (server weekly plan snapshots + forecast context). V1.C lane in dispatch plan ships Lane 0 only (additive Postgres schema + repos). | `docs/contracts/mobile_core_weekly_plan_server_truth_contract.md` |
| `8.business-scope-selector` | PLANNED 2026-05-06 — future Doc 1 sprint covering item 5 (mobile business scope selector + accessible-scopes server route). V1.D lane in dispatch plan ships Lane 0 only (server route + local active-scope repo). | `docs/contracts/mobile_core_business_scope_contract.md` |
| Claude V1 closure dispatch | RUNNING 2026-05-06 — seven file-disjoint lanes (V1.A/B/C/D/E/F/G) closing punchlist items + Doc 1 Lane 0s + cutover preflight harness; V1.C/D wait for Codex's `8.star-target-server-truth.Lane 0` / `Lane 3` to merge. | `docs/_execution/2026-05-06_v1_closure_dispatch_plan.md` |
| `8.live` (lifecycle rollout) | open — 17 `*.live.sandbox` + 17 `*.live.prod` slices; closes when last vendor reaches `production_credentialed`; `*.live.prod` slices soft-blocked on V1.E `vendor-now-available` email fan-out | `phase_8_live_rollout/phase_8_live_rollout_plan.md` |
| `8.5` (Outbound finance) | paused (outward-vendor) | `phase_8_5_external_integrations/*` |
| `11b`/`.1`/`.2` | paused (AI) | `phase_11b/*` |
| `12.0`–`12.5` | paused (AI) | `phase_12_workflow_platform/*` |
| `9.8` | `.email` accepted (PR #88); inbound-vendor T&Cs in scope; advisor + outbound paused | `phase_9_8/*` |
| `11A.3` + `11A.3.x` | paused (AI) | `phase_11A_operations_console/*` |
| `11A.11` | paused (AI) | `phase_11A_operations_console/*` |
| `11W.9` | paused (depends on 8.5) | `phase_11W/*` |
| `10b` | paused (AI) | n/a |
| `cutover.0b` | queued — Tier-M perf gate; needs `cutover.1` corpus seed | `phase_production_cutover/*` |
| `cutover.1` | queued — production corpus load | same plan |
| `cutover.2`–`5` | queued (post-`0b`) | same plan |

## Active Lanes

Codex on master; Claude in `.claude/worktrees/<lane>`. Multiple phases may run in parallel. Rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Parallel Worktrees".

**Master state 2026-05-06 post-audit**: 5-agent audit at HEAD `fad3c031` confirmed Lane 0 + 1 + 2 (closed-truth) + 3 + 4 + 5 (live-truth) + A1 + B1–B4 all landed with code/lints/tests green (1982/1983 PASS, single fail = quarantined). All 5 hardening lints clean. Live provider/device proof remains future lifecycle/E2E work. Audit reports under `docs/_execution/2026-05-06*`.

**Currently running**: User's worktrees on `8.spine-bridge-sink-fanout` (2 of 14 sink lanes outstanding — Oracle Simphony · OpenTable — plus `.7S.upgrade` adapter capability extension; AL · TC · HM · SQ · TS · PU · AG · CL · ADP · RV · SR · LSK all ACCEPT 2026-05-06); Codex on `8.star-target-server-truth` (Doc 1 items 1–3; Lane 0 server decision schema must land before proxy/mobile/target projection lanes); Claude V1 closure dispatch (`docs/_execution/2026-05-06_v1_closure_dispatch_plan.md`) — V1.A closed-row proxy timing provenance + V1.B FK posture migration + V1.E vendor-now-available email fan-out + V1.F connector backfill jobs test coverage + V1.G cutover.0 preflight harness running NOW; V1.C weekly-plan server truth Lane 0 + V1.D mobile-scope foundation queued for after Codex's Lane 0 / Lane 3 merges.

**Wave D — rolling `*.live.*` slices** fire individually as credentials arrive. Tracker: `phase_8_live_rollout/phase_8_live_rollout_plan.md`.

**Operator parallel critical path (no engineering)**: see `docs/_execution/2026-05-05_v1_launch_punchlist.md` Section 0.

**Skip until unfreeze**: see Now block paused lists.

## Hard Gates

- All `7.58.*` accept before `11b.0`. (Driver-key Phase-8 gate satisfied.)
- `cutover.0b` Tier-M perf gate is launch-blocking; needs `cutover.1` corpus seed first.
- Production migrations use online-migration patterns once real operator data exists; transition at `cutover.4`.
- Migration changes: `dart run tool/migration_drift_scanner.dart --fix --strict-docs`, then `dart run tool/migration_cutoff_lint.dart`.
- Runtime-exposed slices satisfy `docs/contracts/slice_runtime_acceptance_contract.md`. Browser-exposed slices use Browser Use evidence per `runbooks/browser_use_acceptance_harness_runbook.md` and full E2E uses `docs/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md`.
- Before staging console perf claims: `dart run tool/perf_gate/staging_console_probe.dart --run --admin-url=<url> --proxy-url=<url>` and attach JSON. `--enforce-budgets` for PR/release gates; `--include-health` only for bounded health probes.
- 35 scalability locks (`phase_9_scalability_decisions_2026-04-27.md`) authoritative; 10 Hard Promises in `CLAUDE.md` durable.

## Notes

- Mobile architecture (canonical-fact dicts → operator-scoped Postgres `shift_records` → mobile SQLite via proxy sync) bound by `integration_spine_architecture_contract.md`.
- 2026-05-05 vendor-research falsehoods captured in `integration_spine_architecture_contract.md` "2026-05-05 falsehood corrections" section.
- `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` is the canonical private env loader (outside repo).
- Closed-phase audits/closeouts live in `docs/_execution/`; follow CLAUDE.md "Phase Doc Hygiene" and retire to `docs/archive/phases/` within a week.
- If a prompt requires a key, account, cloud project, billing setup, or infrastructure choice, surface it in Block 1.
