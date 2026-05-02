# Forge & Flow Project Tracker

Updated: 2026-05-02
Owner: You · Execution: We think, Claude codes

This is a routing map, not the full plan. Slice scopes live in their phase doc.

## Now

- **Active**: `10.5.0` daypart toggle scaffold on Shift dashboard
  (worktree `.claude/worktrees/trusting-greider-0f6f9d`, branch
  `claude/trusting-greider-0f6f9d`). Surface-only seam: segmented
  Whole Day | Daypart pills above SHIFT OUTPUTS, daypart lens
  renders SERVICE PERIODS scaffold (Lunch/Dinner/Late Night cards
  from `demoDefinitions`) with live ACTIVE NOW chip. Whole-day stays
  default + authoritative. Walkthrough at `docs/_walkthroughs/10.5.0.md`.
- 11A Operations Console foundation now spans `11A.0`–`4c`/`7`/`UX.health`
  accepted; `11A.5`/`11A.6` blocked on B44/B45/B47 producers.
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
- **Earlier 2026-05-02 batch**: `HARD-A`–`HARD-H` hardening (PRs #41–49);
  `11A.3b`, `11A.4`/`4b`/`4c`, `11A.7`, `11A.UX.health`; `G.2` boundary
  monitor; `7.58.5` variance row purity. Hardening contracts `Status: Closed`
  in `docs/contracts/hardening_*.md`.
- **`cutover.0a` + `cutover.0a.pg` complete (2026-05-01)**. Production1
  Postgres on CMK (`forge-flow-production1-pg-cmk`). 32 baseline migrations
  applied (`202604250000`–`202604280013`); **22 newer pending Production1
  apply** (`202604280014`–`202605021500`) — see runbook +
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

Sprint just closed (PRs #50–54); `10.5.0` (daypart toggle scaffold) now active
on `.claude/worktrees/trusting-greider-0f6f9d`. Remaining candidates by readiness:

1. **Production1 migration apply event** — 22 migrations queued
   (`202604280014`–`202605021500`); runbook `phase_9_production1_migration_apply_runbook.md`.
   Operator-driven; no code change needed.
2. **B43 Production1 anchor deploy** — needs Production GCP project provisioning.
3. **`10a` realtime push channel** — Phase 10a NOTIFY → Pub/Sub → WebSocket.
4. **`10.5` daypart projections** — Shift companion (per HP non-blocking ordering).
2. **`7.58.UX.5` F-1 fallthrough** — primary-driver audit deferral; UX surface,
   keep contract test green.
3. **B43 Production1 anchor deploy** — needs Production GCP project provisioning.
4. **`10a` realtime push channel** — Phase 10a NOTIFY → Pub/Sub → WebSocket.
5. **`10.5` follow-on slices** — daypart bucketing engine + per-period read
   service + primary-driver teaching (build sequence per phase doc).

**Then queued (rough order):** `11A.5`/`11A.6` (after B44/B45/B47 producer
wiring), `9.5`, `9.75`, `7.61`, `8`/`8R`/`8.5`, `11b`/`11b.1`/`11b.2`, `12.*`,
`9.8`, `cutover.0b`–`0-5`.

## Phase Board

Accepted phases retire to `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.
Live board lists active + queued only.

| Phase | Status | Plan |
| --- | --- | --- |
| `11A` foundation | active; `0`–`4c`/`7`/`UX.health` accepted; `5`/`6`/`8`/`9`/`10` not started | `phase_11A_operations_console_plan.md` |
| `9` framework + `9.0Σ.b-l` + `9.UX.*` | accepted on master + applied to staging; phase 9 itself stays open until `9.8` lands; B41/B43/B44/B45/B46/B47/B48 are operational gates | `phase_9/*` |
| `7.58` | `7.58.0` (contract pinned) + `7.58.5` + `7.58.UX.5` accepted; zero DRIFT. `7.58.1`/`.2`/`.3`/`.4` queued | `phase_7_58/*` |
| `7.61`, `10a`, `10.5`, `9.5`, `9.75`, `8`, `8R`, `8.5` | queued | their respective plans |
| `7.58` | `7.58.0` (contract pinned) + `7.58.5` accepted; `7.58.UX.5` queued (F-1 fallthrough) | `phase_7_58/*` |
| `10.5` | active; `10.5.0` daypart toggle scaffold landing on `.claude/worktrees/trusting-greider-0f6f9d` | `phase_10_5/*` |
| `7.61`, `10a`, `9.5`, `9.75`, `8`, `8R`, `8.5` | queued | their respective plans |
| `11b`/`11b.1`/`11b.2` | queued (gated on `11A.5`/`11A.6` + B43 prod anchor) | `phase_11b/*` |
| `12.0`–`12.5` | queued (gated by B41 live apply) | `phase_12_workflow_platform/*` |
| `9.8` | queued (launch-blocking; sequenced after auth + vendor contracts) | `phase_9_8/*` |
| `cutover.0b` | queued — Tier-M 14-row perf gate is the launch blocker | `phase_production_cutover/*` |
| `cutover.1`–`5` | queued (post-`0b`) | same plan |

## Hard Gates

- All `7.58.*` accept before `11b.0`; all `7.61.*` accept before Phase 8.
- `cutover.0b` Tier-M perf gate is the launch blocker.
- Production migrations use online-migration patterns once real operator data
  exists; transition point is `cutover.4` accepting.
- 35 scalability locks (`phase_9_scalability_decisions_2026-04-27.md`) are
  authoritative; the 10 Hard Promises in `CLAUDE.md` are durable.

## Notes

- `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` is the canonical
  private env loader (outside repo, never commit).
- If a prompt requires a key, account, cloud project, billing setup, or
  infrastructure choice, surface it in Block 1 of the prompt.
