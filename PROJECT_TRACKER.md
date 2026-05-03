# Forge & Flow Project Tracker

Updated: 2026-05-03
Owner: You · Execution: We think, Claude codes

Routing map only. Slice scopes live in their phase docs.

## Now

- **Latest sprint accepted (PRs #80-83 + standalone commits, 2026-05-03)**:
  `10.5.3` daypart-live primary-driver chip (closes Phase 10.5),
  `9.5.0` El Podio leaderboard schema + RLS skeleton (opens Phase 9.5),
  `10a.1` Cloud Pub/Sub publisher adapter (#1 of 5 queued 10a
  follow-ups). Plus `d46329a` admin/settings UI relabel, `b82c933`
  migration-policy replay safety, `ae6cb77` Debug Console request-log
  read grant migration, `caacffb` Production1 migration apply record,
  `7d33eae` performance framework doc. Walkthroughs at
  `docs/_walkthroughs/10.5.3.md` / `9.5.0.md` / `10a.1.md`.
- **Phase 10.5 closed; phase doc archived** at
  `docs/archive/phases/phase_10_5/phase_10_5_shift_daypart_service_period_view_and_primary_driver.md`.
  All 4 slices (`.0`/`.1`/`.2`/`.3`) accepted.
- **Phase 7.61 closed; audit plan archived** at
  `docs/archive/phases/phase_7_61/phase_7_61_audit_plan.md`. All
  non-deferred slices (`.0`/`.1`/`.2`/`.3`) accepted; F-A carried into
  `cutover.0b` per cutover plan; F-B (no owner) carried
  post-`cutover.5`. Driver-key contract
  `docs/contracts/phase_7_61_driver_key_contract.md` stays active.
- **2026-05-03 staging runtime/perf remediation** captured in
  `docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`;
  durable rules in
  `docs/contracts/slice_runtime_acceptance_contract.md`. Authenticated
  screen/action timing still needs explicit credential-send approval.
- **`cutover.0a` + `cutover.0a.pg` complete (2026-05-01)**. Production1
  Postgres on CMK. The 27-file Production1 migration batch
  (`202604280014` through `202605021900`) was applied and verified on
  2026-05-03; `cutover.1` repeats verification before corpus load.
- **Post-cutoff staging migration addition**:
  `202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql`
  is a Debug Console `forge_admin` request-log read grant. Applied +
  Browser Use verified on staging; pending Production1 apply.
- **Production1 GCP/Firebase/proxy/DNS setup paused** per operator
  direction 2026-05-03. Project/Firebase shell exists; runtime needs
  Firebase apps/configs, runtime APIs, deploy SA, static egress, DNS,
  Secret Manager namespace, Azure firewall allowlist. Staging-parity
  baseline:
  `docs/phases/phase_production_cutover/production1_staging_parity_baseline_2026-05-03.md`.
- **Cloud Armor**: preview-only at sensitivity 2; awaits ≥3 clean
  post-tuning days + approval before enforcement.
- **iOS physical device matrix** deferred until Apple device/signing
  lane returns. Automated GitHub Actions iOS sim builds green on master.
- **Barrio paused (2026-05-03 operator direction)**: only Forge & Flow
  flavor (`lib/main_forgeflow.dart`) is in scope for current and upcoming
  sprints. Skip lanes touching `lib/internal/barrio/**`,
  `lib/main_barrio.dart`, Phase 9.75, and `9.5.UX.*`. Phase 9.5 backend
  (Postgres schema, RLS, repository) is general-purpose and stays in scope.
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
| `9.8`, `10a`/`10b`, `9.5`/`9.75`, `7.58`, `8`/`8R`/`8.5`, `11b*`, `12.*` | that phase's doc under `docs/phases/**` |

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
| `11A` foundation | `0`–`5`/`6`/`7`/`UX.health` accepted; B44/B45/B47 producers delivered; `8`/`9`/`10` not started | `phase_11A_operations_console/*` |
| `9.75` | **paused (Barrio)** per 2026-05-03 operator direction (Barrio Staff Daily Companion frozen until unfreeze) | `phase_9_75/*` |
| `8`, `8R`, `8.5` | queued | their respective plans |
| `11b`/`11b.1`/`11b.2` | queued (gated on B43 prod anchor) | `phase_11b/*` |
| `12.0`–`12.5` | queued (gated by B41 live apply) | `phase_12_workflow_platform/*` |
| `9.8` | queued (launch-blocking; sequenced after auth + vendor contracts) | `phase_9_8/*` |
| `cutover.0b` | queued — Tier-M perf gate; needs `cutover.1` corpus seed first; absorbs `7.61.4` (F-A) | `phase_production_cutover/*` |
| `cutover.1` | queued — production corpus load generates the `0b` seed/harness | same plan |
| `cutover.2`–`5` | queued (post-`0b`) | same plan |

## Active Lanes

Codex on master; Claude in `.claude/worktrees/<lane>`. Multiple phases
may run in parallel. Rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
"Parallel Worktrees". Phase Board above is canonical state; the list
below is sequencing intent.

Next candidates by readiness:

1. **Production1 Debug Console grant follow-up** — apply
   `202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql`
   after the usual live-mutation gate; staging applied/verified.
2. **Production1 GCP/Firebase/proxy/DNS setup** — paused; substantial
   unblock list (see Now).
3. **B43 Production1 anchor deploy** — needs production runtime APIs +
   Secret Manager namespace + static egress + Azure audit-anchor secrets.
4. **`10a.2` dead-letter cap** — bridge worker moves rows whose
   `attempt_count` exceeds tunable cap to `event_outbox_dead_letter`;
   counter surfaces in 11A.6 envelope.
5. **`7.58.5` Variance row purity (G.5)** — drop daypart carry-forward
   inheritance in `variance_week_projection_read_service.dart` so
   open/projected rows return `'on_model'` rather than the prior closed
   daypart's id.
6. **Phase 8 (`8.0` POS adapter scaffold)** — driver-key gate satisfied;
   stub adapter + Settings → Integrations card tractable now; vendor
   (Toast) sandbox creds blocker only for live transport.

**Barrio-paused (skip until unfreeze):** `9.5.UX.*`, `9.75`.

Then queued: `10a.3`/`.4`/`.5`, `7.58.1`/`.2`/`.3`/`.4`, `8R`, `8.5`,
`11b`/`.1`/`.2`, `12.*`, `9.8`, `cutover.0b`–`5`.

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
  `runbooks/browser_use_acceptance_harness_runbook.md`.
- Before staging console perf claims:
  `dart run tool/perf_gate/staging_console_probe.dart --run --admin-url=<url> --proxy-url=<url>`
  and attach JSON output. `--enforce-budgets` for PR/release gates;
  `--include-health` only for deliberate, bounded health probes.
- 35 scalability locks (`phase_9_scalability_decisions_2026-04-27.md`)
  authoritative; 10 Hard Promises in `CLAUDE.md` durable.

## Notes

- `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` is the
  canonical private env loader (outside repo, never commit).
- If a prompt requires a key, account, cloud project, billing setup,
  or infrastructure choice, surface it in Block 1.
