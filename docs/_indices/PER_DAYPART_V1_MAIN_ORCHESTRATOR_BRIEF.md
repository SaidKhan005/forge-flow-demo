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
| 1 — Per-period data layer foundation | **Main** | ✅ MERGED #767 (`~21:24Z 2026-05-15`) — operator-approved. Audit: `slice_1_per_period_data_foundation_orchestrator_review.md`. | SQLite V36 + Postgres `202605160000`; 32 files; pool consistency + Gap 42 fallback + Gap 23 carry verified. |
| 1.5 — Closed-shift aggregator → DaypartBucketer routing | **Main** | ✅ MERGED #763 (`d392d4d1`) | Late-night regression test ✅ MERGED #768 (`6e843798`). |
| 2 — Benchmark tab redesign | **Main** | ✅ MERGED #778 (`7b4d7139`) | Daypart Breakdown swap + card cut + Operating strip + operator-web Benchmarks surface severed (Gap 35 UI half). Audit: `slice_2_benchmark_tab.md`. |
| 2.5 — Service period editor field completeness | **Claude 2** | ✅ MERGED #762 (`4e2a6c94`) | `applicableDays` + `shortLabel` + `sortOrder` landed. |
| 3 — Plan tab persistence wiring | **Main** | ✅ MERGED #776 (`e6ef5b10`) | Persisted-row reader swap; `DaypartPlanAllocator` @Deprecated (3 live consumers); sentinel-0 → MeridianConfig defaults. Audit: `slice_3_plan_persistence.md`. |
| 4 — Shift daypart card full parity | **Main** | ✅ MERGED #777 (`90ef6c47`) | 3-section parity card; whole-day card byte-untouched (Promise 3). 2 plan-legit deferrals. Audit: `slice_4_shift_card.md`. |
| 5 — Variance read-seam swap | **Main** | ✅ MERGED #775 (`8f97f699`) | Per-period read + new derived `daypartTheoreticalLaborPctFor` accessor (formula = canonical `build()`). Audit: `slice_5_variance_read_seam.md`. |
| 6 — Audit scorer extension | **Main** | ✅ MERGED #774 (`a6c6359a`) | Gap-8 structural ordering fix + pool-consistency + wage-at-lock-time audit groups. Audit: `slice_6_audit_scorer.md`. |
| 7a — Tock reservation business_date | **Claude 2** | ✅ MERGED #766 (`baa4047a`) | Gap 45 closed via `IanaTimezoneConverter`. |
| 7b — Sub-hour business-day cutoff precision (Gap 46+47) | **Claude 2** | IN PROGRESS — option (b) sink-side fix. **7b.1 MERGED #781 (`4e06a74e`, 22:38Z)** — `SinkBusinessDateProjector` helper + Square exemplar. Claude 2 now on **7b.2** (roll out the projector across remaining vendor sinks). | Orchestrator defaults: (b1) keep SQL trigger as legacy backup; converge 3 fallback cutoff hardcodes onto 4h. Operator may override. |

## Operator decisions queued

**All 4 prior gaps RESOLVED (locked in plan doc 29ad4c8d + 686d8b5d):**
- Gap 42 → option (c): empty `target_cycle_dayparts` + `MeridianConfig` whole-day fallback.
- Gap 31 → delete `shift_close_authority` entirely; auto-derive from per-vendor capability + business-day-start (absorbed into Slice 1.5).
- Gap 36 → kill legacy `covers_source_lunch/dinner/late_night` columns.
- Gap 35 → cut operator-web Benchmarks override surface entirely.

**Open operator decisions:**

1. ~~Slice 1 merge approval~~ — DONE. Operator approved; merged #767 ~21:24Z 2026-05-15.
2. ~~Slice 7b option choice~~ — RESOLVED. Claude 2 owns option (b) + doc merges.

**Per-Daypart V1 implementation slices ALL MERGED** (0, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 7a). 7b in progress in Claude 2's lane: **7b.1 merged #781**; Claude 2 on 7b.2. Post-merge master analyze: 5 info-level deprecation lints only (planned `DaypartPlanAllocator` migration tail), zero errors/warnings.

**New follow-up (NOT blocking V1 — needs its own slice + operator approval):**
- **Gap 35 backend half. DEFERRED BY OPERATOR until post-testing (2026-05-15).** Slice 2 severed the operator-web Benchmarks *UI* surface (door bricked up, zero UI reach). The backend half — drop the `benchmark_overrides` Postgres table + remove `_writeReplacementCycle`'s admin-replacement path in `target_cycle_service.dart` — is **intentionally held open** until end-to-end testing confirms with certainty that the table + admin write-path are truly unused and safe to delete. Do NOT close this off / dispatch the removal slice until the operator confirms post-testing. Schema-touching + proxy-touching → own slice + operator approval when greenlit. Tracked: `docs/_audits/per_daypart_v1/slice_2_benchmark_tab.md` Follow-ups §1.

