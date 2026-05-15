# Per-Daypart Targets V1 — Main Orchestrator Brief

> **Self-persisted brief for the main orchestrator session (this Claude).**
> Reads the canonical plan and execution context cold so a fresh session can pick up without losing state. Paired with `PER_DAYPART_V1_CLAUDE2_HANDOFF.md` (the Claude 2 paste-ready prompt).

## Identity

You are the **main orchestrator** for Per-Daypart Targets V1 implementation. You plan, dispatch worker agents, audit returning PRs, merge clean work, surface operator-decision findings. You do not write production code directly except for tracker / coordination / audit doc edits on master.

## Canonical references (read in this order)

1. `CLAUDE.md` — workflow, authority order, hard promises, design rules.
2. `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` — the locked plan; 14 decisions; 9 slices; 44 gaps consolidated; reusable surface-coverage audit method appended.
3. `docs/_indices/NEXT_WAVE_PLAN.md` — Phase 2.5 captures this work in the forward pipeline.
4. `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/session_handoff.md` — current cursor.
5. `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/project_per_daypart_targets_v1.md` — one-line summary + open decisions.

## Slice sequence + ownership

| Slice | Owner | Status | Notes |
|---|---|---|---|
| 0 — Cycle rollover gating + contract amendments | **Main** | ✅ MERGED #761 (`1460d45d`) | No schema change. Touched `TargetCyclePolicy`, `target_cycle_service.dart`, 3 contract docs. |
| 1 — Per-period data layer foundation | **Main** | ⏸ PARKED for operator merge approval — PR #767 (`claude/per-daypart-slice-1-per-period-data-foundation`). Pattern B audit CLEAN — see `docs/_audits/per_daypart_v1/slice_1_per_period_data_foundation_orchestrator_review.md`. Schema-touching → CLAUDE.md operator-gate. | SQLite V36 + Postgres `202605160000` migration; 32 files; pool consistency + Gap 42 fallback + Gap 23 carry verified. |
| 1.5 — Closed-shift aggregator → DaypartBucketer routing | **Main** | ✅ MERGED #763 (`d392d4d1`) | Late-night regression test ✅ MERGED #768 (`6e843798`). |
| 2 — Benchmark tab redesign | **Main** | UNBLOCKED (Gap 35 + 36 resolved). Waiting on Slice 1 merge. | Daypart Breakdown swap (avg→target + Avg Covers stays + OPZ single column) + card cut + strip rehome. |
| 2.5 — Service period editor field completeness | **Claude 2** | ✅ MERGED #762 (`4e2a6c94`) | `applicableDays` + `shortLabel` + `sortOrder` landed. |
| 3 — Plan tab persistence wiring | **Main or Claude 2** | Waiting on Slice 1 merge. | Allocator retirement + sub-row read swap + `schedule_builder` sentinel-0 cleanup. |
| 4 — Shift daypart card full parity | **Claude 2** preferred | Waiting on Slice 1 merge. | UX overhaul: Outputs + Inputs + FOH Productivity per period. |
| 5 — Variance read-seam swap | **Main or Claude 2** | Waiting on Slice 1 merge. | Small read swap. |
| 6 — Audit scorer extension | **Main** | Waiting on Slice 1 merge. | Per-period check shapes + pool-consistency + wage-at-lock-time + structural ordering bug fix. |
| 7a — Tock reservation business_date | **Claude 2** | ✅ MERGED #766 (`baa4047a`) | Gap 45 closed via `IanaTimezoneConverter`. |
| 7b — Sub-hour business-day cutoff precision (Gap 46+47) | **Claude 2** | RESOLVED — operator chose option (b) proper fix (sink-side `BusinessDateResolver`). Claude 2 implementing + handling doc merges. | Orchestrator defaults handed to Claude 2: (b1) keep SQL trigger as legacy backup; converge 3 fallback cutoff hardcodes onto 4h. Operator may override on return. |

## Operator decisions queued

**All 4 prior gaps RESOLVED (locked in plan doc 29ad4c8d + 686d8b5d):**
- Gap 42 → option (c): empty `target_cycle_dayparts` + `MeridianConfig` whole-day fallback.
- Gap 31 → delete `shift_close_authority` entirely; auto-derive from per-vendor capability + business-day-start (absorbed into Slice 1.5).
- Gap 36 → kill legacy `covers_source_lunch/dinner/late_night` columns.
- Gap 35 → cut operator-web Benchmarks override surface entirely.

**Open operator decisions (parked during operator break 2026-05-15):**

1. **Slice 1 merge approval (schema-touching gate).** PR #767. Pattern B audit clean. Recommended: APPROVE — merge unlocks Slices 2/3/4/5/6 parallel dispatch.
2. ~~Slice 7b option choice~~ — RESOLVED. Operator chose option (b) proper fix; Claude 2 implementing + doc merges. Orchestrator defaults handed down: (b1) keep SQL trigger as legacy backup; converge 3 fallback cutoff hardcodes onto 4h. Operator may override either on return — not blocking.

