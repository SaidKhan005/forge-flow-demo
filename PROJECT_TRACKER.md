# Forge & Flow Project Tracker

Updated: 2026-05-03
Owner: You · Execution: We think, Claude codes

This is a routing map, not the full plan. Slice scopes live in their phase doc.

## Now

- **Active**: `10.5.0` daypart toggle scaffold + `10.5.1` bucketing
  engine accepted (worktree `.claude/worktrees/gracious-rosalind-19b985`,
  branch `claude/gracious-rosalind-19b985`). 10.5.0 surface-only seam:
  segmented Whole Day | Daypart pills above SHIFT OUTPUTS, daypart lens
  renders SERVICE PERIODS scaffold (Lunch/Dinner/Late Night cards from
  `demoDefinitions`) with live ACTIVE NOW chip; whole-day stays default
  + authoritative. 10.5.1 pure-function `DaypartBucketer`
  (POS / labor punch with split / reservation) consumes
  `ServicePeriodDefinitionResolver` + `BusinessDateResolver`; 16
  domain tests cover the punch-split worked example with a
  non-service gap, the 15:00 inclusive-end tie-break, the Late Night
  02:00 Sun-calendar → Sat business-date roll-over, and the
  missing-IANA-tz `MissingTimezoneError` posture. Per-period read
  service + primary-driver teaching queued. Walkthroughs at
  `docs/_walkthroughs/10.5.0.md` + `docs/_walkthroughs/10.5.1.md`.
- 11A Operations Console foundation now spans `11A.0`–`4c`/`7`/`UX.health`
  accepted; `11A.5`/`11A.6` blocked on B45/B47 producers (B44 graph producers
  delivered — see `docs/_walkthroughs/B44.md`).
- **Live staging console remediation (2026-05-03 branch)**: Corpus -> Graph
  candidates 503 is fixed in branch by shipping sanitized candidate artifacts
  with the advisor proxy image at `/app/graphify-out/candidates`.
  `audit_chain_lag_seconds` was not future UI/backend wiring; after
  action-time approval, staging Cloud Run execution
  `forge-flow-audit-anchor-zmsvj` anchored the 2026-05-02 chain and `/health`
  now reports that metric green. Overall staging health remains yellow due to
  other producer/ops-data signals outside this branch's two requested fixes.
