# Forge & Flow Project Tracker

Updated: 2026-05-03
Owner: You · Execution: We think, Claude codes

Routing map only. Slice scopes live in their phase docs.

## Now

- **V1 push direction (locked 2026-05-03)**: inbound-integration
  framework + two-console web management plane. Direct vendor
  integration only (no middleware default). Lean V1 cut applied
  (Phase 11W → 3 slices; 11A.12-14 deferred; over-engineering rolled
  back). UX-writing-as-training standard binds operator-facing
  surfaces. Plans at `docs/phases/phase_8/`, `docs/phases/phase_8R/`,
  `docs/phases/phase_8S/`, `docs/phases/phase_11W/`,
  `docs/phases/phase_9_8/`. Memory: `project_v1_launch_decisions_2026_05_03.md`,
  `project_v1_lean_scope_cut.md`, `project_phase_8_architecture.md`,
  `project_two_console_framing.md`, `project_operator_share_assumptions.md`,
  `project_ux_writing_standard.md`.
- **Phase pauses (operator direction 2026-05-03)**: AI / outward-vendor /
  Barrio. Paused for new work: `11b`/`.1`/`.2`, `12.*`, `11A.3`/`.3.x`,
  `11A.11`, `8.5`, `11W.9`, `10b`, `9.8` AI portion, all Barrio
  (`9.5.UX.*`, `9.75`, `lib/internal/barrio/**`, `lib/main_barrio.dart`).
  In scope: `8`/`8R`/`8.S`/`11W` (minus `.9`)/`11A.10`/`10a`/`9.8`
  inbound-vendor T&Cs + email-provider/`7.58`/Cutover. Memory:
  `project_phase_pause_2026_05_03.md`, `project_barrio_paused.md`.
  Pauses lift only on explicit operator unfreeze.
- **Production1 paused** (operator direction 2026-05-03). Postgres on
  CMK live; 27-file migration batch applied 2026-05-03; runtime needs
  Firebase apps/configs, runtime APIs, deploy SA, static egress, DNS,
  Secret Manager namespace, Azure firewall allowlist. Wave 1 ships
  staging-only first; Production1 unfreeze becomes a parallel critical
  path before V1 launch. Baseline:
  `docs/phases/phase_production_cutover/production1_staging_parity_baseline_2026-05-03.md`.
  Pending Production1 apply:
  `202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql` and
  `202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql`.
  The latter was applied and Browser Use verified on staging on 2026-05-04
  after live-admin E2E found `forge_admin` lacked operator/location DML.
- **Staging runtime/perf carry-forward** (2026-05-03):
  `docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`;
  durable rules in `docs/contracts/slice_runtime_acceptance_contract.md`.
  Authenticated screen/action timing still needs explicit
  credential-send approval. Cloud Armor preview-only at sensitivity 2
  pending ≥3 clean post-tuning days + approval. iOS physical device
  matrix deferred until Apple signing lane returns; sim builds green.
- **Notify before** any live Firebase mutation, key/account request,
  billing setup, provider call, or product decision.

## Active Authority (read in this order when prompting)

1. `PROJECT_TRACKER.md` (this file) — routing.
2. `docs/contracts/**` — durable rules.
3. `docs/POST_HARDENING_FOLLOWUPS.md` — open P0–P3 items.
4. The active phase doc named for the slice (Prompt Fetch Map below).
5. Decision registers when the slice needs arch/cost/security rationale:
   `docs/phases/phase_11a/phase_11a_decision_register.md`,
   `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`,
   `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md`.
6. `docs/CODEX_PROMPT_GENERATION_STANDARD.md` — prompt shape, parallel-lane rules.
7. `docs/PERFORMANCE_FRAMEWORK.md` — required for performance, scale,
   mobile responsiveness, web-console timing, load, polling, health, or
   bundle-size work.
