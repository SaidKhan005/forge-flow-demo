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
- **In scope** — `8.spine-bridge-sink-fanout` (7 of 14 lanes remain after `.1.AL`/`.TC`/`.HM`/`.SQ`/`.TS`/`.PU`/`.AG`), `8.spine-bridge-live` (projector + writer routes queued post-foundation), `11W.0`/`.7`/`.8` (V1 web shell), `11A.10` (impersonation), `9.8` inbound T&Cs + email, business-timing-live writer + projector, Cutover.
- **Production1 paused** (2026-05-03). Pending Production1/staging apply queue (7 migrations) tracked in `docs/POST_HARDENING_FOLLOWUPS.md` "P0 - Production1 Migration Apply Gap". Baseline: `docs/phases/phase_production_cutover/production1_staging_parity_baseline_2026-05-03.md`.
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
| `7.61` / `10.5` (closed) | `docs/archive/phases/phase_7_61/`, `docs/archive/phases/phase_10_5/` |
| `8` / `8R` / `8.S` / `8.spine-bridge` / `8.spine-bridge-live` / `8.live` | `phase_8/*`, `phase_8R/*`, `phase_8S/*`, `phase_8/phase_8_spine_bridge_plan.md`, `phase_business_timing_live/*`, `phase_8_live_rollout/*` |
| `8.5`, `9.8`, `10a`/`10b`, `9.5`/`9.75`, `7.58`, `11b*`, `11W*`, `12.*` | matching `docs/phases/**` doc |

## North Star

POS + Labor + Reservation → Canonical Operational Facts → 60-Day Benchmark Snapshot → TargetCycle + DemandForecastContext → SchedulePlan → WeeklyPlanSnapshot → Shift → Variance → History → Learn.

## Phase Board

Accepted phases retire to `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.

| Phase | Status | Plan |
| --- | --- | --- |
| `9` framework + `9.0Σ.b-l` + `9.UX.*` | accepted; phase stays open until `9.8` inbound T&Cs land | `phase_9/*` |
| `7.58` (closed 2026-05-05) | advisor-depth-complete; all 5 depth-wave slices ACCEPT | `docs/archive/phases/phase_7_58/` |
| `7.61` (closed) | all 4 non-deferred slices accepted | `docs/archive/phases/phase_7_61/` |
| `10.5` (closed) | all 4 slices accepted | `docs/archive/phases/phase_10_5/` |
| `10a` (closed for V1 2026-05-06) | `.0`/`.1`/`.2`/`.3`/`.4`/`.5` + `UX.0`/`UX.1` ACCEPT | `phase_10a/*` |
| `9.5` | `.0` accepted; `.UX.*` paused (Barrio) | `phase_9_5/*` |
| `11A` | foundation `0`–`7`/`UX.health` ACCEPT + cross-op parity `.12`/`.13`/`.14` ACCEPT 2026-05-06; `.8`/`.9`/`.10` not started | `phase_11A_operations_console/*` |
| `11W` Operator Web Console | parity `.1`–`.6` ACCEPT 2026-05-06; `.0`/`.7`/`.8` queued for V1 launch | `phase_11W/*` |
| `9.75` | paused (Barrio) | `phase_9_75/*` |
| `8` (POS) | engineering-complete (PASS 2026-05-05 via `mobile-proof.v2`); Wave B `documented` for 7 adapters; lifecycle promotion via `phase_8_live_rollout` | `phase_8/*` + `vendor_master_list.md` |
| `8R` (Reservations) | engineering-complete (PASS 2026-05-05 via `mobile-proof.v2`); Wave B `documented` for 4 adapters; lifecycle promotion via `phase_8_live_rollout` | `phase_8R/*` |
| `8.S` (Scheduling) | engineering-complete (PASS 2026-05-05 via `mobile-proof.v2`); Wave B `documented` for 6 adapters; lifecycle promotion via `phase_8_live_rollout` | `phase_8S/*` |
| `8.spine-bridge` | ACCEPT 2026-05-05 — 11 sub-lanes + `.4` proof v2 PASS 27/27 | `phase_8/phase_8_spine_bridge_plan.md`, `docs/_execution/2026-05-05_8_integration_mobile_proof_v2_execution.md` |
| `8.spine-bridge-sink-fanout` | RUNNING — 1 of 14 ACCEPT (`.1.AL` Aloha NCR Voyix `94ac00ac`); 13 lanes remain. Plus `8.business_date_denorm` ACCEPT 2026-05-06 (`c61c2ea7`) | `phase_8/phase_8_spine_bridge_plan.md` |
| `business-timing-live` | foundation + UI shell merged; canonical timing source is same-DB `business_timing_profiles`/service periods; live producer/proxy/write proof remains gated | `phase_business_timing_live/business_timing_live_plan.md` |
| `8.spine-bridge-live` | queued - explicit live lane after sink fanout + timing schema review: OpenShiftSnapshotProjector -> open_shift_snapshots -> proxy pull -> mobile SQLite -> Shift selectors | `phase_8/phase_8_spine_bridge_plan.md`, `phase_business_timing_live/business_timing_live_plan.md` |
| `8.live` (lifecycle rollout) | open — 17 `*.live.sandbox` + 17 `*.live.prod` slices; closes when last vendor reaches `production_credentialed` | `phase_8_live_rollout/phase_8_live_rollout_plan.md` |
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

**Master state 2026-05-06**: deep audit + alignment pass closed all REJECT-level structural defects from the 11+10 parallel sprint window. All 4 hardening lints clean (`index_leading_column_lint`, `migration_cutoff_lint`, `rls_policy_lint`, `postgres_import_lint`). Permission catalog reconciled to 99 keys; `team.audit_log.export` migration landed via `99b36ddc`; index rekey via `2e619e3a`; history-analyzer test re-pinned to post-7.58.4 seed via `bb604cd2`; admin shell + corpus + settings MFA tests aligned via `768117ea`; 11A.14 audit doc drift cleared via `45bdd734`. Audit reports: see `docs/_execution/`.

**Currently running**: `8.spine-bridge-sink-fanout` (7 of 14 lanes outstanding — Aloha + Tock + Humanity + Square + Toast + Push Operations + Agendrix landed; remaining: Clover · Lightspeed LSK · Revel · Oracle Simphony · ADP · 7shifts upgrade · OpenTable · SevenRooms); `business-timing-live` writer + projector (queued post-foundation review); V1 web shell (`11W.0` / `.7` / `.8`).

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