## Dispatch transport (NEW STANDARD 2026-05-15 — testing)

Worker execution moves off the orchestrator's interactive subscription onto the Agent SDK / `claude -p` $200/mo credit. Orchestrator stays interactive. Two transports, same contract:
- **Headless (preferred for slice workers):** `scripts/dispatch_worker.ps1 -Branch <b> -PromptFile <f>` launches a fully-autonomous `claude -p` process in an isolated worktree, logs to `.claude/worker-logs/<leaf>.log`. Poll `gh pr list --head <b>` for the returning PR. v1 flags are a first guess — tune on real runs.
- **Agent tool (fallback / quick research):** in-session sub-agent, draws subscription. Use when headless proves flaky or for short audits the orchestrator needs results from before proceeding.
- Rationale + open test questions: user memory `feedback_agent_sdk_credit_dispatch.md`.
- **Test status (2026-05-15):** first headless canary attempt surfaced 2 harness bugs — (1) repo-root resolved to the invoking worktree not the main tree; (2) PowerShell 5.1 treated git's informational stderr as fatal under `ErrorActionPreference=Stop`. Both FIXED in `scripts/dispatch_worker.ps1` (main-worktree resolution via `git worktree list --porcelain`; `Invoke-Git` helper that only throws on non-zero exit; pwsh→powershell hook fallback). Parses clean; live end-to-end headless validation deferred to the next real headless dispatch need. The 5-slice Slices-2/3/4/5/6 wave shipped via the Agent-tool fallback (documented contingency) — zero velocity loss.

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

## Live walkthrough wave (2026-05-15 evening — emulator pressure-test)

Operator-driven emulator walkthrough (F&F demo, `emulator-5554`) surfaced 6 findings; Claude root-causes + dispatches fixes via the **headless `scripts/dispatch_worker.ps1`** harness (now validated live — 3 Windows bugs fixed: main-worktree resolution, `Invoke-Git` native-stderr, `cmd.exe`+stdin launch).

- **Finding 1** Shift daypart card: closed-period misclassified + phantom `0.0%`/`$0.00` → **MERGED #785**.
- **Finding 2** Demo seed never wrote per-period cycle rows (identical Benchmark targets) → **MERGED #784** (canonical `TargetCycleDao.upsertCycle`; lunch 4.40/dinner 4.80/late_night 3.90).
- **Finding 3** Settings raw-URL under buttons → **MERGED #783** (shared `SettingsPointerRow`, deep-link reuse).
- **Finding 4/5/6** Full operational demo-data overhaul: spec'd at `docs/_audits/per_daypart_v1/full_demo_data_spec.md` — 6 chunked slices (A hierarchy → B driver-variance "all covers" fix → C per-location data → D Gap-39 Learn narration → E vendor/demo_mode_state → F HP#11 overrides+notifications). No schema change; HP #2 clean. **Operator decisions: full breadth every surface; Gap 39 Learn narration PULLED IN-SCOPE.** Sequenced AFTER Finding 2 (#784, merged) since shared seed files; demo wave now unblocked.

Next: reseed + hot-restart emulator (operator sees Findings 1/2/3 live) → run 6-slice demo-data wave → re-pressure-test fully operational.

## Active work (2026-05-15 — autonomous orchestration; V1 implementation complete)

**Merged this session:** Slice 0 (#761) → 2.5 (#762) → 1.5 (#763) → arch-verify (#764) → 7a (#766) → 1.5 regression (#768) → 7b research (#765) → Slice 1 audit (#770) → 7b coord (#772) → dispatch harness (#773) → **Slice 1 #767 (operator-approved)** → **Slices 2/3/4/5/6 parallel wave #774-#778 (all audited clean, merged)** → wave-close + harness fixes (#779) → notes update (this).

**In flight (Claude 2 lane):** Slice 7b option (b). 7b.1 merged (#781). Claude 2 on 7b.2 (projector rollout across remaining vendor sinks). Claude 2 self-coordinates its lane; orchestrator only tracks status here.

**Held open by operator decision (do NOT action until greenlit):**
- Gap 35 backend half — deferred until post-testing confirms the `benchmark_overrides` table + admin write-path are provably safe to delete. See "New follow-up" section above.

**No Main-lane work queued.** V1 implementation slices all shipped. Next Main dispatch only on operator instruction (Gap 35 removal slice, or new direction).

## Stop conditions

- Stop dispatching new slices when: 2+ PRs awaiting orchestrator audit, OR 2+ operator-gated PRs awaiting operator approval, OR an operator decision is pending that affects multiple queued slices.
- Stop the whole orchestration if: contract amendment in Slice 0 produces a conflict the operator hasn't reviewed, OR an audit surface gap exceeds 5-LoC inline fix scope (treat as a new slice).
