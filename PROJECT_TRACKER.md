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
- **In scope** — `8`/`8R`/`8.S`/`8.spine-bridge`/`11W` (minus `.9`)/`11A.10`/`10a`/`9.8` inbound T&Cs + email/`7.58`/Cutover.
- **Production1 paused** (2026-05-03). Wave 1 ships staging-only first; unfreeze becomes a parallel critical path before V1 launch. Baseline: `docs/phases/phase_production_cutover/production1_staging_parity_baseline_2026-05-03.md`. Pending Production1 apply: `202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql` + `202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql` + `202605060000_mobile_push_notifications.sql` (the 202605041930 file applied + Browser Use verified on staging 2026-05-04 after live-admin E2E found `forge_admin` lacked operator/location DML; the mobile push migration is code-ready and still requires staging apply/device proof before Production1).
- **Mobile push end-to-end reminder** (PR #149 / branch `codex/mobile-fcm-notifications`): review first, then wire through staging before any Production1 apply. Staging proof must include: apply `202605060000_mobile_push_notifications.sql`; configure the staging proxy with `MOBILE_PUSH_TOKEN_ENVELOPE_KEY` plus FCM HTTP v1 access through the deployed service account; deploy the proxy routes `/v1/auth/mobile/push-token/register`, `/v1/auth/mobile/push-token/revoke`, and `/v1/auth/mobile/push/test`; build/install ForgeFlow on a physical Android/iOS device with `FORGE_FLOW_USE_FIREBASE_AUTH=true`, `FORGE_FLOW_PROXY_BASE_URI=https://staging-api.feflow.org`, `FORGE_FLOW_APP_VARIANT=forgeflow`, and `FORGE_FLOW_APP_ENVIRONMENT=staging`; sign in with a staging operator account; verify a row lands in `public.mobile_push_tokens` without token plaintext in responses/logs; call the self-test route; confirm the OS popup appears on the phone; tap it and confirm the app opens `NotificationsScreen`. Production proof is separate and remains gated: after staging is green and explicitly approved, apply the same migration to Production1, configure production `MOBILE_PUSH_TOKEN_ENVELOPE_KEY`/FCM HTTP v1 access, deploy the production proxy, build the production Firebase workspace release, run a limited real-device smoke, and document rollback/revoke steps. Flutter clients must never contain Firebase Admin credentials or FCM server keys.
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
| `8` / `8R` / `8.S` / `8.spine-bridge` / `8.live` | `phase_8/*`, `phase_8R/*`, `phase_8S/*`, `phase_8/phase_8_spine_bridge_plan.md`, `phase_8_live_rollout/*` |
| `8.5`, `9.8`, `10a`/`10b`, `9.5`/`9.75`, `7.58`, `11b*`, `11W*`, `12.*` | matching `docs/phases/**` doc |

## North Star

POS + Labor + Reservation → Canonical Operational Facts → 60-Day Benchmark Snapshot → TargetCycle + DemandForecastContext → SchedulePlan → WeeklyPlanSnapshot → Shift → Variance → History → Learn.

## Phase Board

Accepted phases retire to `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.

| Phase | Status | Plan |
| --- | --- | --- |
| `9` framework + `9.0Σ.b-l` + `9.UX.*` | accepted; phase 9 stays open until `9.8` lands | `phase_9/*` |
| `7.58` | CLOSED — depth wave landed 2026-05-05 on master @ `699a45f`: all 5 slices ACCEPT (`.UX.6`/`.UX.8`/`.cross-axis.0`/`10.5.6`/`.UX.7+9`). `.UX.6` follow-up closed via `3154679` (PR #144). Phase 7.58 advisor-depth-complete. Audit: `docs/_execution/2026-05-05_depth_wave_audit.md`. | `phase_7_58/phase_7_58_depth_wave_plan.md` |
| `7.61` (closed) | all 4 non-deferred slices accepted | `docs/archive/phases/phase_7_61/` |
| `10.5` (closed) | all 4 slices accepted | `docs/archive/phases/phase_10_5/` |
| `10a` | `.0`/`.1`/`.2` + `UX.0`/`UX.1` accepted; `.3`/`.4`/`.5` queued | `phase_10a/*` |
| `9.5` | `.0` accepted; `.UX.*` paused (Barrio) | `phase_9_5/*` |
| `11A` foundation | `0`–`5`/`6`/`7`/`UX.health` accepted; `8`/`9`/`10` not started; `11A.12-14` deferred | `phase_11A_operations_console/*` |
| `11W` Operator Web Console | `11W.0` accepted (PR #87); `11W.7`/`11W.8` queued; remaining 7 slices deferred | `phase_11W/*` |
| `9.75` | paused (Barrio) | `phase_9_75/*` |
| `8` (POS) | engineering-complete (PASS 2026-05-05 via `mobile-proof.v2`); Wave B `documented` for 7 adapters; lifecycle promotion via `phase_8_live_rollout` | `phase_8/*` + `vendor_master_list.md` |
| `8R` (Reservations) | engineering-complete (PASS 2026-05-05 via `mobile-proof.v2`); Wave B `documented` for 4 adapters; lifecycle promotion via `phase_8_live_rollout` | `phase_8R/*` |
| `8.S` (Scheduling) | engineering-complete (PASS 2026-05-05 via `mobile-proof.v2`); Wave B `documented` for 6 adapters; lifecycle promotion via `phase_8_live_rollout` | `phase_8S/*` |
| `8.spine-bridge` | accepted 2026-05-05 — 11 sub-lanes landed (`.0` / `.0a` / `.1.OR` / `.1.QBT` / `.1.LB` / `.2` / `.3` / `.A` / `.B` / `.C` / `.7S.upgrade`); `.4` proof v2 PASSED 27/27 | `phase_8/phase_8_spine_bridge_plan.md`, `docs/_execution/2026-05-05_8_integration_mobile_proof_v2_execution.md` |
| `8.spine-bridge-sink-fanout` | queued — 14 file-disjoint Postgres sink lanes for the remaining vendors (cleared by `mobile-proof.v2` PASS 2026-05-05) | `phase_8/phase_8_spine_bridge_plan.md` |
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

**Phase 7.58 depth wave CLOSED 2026-05-05** on master @ `699a45f`. All 5 slices ACCEPT (`.UX.6`/`.UX.8`/`.cross-axis.0`/`10.5.6`/`.UX.7+9`); `.UX.6` legacy widget-test follow-up closed via `3154679` (PR #144) — `flutter test test/variance_history_widget_test.dart` → 70/70 PASS. Bold by Design + Jim Taylor depth now surfaces inside existing chrome (DOLLAR IMPACT triplet footer, OPZ-aware row adornment, OPZ matrix grid on Shift whole-day, cross-axis pair catalog + Learn carousel swap, coverage caption on Learn snapshot). **Core app logic preserved**: `LaborModel.determineLever`, `attributeDollarImpactByAxis`, `theoreticalLaborPct`, `ShiftFactBuilder`, persistence, sync, Concern A all signature-stable. Audit: `docs/_execution/2026-05-05_depth_wave_audit.md`. Plan: `docs/phases/phase_7_58/phase_7_58_depth_wave_plan.md`. Contract: `docs/contracts/phase_7_58_primary_driver_contract.md` "Depth Surfaces" section.

Phase 8 / 8R / 8.S engineering-complete on master (mobile-proof.v2 PASSED 2026-05-05; evidence: `docs/_execution/2026-05-05_8_integration_mobile_proof_v2_execution.md`). `8.spine-bridge-sink-fanout` paused 2026-05-05; resume via explicit prompt.

**Wave D — rolling `*.live.*` slices** fire individually as credentials arrive (`<vendor_id>.live.sandbox` → `sandbox_verified`; `<vendor_id>.live.prod` → `production_credentialed`). Tracker: `phase_8_live_rollout/phase_8_live_rollout_plan.md`.

**Operator parallel critical path (no engineering)**: sandbox provisioning across 17 vendors; DNS+TLS for `app.forgeflow.app` + `mail.forgeflow.app`; SendGrid + DKIM/SPF/DMARC; partnership applications; legal review of inbound T&Cs; Production1 unfreeze decision. None blocks Wave B engineering.

**Queued (in-scope, sequencing intent)**: 11W/11A parallel waves (Wave 1: `11W.1` + `11A.12` Members; Wave 2: `11W.2`+`11W.3`+`11W.4`+`11A.13` Roles/Hierarchy/Sessions; Wave 3: `11W.5`+`11W.6`+`11A.14` Audit/Security/Support); `8.live.connected-device-smoke` (cleared; trio credentials gating); `cutover.0b`–`5`; Phase 11A `10`; `9.8` inbound T&Cs (legal-gated); `8.spine-bridge-sink-fanout` (paused 2026-05-05).

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

2026-05-05 closeout:

- **Phase 8 / 8R / 8.S engineering-complete** via `8.integration-mobile-proof.v2` PASS. Evidence: `docs/_execution/2026-05-05_8_integration_mobile_proof_v2_execution.md` (27/27; 686/686 tests). Sink-fanout paused; live trio smoke cleared but operator-credential-gated.
- **Phase 7.58 advisor depth wave queued** post 8-slice merge (PRs #125–#136). Origin audit: `docs/_execution/2026-05-05_outcome_engineering_depth_audit.md`. Wave honors core-logic-preserved posture: renderer-side + analyzer-additive only; engine math, persistence, sync, Concern A all unchanged.
- 2026-05-05 vendor-research falsehoods captured in `integration_spine_architecture_contract.md` "2026-05-05 falsehood corrections" section.
- Mobile architecture (canonical-fact dicts → operator-scoped Postgres `shift_records` → mobile SQLite via proxy sync) bound by `integration_spine_architecture_contract.md`.
- `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` is the canonical private env loader (outside repo).
- If a prompt requires a key, account, cloud project, billing setup, or infrastructure choice, surface it in Block 1.