- **Staging console performance guardrail (2026-05-03, PR #68)**:
  branch `codex/staging-perf-audit` measured the real staging console and
  proxy, not a mock replacement. Tested admin URL:
  `https://forge-flow-admin-console-rf7nosnoka-pd.a.run.app`
  (`forge-flow-admin-console-00003-shn`, image tag `20260503025703`);
  local browser-served audit URL: `http://127.0.0.1:7362/?audit=after`;
  proxy URL: `https://forge-flow-staging-proxy-rf7nosnoka-pd.a.run.app`
  (`forge-flow-staging-proxy-00051-7x5`, digest
  `sha256:f4dbd6c7a95c1efeb74322c8ae65655341e762dabb96244d1b037de02cecc668`).
  Baseline -> after kept the same UX while deferring the Graph candidates
  fetch until that tab is visited and preventing overlapping `/health` polls.
  Safe staging load results: admin index c4 p95 `330.4ms`; gzip
  `main.dart.js` c4 p95 `978.9ms` (995,111 byte gzip transfer by `curl`);
  proxy `/readyz` c4 p95 `171.3ms`; proxy `/health` was intentionally not
  escalated after c1/c2 showed real instability/timeouts
  (c1 p50 `14575.6ms`, 60% non-green; c2 p50 `20479.4ms`, 83.3%
  non-green). New repeatable script:
  `dart run tool/perf_gate/staging_console_probe.dart --run --admin-url=<url> --proxy-url=<url>`;
  add `--enforce-budgets` in release checks to fail on current starting
  guardrails (admin index p95 <= 750ms, `main.dart.js` gzip p95 <= 1500ms
  and <= 1.25MB transfer, proxy `/readyz` p95 <= 500ms). Script verification
  at `2026-05-03T03:20:29Z` passed those budgets: admin index c4 p95
  `308.7ms`, `main.dart.js` gzip c4 p95 `779.7ms` / `995111` bytes, proxy
  `/readyz` c4 p95 `181.1ms`, 0% error rate on default probes.
  Authenticated screen/action timing remains pending explicit credential-send
  approval in the in-app browser.
- **Recently accepted (2026-05-02 sprint, PRs #50–54)**: `7.58.0` Primary
  Driver contract pin (test-only, 22 assertions / 12 fixtures, 31 of 32 rules
  MET, F-1 deferred to 7.58.UX.5); `11A.3a` operator-picker (Graph candidates
  commit unblocked); `9.0Σ.l` RLS depth on `proxy_requests` + `feature_flags`
  (wrapper-based policies, migration `202605021500`); admin gateway
  idempotency-key parcel (operator/pricing/integration + proxy
  `_runAdminIdempotent`); MFA test parcel (4 files, 45 tests,
  `lib/services/mfa/` 87.3% coverage).
- **Recently accepted (2026-05-02 follow-up)**: `7.58.UX.5` Variance day-row
  renderer honesty (F-1 / F-6 / F-7 closed). `LeverCards.lookup` helper +
  `LeverCardNotYetAvailable` widget; 8 renderer sites migrated off the silent
  `coversDown` fall-through; closed-row `_driverLabel` lowercased; inline
  `_LeverBadge` switched to `LeverCardData.metric` copy. Contract test stays
  green (22/22); regression suite 181/181. Phase 7.58 has zero DRIFT.
- **Recently accepted (2026-05-02 evening, PRs #60-66)**: `10.5.1`
  bucketing engine, `7.61.0` driver-key audit, `10a.0` realtime scaffold,
  B44 graph health producer family, postgres repository test batch 2, admin
  MFA challenge parity, and staging admin console stabilization. Follow-up
  migration queue now extends through `202605021900`.
- **Earlier 2026-05-02 batch**: `HARD-A`–`HARD-H` hardening (PRs #41–49);
  `11A.3b`, `11A.4`/`4b`/`4c`, `11A.7`, `11A.UX.health`; `G.2` boundary
  monitor; `7.58.5` variance row purity. Hardening contracts `Status: Closed`
  in `docs/contracts/hardening_*.md`.
- **`cutover.0a` + `cutover.0a.pg` complete (2026-05-01)**. Production1
  Postgres on CMK (`forge-flow-production1-pg-cmk`). 32 baseline migrations
  applied (`202604250000`–`202604280013`); **27 newer pending Production1
  apply** (`202604280014`–`202605021900`) — see runbook +
  `docs/POST_HARDENING_FOLLOWUPS.md` P0.
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

## Prompt Fetch Map

| Slice prefix | Read |
| --- | --- |
| `11a.*` | `phase_11a/phase_11a_advisor_infrastructure_plan.md` (+ decision register if architecture/cost question) |
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
`docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Parallel Lanes".

Sprints PRs #50–66 closed (incl. `7.58.UX.5`, `10.5.0`, `10.5.1`,
`7.61.0`, `10a.0`, B44 graph producers, postgres repo + MFA adapter test
parcels, admin MFA challenge parity, staging admin stabilization, and the
runbook companion). Phase 7.58 is zero-DRIFT. Next candidates by readiness:

1. **Production1 migration apply event** — 27 migrations queued
   (`202604280014`–`202605021900`); runbook now refreshed.
   Operator-driven; no code change needed.
2. **B43 Production1 anchor deploy** — needs Production GCP project provisioning.
3. **`10a` realtime push channel** — Phase 10a NOTIFY → Pub/Sub → WebSocket.
4. **`10.5` follow-on slices** — `10.5.1` bucketing engine accepted; per-period
   read service (`10.5.2`) + primary-driver teaching (`10.5.3+`) next
   per phase doc.
5. **`7.61` pre-Phase-8 cleanup** — driver-key audit; gated before Phase 8.

**Then queued (rough order):** `11A.5`/`11A.6` (after B45/B47 producer
wiring; B44 graph producers already delivered), `9.5`, `9.75`, `8`/`8R`/`8.5`,
`11b`/`11b.1`/`11b.2`, `12.*`, `9.8`, `cutover.0b`–`0-5`.

## Phase Board

Accepted phases retire to `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.
Live board lists active + queued only.

| Phase | Status | Plan |
| --- | --- | --- |
| `11A` foundation | active; `0`–`4c`/`7`/`UX.health` accepted; `5`/`6`/`8`/`9`/`10` not started | `phase_11A_operations_console_plan.md` |
| `9` framework + `9.0Σ.b-l` + `9.UX.*` | accepted on master + applied to staging; phase 9 itself stays open until `9.8` lands; B41/B43/B44/B45/B46/B47/B48 are operational gates | `phase_9/*` |
| `7.58` | `7.58.0` + `7.58.5` + `7.58.UX.5` accepted; zero DRIFT. `7.58.1`/`.2`/`.3`/`.4` queued | `phase_7_58/*` |
| `10.5` | active; `10.5.0` daypart toggle scaffold + `10.5.1` bucketing engine accepted; per-period read service + driver teaching queued | `phase_10_5/*` |
| `7.61` | active; `7.61.0` audit pinned (contract + 21-active + 1-skipped-F-2-holdout test, zero catalog DRIFT); `.1`/`.2`/`.3` queued per findings F-1/F-2/F-3; `.4` deferred to `cutover.0b` (F-A); F-B (`shifts.primary_lever` lowercase migration) deferred post-`cutover.5` | `phase_7_61/*` |
| `10a` | active; `10a.0` realtime push channel scaffold (NOTIFY → claim → in-process publisher → WebSocket) — Pub/Sub adapter + dead-letter + retention sweep + tripwires + UX surfaces queued | `phase_10a/*` |
| `9.5`, `9.75`, `8`, `8R`, `8.5` | queued | their respective plans |
| `11b`/`11b.1`/`11b.2` | queued (gated on `11A.5`/`11A.6` + B43 prod anchor) | `phase_11b/*` |
| `12.0`–`12.5` | queued (gated by B41 live apply) | `phase_12_workflow_platform/*` |
| `9.8` | queued (launch-blocking; sequenced after auth + vendor contracts) | `phase_9_8/*` |
| `cutover.0b` | queued — Tier-M 14-row perf gate is the launch blocker | `phase_production_cutover/*` |
| `cutover.1`–`5` | queued (post-`0b`) | same plan |

## Hard Gates

- All `7.58.*` accept before `11b.0`; all `7.61.*` accept before Phase 8.
  `7.61.0` audit emitted no risky findings — F-1/F-2/F-3 are silent
  overclaim in the History/Learn analyzer + dev fixture (renderer-side,
  not key-shape); F-A is a deferred Postgres CHECK constraint; F-B is
  the deferred `shifts.primary_lever` lowercase migration (post-cutover.5,
  no slice owner).
- `cutover.0b` Tier-M perf gate is the launch blocker.
- Production migrations use online-migration patterns once real operator data
  exists; transition point is `cutover.4` accepting.
- After any slice adds `db/migrations/*.sql`, run
  `dart run tool/migration_drift_scanner.dart --fix --strict-docs` before
  tracker/runbook closeout. It updates the staging setup cutoff, emits
  `build/reports/migration_drift_report.md`, and flags authority docs that
  still need manual migration queue/count wording. `tool/migration_cutoff_lint.dart`
  remains the hard cutoff gate.
- Before future staging console performance claims, run
  `dart run tool/perf_gate/staging_console_probe.dart --run --admin-url=<url> --proxy-url=<url>`
  and attach the JSON output; use `--enforce-budgets` for PR/release gates.
  Use `--include-health` only for a deliberate, bounded health probe; do not
  mask red/yellow `/health` producer state as a frontend performance fix.
- 35 scalability locks (`phase_9_scalability_decisions_2026-04-27.md`) are
  authoritative; the 10 Hard Promises in `CLAUDE.md` are durable.

## Notes

- `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` is the canonical
  private env loader (outside repo, never commit).
- If a prompt requires a key, account, cloud project, billing setup, or
  infrastructure choice, surface it in Block 1 of the prompt.