**Net: the ONLY operator decision blocking forward progress is #1 (Slice 1 merge approval).**

## Dispatch transport (NEW STANDARD 2026-05-15 — testing)

Worker execution moves off the orchestrator's interactive subscription onto the Agent SDK / `claude -p` $200/mo credit. Orchestrator stays interactive. Two transports, same contract:
- **Headless (preferred for slice workers):** `scripts/dispatch_worker.ps1 -Branch <b> -PromptFile <f>` launches a fully-autonomous `claude -p` process in an isolated worktree, logs to `.claude/worker-logs/<leaf>.log`. Poll `gh pr list --head <b>` for the returning PR. v1 flags are a first guess — tune on real runs.
- **Agent tool (fallback / quick research):** in-session sub-agent, draws subscription. Use when headless proves flaky or for short audits the orchestrator needs results from before proceeding.
- Rationale + open test questions: user memory `feedback_agent_sdk_credit_dispatch.md`.

## Dispatch contract (every worker agent)

- `isolation: "worktree"` — agents run in `.claude/worktrees/<lane>-<hash>/`.
- Branch prefix: `claude/per-daypart-slice-<N>-<topic>` (this orchestrator's agents).
- First action in the worker prompt: `pwsh scripts/install_git_hooks.ps1` (canonical hooks; otherwise push stalls on stale heavy hook).
- Contract: **branch → implement → self-audit → commit + push → open PR → STOP**. Worker does NOT merge, does NOT bypass hooks (`--no-verify` banned), does NOT update trackers.
- Worker self-audit: Pattern B exemplar table in PR body with file:line citations covering 14 audit lenses per `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.
- Worker writes audit doc to `docs/_audits/per_daypart_v1/pr_<n>_<topic>.md` as part of the PR.

## Orchestrator workflow per returning PR

1. **Pull PR diff + audit doc.** Compare against the plan doc's slice scope.
2. **Independent audit** — verify Pattern B claims with own file:line checks. Flag any:
   - Scope drift (touched files outside the slice's named paths)
   - Hardcodes or sentinels (especially `0`-as-null violations of Design Rule 2)
   - Missing per-period iteration where the plan requires it
   - Whole-day field reuse where per-period names are required (Design Rule 1)
   - Bypass of canonical write path (Design Rule 4)
3. **Verdict:** approve-for-merge / fix-inline / send-back-with-findings.
4. **Operator-approval slices** (Slice 0, 1, 1.5, 2): ping operator with one-paragraph summary + verdict + audit doc link. Do NOT auto-merge.
5. **Auto-merge slices** (Slice 2.5, 3, 4, 5, 6 if non-controversial): merge on clean audit.
6. **Post-merge:** flip status in this brief; update `session_handoff.md`; emit next slice's prompt if dependencies are clear.

## Concurrency rules (with Claude 2)

- Main owns: `lib/services/target_cycle_service.dart`, `lib/services/integration/canonical_fact_to_closed_shift_input.dart`, `lib/services/shift_service.dart`, contract docs under `docs/contracts/`, `target_cycle_dayparts` migrations.
- Claude 2 owns: `lib/operator_web/widgets/service_period_editor.dart`, `lib/operator_web/screens/business_timing_editor_screen.dart`, related operator-web tests.
- Shared docs (plan doc, brief, ledger): both lanes annotate own slice rows inline; never overwrite the other lane's annotations. Status board sections per lane.
- Coordination via Git only — no real-time channel.

## Active work (2026-05-15 — operator on break, autonomous mode)

**Merged in current wave** (chronological): Slice 0 (#761) → Slice 2.5 (#762) → Slice 1.5 (#763) → architecture-verification audit (#764) → Slice 7a Tock (#766) → Slice 1.5 regression test (#768) → Slice 7b research doc (#765).

**Awaiting operator return:**
1. **Slice 1 merge approval** — PR #767, schema-touching gate. SOLE blocker.

**In flight (Claude 2):** Slice 7b option (b) proper fix + doc merges.

**Dispatchable on Slice 1 merge** (one-shot parallel wave):
- Slices 2 / 3 / 5 / 6 → Main parallel workers
- Slice 4 → Claude 2

Pre-staged worker prompts: `docs/_indices/PER_DAYPART_V1_POST_SLICE1_DISPATCH.md` (populated on first dispatch).

## Stop conditions

- Stop dispatching new slices when: 2+ PRs awaiting orchestrator audit, OR 2+ operator-gated PRs awaiting operator approval, OR an operator decision is pending that affects multiple queued slices.
- Stop the whole orchestration if: contract amendment in Slice 0 produces a conflict the operator hasn't reviewed, OR an audit surface gap exceeds 5-LoC inline fix scope (treat as a new slice).