8. `docs/UX_ADJUSTMENT_FRAMEWORK.md` - required for UX polish, copy,
   admin-console clarity, navigation grouping, button/modal styling, filters,
   keys, tooltips, browser-tab polish, or no-regression UX adjustment work.
9. `docs/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` — required for live Browser Use,
   web/admin console acceptance, mobile-device QA, safe-action sweeps, and
   branch-to-artifact-to-runtime proof.

`docs/archive/**` is history; ignore unless explicitly named.

Prefer `.mcp.json` servers for orientation when available: `forgeflow_docs`
(active docs/contracts/phase/runbook lookup), `forgeflow_sqlite_schema`
(read-only local SQLite schema), `graphify` (graph context).

## Prompt Fetch Map

| Slice prefix | Read |
| --- | --- |
| `11a.*` | substrate accepted; archived plan at `docs/archive/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`; live decision register at `phase_11a/phase_11a_decision_register.md` |
| `11A.*` | `phase_11A_operations_console/phase_11A_operations_console_plan.md` |
| `cutover.*` | `phase_production_cutover/phase_production_cutover_plan.md` (+ scalability decisions for `0a`; perf audit for `0b`) |
| `9.0Σ.*`, `9.live-closeout`, `9.0-9.10` | `phase_9/phase_9_auth_plan.md` + `phase_9_execution_backlog.md` |
| `7.61` / `10.5` (both closed) | archived at `docs/archive/phases/phase_7_61/` and `docs/archive/phases/phase_10_5/`; carry-forward items live in `phase_production_cutover_plan.md` |
| `9.8`, `10a`/`10b`, `9.5`/`9.75`, `7.58`, `8`/`8R`/`8.S`/`8.5`, `11b*`, `11W*`, `12.*` | that phase's doc under `docs/phases/**` (`8` POS, `8R` reservations, `8.S` scheduling, `8.5` outbound finance, `11W` operator web console) |

## North Star

POS + Labor + Reservation → Canonical Operational Facts → 60-Day
Benchmark Snapshot → TargetCycle + DemandForecastContext →
SchedulePlan → WeeklyPlanSnapshot → Shift → Variance → History → Learn.

## Phase Board

