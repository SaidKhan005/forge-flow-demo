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
| 0 — Cycle rollover gating + contract amendments | **Main** | dispatchable now | No schema change. Touches `TargetCyclePolicy`, `target_cycle_service.dart`, 3 contract docs. Auth-sensitive (contract amendment) → operator approves merge. |
| 1 — Per-period data layer foundation | **Main** | **BLOCKED on Gap 42 operator decision** | Schema + cycle-write path + demo reseed + `closeShift` timing-field carry. Auth/RLS-sensitive. |
| 1.5 — Closed-shift aggregator → DaypartBucketer routing | **Main** | dispatchable now | Must land before Slice 6. Replaces inline `_bucketsToDaypart` with `DaypartBucketer` + per-period accumulator + cross-(business-date) split + stage-4 fallback fix + 14-shifts hardcode removal. Integration-spine sensitive → operator approves. |
| 2 — Benchmark tab redesign | **Main** | BLOCKED on Gap 35 + Gap 36 operator decisions | Daypart Breakdown table redesign + card cut + strip rehome + 4 UI sites de-hardcoded + operator-web Benchmarks decision. |
| 2.5 — Service period editor field completeness | **Claude 2** | dispatchable now | `applicableDays`, `shortLabel`, `sortOrder` on `ServicePeriodDraft` + editor UI. Isolated operator-web work. |
| 3 — Plan tab persistence wiring | **Main or Claude 2** | depends on Slice 1 | Allocator retirement + sub-row read swap + `schedule_builder` sentinel-0 cleanup. |
| 4 — Shift daypart card full parity | **Claude 2** preferred | depends on Slice 1 | UX overhaul: Outputs + Inputs + FOH Productivity per period. Mostly UX work. |
| 5 — Variance read-seam swap | **Main or Claude 2** | depends on Slice 1 | Small read swap. |
| 6 — Audit scorer extension | **Main** | depends on Slices 1 + 1.5 | Per-period check shapes + pool-consistency + wage-at-lock-time + structural ordering bug fix. |

## Operator decisions queued (BLOCK relevant slices)

1. **Gap 42 — MeridianConfig insufficient-recommendation fallback shape.** Options: (a) widen `MeridianConfig` to per-period, (b) write all-periods-identical fallback rows, (c) leave `target_cycle_dayparts` empty + fall back to parent pool at read time. **Main recommendation: (c).** **BLOCKS Slice 1 dispatch.**
2. **Gap 31 — `shift_close_authority` operator-editability.** Either expose on operator-web business timing editor OR document as backend-only carve-out per HP #11. **Separate follow-up; does NOT block per-daypart V1.**
3. **Gap 36 — Legacy `covers_source_lunch/dinner/late_night` vs keyed `data_accuracy_service_period_settings` precedence.** **BLOCKS Slice 2 dispatch.**
4. **Gap 35 — Operator-web Benchmarks override write-seam decision.** Either make override per-period (mirror mobile Baseline Manager) or add copy explaining pool-write semantics. **BLOCKS Slice 2 dispatch.**

Slice 0 + Slice 1.5 + Slice 2.5 do not depend on any of these. Dispatch immediately.

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

## Active work (this session)

1. **Slice 0 worker dispatched** — see worker agent task.
2. **Slice 1.5 worker dispatched** — see worker agent task.
3. Awaiting operator decisions on Gaps 42, 35, 36 before Slice 1 + Slice 2 dispatches.

## Stop conditions

- Stop dispatching new slices when: 2+ PRs awaiting orchestrator audit, OR 2+ operator-gated PRs awaiting operator approval, OR an operator decision is pending that affects multiple queued slices.
- Stop the whole orchestration if: contract amendment in Slice 0 produces a conflict the operator hasn't reviewed, OR an audit surface gap exceeds 5-LoC inline fix scope (treat as a new slice).