Accepted phases retire to `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.

| Phase | Status | Plan |
| --- | --- | --- |
| `9` framework + `9.0Σ.b-l` + `9.UX.*` | accepted on master + applied to staging; phase 9 stays open until `9.8` lands | `phase_9/*` |
| `7.58` | `.0`/`.5`/`.UX.5` accepted; `.1`/`.2`/`.3`/`.4` queued; zero DRIFT | `phase_7_58/*` |
| `7.61` (closed) | all 4 non-deferred slices accepted; F-A → `cutover.0b`, F-B post-`cutover.5` no owner | `docs/archive/phases/phase_7_61/` |
| `10.5` (closed) | all 4 slices (`.0`/`.1`/`.2`/`.3`) accepted | `docs/archive/phases/phase_10_5/` |
| `10a` | `.0`/`.1` + `UX.0`/`UX.1` accepted; `.2` dead-letter, `.3` retention sweep, `.4` tripwires, `.5` last_event_id replay queued | `phase_10a/*` |
| `9.5` | `.0` backend (schema + RLS) accepted; `.UX.*` **paused (Barrio)** per 2026-05-03 operator direction; Recognition/Operations El Podio later | `phase_9_5/*` |
| `11A` foundation | `0`–`5`/`6`/`7`/`UX.health` accepted; B44/B45/B47 producers delivered; `8`/`9`/`10` not started; cross-operator parity (`11A.12`/`13`/`14`) deferred per V1 lean cut until 20+ operators justify it | `phase_11A_operations_console/*` |
| `11W` Operator Web Console (NEW) | `11W.0` shell + onboarding accepted on master 2026-05-03 (PR #87); `11W.7` Account + `11W.8` Vendor connections mount queued; remaining 7 slices (Members/Roles/Hierarchy/Sessions/Audit/Security/Outbound) deferred per `project_v1_lean_scope_cut.md` | `phase_11W/*` |
| `9.75` | **paused (Barrio)** per 2026-05-03 operator direction (Barrio Staff Daily Companion frozen until unfreeze) | `phase_9_75/*` |
| `8` (POS) | `8.0` framework + master-side hardening accepted on master 2026-05-03 (PR #90 + `4f2dc85`); 7 POS adapters queued in Wave B (engineer-all-17 doctrine). **Closes as engineering-complete when Wave B lands.** Lifecycle rollout in `phase_8_live_rollout/`. | `phase_8/*` + `vendor_master_list.md` + `vendor_connections_admin_surface.md` |
| `8R` (Reservations) | queued — 4 reservation adapters in Wave B; Resy uncovered (15% market gap). **Closes as engineering-complete when Wave B lands.** Lifecycle rollout in `phase_8_live_rollout/`. | `phase_8R/*` |
| `8.S` (Scheduling) | queued — 6 scheduling adapters in Wave B; ADP/QuickBooks module disambiguation at connect. **Closes as engineering-complete when Wave B lands.** Lifecycle rollout in `phase_8_live_rollout/`. | `phase_8S/*` |
| `8.live` (Vendor lifecycle rollout) | open — rolling. Tracks 17 `*.live.sandbox` + 17 `*.live.prod` slices that promote lifecycle as credentials arrive. Closes when last vendor reaches `production_credentialed` (Resy permanently abandoned per partnership_status). | `phase_8_live_rollout/phase_8_live_rollout_plan.md` |
| `8.5` (Outbound finance) | **paused (outward-vendor focus pivot 2026-05-03)** — QBO Accounting/Xero/Bill.com/Plaid; sibling lane to 8/8R/8.S; resumes after inbound integration push | `phase_8_5_external_integrations/*` |
| `11b`/`11b.1`/`11b.2` | **paused (AI focus pivot 2026-05-03)** — operator-facing advisor; gated on B43 prod anchor; resumes post-pause | `phase_11b/*` |
| `12.0`–`12.5` | **paused (AI focus pivot 2026-05-03)** — workflow platform AI-driven; gated by B41 live apply; resumes post-pause | `phase_12_workflow_platform/*` |
| `9.8` | `9.8.email` (SendGrid transactional email pipeline + 8 templates) accepted on master 2026-05-03 (PR #88); **inbound-vendor T&Cs portion in scope** (operator authorization for POS/Reservation/Scheduling data); **advisor + outbound T&Cs paused** | `phase_9_8/*` |
| `10a` (cont.) | `10a.2` event-outbox dead-letter cap + transactional MOVE + `/health` depth metric accepted on master 2026-05-03 (PR #89); operator-facing DLQ tile correctly absent per V1 lean cut 2 | `phase_10a/*` |
| `11A.3` + `11A.3.x` (corpus / Graphify) | **paused (AI focus pivot 2026-05-03)** — corpus management + Graphify-assisted review are AI input; resumes post-pause | `phase_11A_operations_console/*` |
| `11A.11` (replay tool) | **paused (AI focus pivot 2026-05-03)** — advisor debug tooling; resumes post-pause | `phase_11A_operations_console/*` |
| `11W.9` (outbound mount) | **paused** — depends on paused Phase 8.5; resumes post-pause | `phase_11W/*` |
| `10b` | **paused (AI focus pivot 2026-05-03)** — advanced realtime / advisor-adjacent; resumes post-pause | n/a |
| `cutover.0b` | queued — Tier-M perf gate; needs `cutover.1` corpus seed first; absorbs `7.61.4` (F-A) | `phase_production_cutover/*` |
| `cutover.1` | queued — production corpus load generates the `0b` seed/harness | same plan |
| `cutover.2`–`5` | queued (post-`0b`) | same plan |

## Active Lanes

Codex on master; Claude in `.claude/worktrees/<lane>`. Multiple phases
may run in parallel. Rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
"Parallel Worktrees". Phase Board above is canonical state; the list
below is sequencing intent.

Wave B builds all Phase 8 / 8R / 8.S documented adapters in one push. 20
file-disjoint parallel lanes, followed by the `8.integration-mobile-proof`
closeout gate before product-complete engineering acceptance. Locked
2026-05-03 per
`memory/project_phase_8_engineer_all_17_doctrine.md`. Authority for
grading every adapter slice: `docs/contracts/vendor_adapter_slice_contract.md`
+ `docs/contracts/per_vendor_doc_pack_contract.md`. Wave plan rows:
`docs/phases/phase_8/vendor_master_list.md` "Wave B".

**Wave B — engineer all 17 vendors at lifecycle = `documented` + Web Console:**

1. **`8.0.lifecycle`** — micro-amendment: replace
   `partnershipGated: bool` with `lifecycle: VendorLifecycle` enum on
   `VendorCapabilityProfile`. Ships first; other lanes consume.
2. **POS (7 lanes)** — `8.LSK` (reference), `8.SQ`, `8.TS`, `8.CL`,
   `8.RV`, `8.AL`, `8.OR`. Each ships
   `lib/integrations/pos/<vendor>_pos_adapter.dart` NEW +
   `docs/integrations/<vendor_id>/` (6-file doc pack) + tests +
   walkthrough.
3. **Reservations (4 lanes)** — `8R.LB` (reference), `8R.OT`,
   `8R.SR`, `8R.TC`. Same shape under
   `lib/integrations/reservation/`.
4. **Scheduling (6 lanes)** — `8.S.QBT` (reference), `8.S.7S`,
   `8.S.ADP` (module disambiguation), `8.S.HM`, `8.S.AG`, `8.S.PU`.
   Same shape under `lib/integrations/labor/`.
5. **`11W.7`** — Operator Web Account screen replaces placeholder.
   File-disjoint from adapter lanes.
6. **`11W.8`** — Operator Web Vendor Connections mount. Reuses the
   `VendorConnectionsWidget` already in `8.0`. File-disjoint.

Total: 20 lanes. Shared seam (adapter registry under
`tool/advisor_proxy/`) handled by 3 category-scoped registry files
updated on a single integration commit after worktrees merge.

**Wave B closeout gate - `8.integration-mobile-proof`:**

- Runs immediately after the 20 Wave B lanes and adapter registry merge.
- Reads `docs/_execution/2026-05-04_vendor_api_access_and_mobile_e2e_gap.md`.
- Proof-only lane: do not change app logic, business logic, mobile UI, adapter
  behavior, schema, migrations, or cloud/runtime behavior. Allowed changes are
  limited to fixtures, test harnesses, and evidence/docs. If a product gap is
  found, record it and create a follow-up slice instead of fixing it here.
- Uses realistic POS + reservation + labor fixtures through real adapters,
  canonical fact writes, and real mobile/business read paths.
- Proves Shift, benchmark/baseline inputs, DemandForecastContext, SchedulePlan,
  Variance provenance, History, Learn, refresh/cache, and demo-mode behavior.
- Acceptance requires no phantom zeros; missing facts must show fallback or
  unavailable, and History/Learn must consume only closed trustworthy facts.
- This gate can run before live vendor accounts. `8.live.connected-device-smoke`
  follows after full setup and real credentials/device are ready.

**Wave D — rolling `*.live.*` slices (fire as credentials arrive):**

- Per vendor: `<vendor_id>.live.sandbox` (~200 LOC + walkthrough,
  promotes lifecycle to `sandbox_verified`) and `<vendor_id>.live.prod`
  (~200 LOC + walkthrough, promotes to `production_credentialed`).
- Wave D never sprints; each slice fires individually when a credential
  arrives. Order is whichever credential lands first.

**Operator parallel critical path (no engineering):** sandbox
provisioning across 17 vendors; DNS+TLS for `app.forgeflow.app` +
`mail.forgeflow.app`; SendGrid account + DKIM/SPF/DMARC; partnership
applications kickoff (Toast / OpenTable / Oracle / NCR Voyix / ADP
Marketplace / SevenRooms / Tock / Push Operations); legal review of
inbound-vendor T&Cs draft; Production1 unfreeze decision. None blocks
Wave B engineering — `*.live.prod` slices fire when each credential
arrives.

**After Wave B lands:** do not declare Phase 8 / 8R / 8.S accepted until
`8.integration-mobile-proof` passes and records evidence. After that closeout
gate, open work moves to `8.live.connected-device-smoke`, rolling
`*.live.sandbox` / `*.live.prod` slices, `cutover.0b` Tier-M perf gate (needs
`cutover.1` corpus seed first), Phase 11A `8`/`9`/`10`, and post-pause
AI/outward/Barrio when unfrozen.

**Barrio-paused (skip until unfreeze):** `9.5.UX.*`, `9.75`.

**AI/outward-vendor-paused (skip until unfreeze):** `11b`/`.1`/`.2`,
`12.*`, `11A.3`/`.3.x`, `11A.11`, `8.5`, `11W.9`, `10b`, `9.8` AI
portion. See `project_phase_pause_2026_05_03.md` for full list.

Then queued (in-scope, sequencing intent):
`10a.3`/`.4`/`.5`, `7.58.1`/`.2`/`.3`/`.4`, Phase 8 Waves
2-5 (`vendor_master_list.md`), Phase 11W Waves B/C (deferred per V1
lean cut), Phase 11A `10`, `9.8` inbound-vendor T&Cs (legal review
gates), `cutover.0b`–`5`.

## Hard Gates

- All `7.58.*` accept before `11b.0`. (Driver-key Phase-8 gate satisfied.)
- `cutover.0b` Tier-M perf gate is launch-blocking; needs `cutover.1`
  corpus seed first.
- Production migrations use online-migration patterns once real operator
  data exists; transition at `cutover.4`.
- Migration changes:
  `dart run tool/migration_drift_scanner.dart --fix --strict-docs`, then
  `dart run tool/migration_cutoff_lint.dart`.
- Runtime-exposed slices satisfy
  `docs/contracts/slice_runtime_acceptance_contract.md`. Browser-exposed
  slices use Browser Use evidence per
  `runbooks/browser_use_acceptance_harness_runbook.md` and full mobile/web
  console E2E passes use `docs/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md`.
- Before staging console perf claims:
  `dart run tool/perf_gate/staging_console_probe.dart --run --admin-url=<url> --proxy-url=<url>`
  and attach JSON output. `--enforce-budgets` for PR/release gates;
  `--include-health` only for deliberate, bounded health probes.
- 35 scalability locks (`phase_9_scalability_decisions_2026-04-27.md`)
  authoritative; 10 Hard Promises in `CLAUDE.md` durable.

## Notes

2026-05-04 vendor API access / product-proof addendum:

- Primary research and Oracle payment-orchestrator evidence are preserved in
  `docs/_execution/2026-05-04_vendor_api_access_and_mobile_e2e_gap.md`.
- The 20 Wave B lanes prove documented adapter implementation. They do not, by
  themselves, prove the full mobile product spine.
- Required next prompt after Wave B: `8.integration-mobile-proof` using
  contract fixtures through real adapters and real mobile/business read paths.
- Required live prompt after full setup: `8.live.connected-device-smoke` using
  one complete POS + reservation + labor trio on a connected device before
  expanding to all 17 vendors.
- Both prompts are proof-only: no app logic changes. They may add fixtures,
  tests, harness glue, and evidence docs only.

- `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` is the
  canonical private env loader (outside repo, never commit).
- If a prompt requires a key, account, cloud project, billing setup,
  or infrastructure choice, surface it in Block 1.
