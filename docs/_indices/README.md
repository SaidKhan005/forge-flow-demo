# Indices

Single canonical entry points for orchestrator + executor coordination.
Executor-agnostic per CLAUDE.md "Workflow": Claude lanes, Codex lanes,
or both run the same underlying pattern.

`PROJECT_TRACKER.md` at repo root is the highest-level router; this
directory is the second hop. Slice scope lives in
`docs/_execution/`, phase plans in `docs/phases/`, audits in
`docs/_audits/`, decision rationale in `docs/archive/_decisions/`.

## Live files

| File | Purpose |
|---|---|
| `NEXT_WAVE_PLAN.md` | Forward pipeline. Phase 2.5, Per-Daypart Targets V1, is the active feature work (output of the Phase 2 mobile walkthrough). |
| `PER_DAYPART_V1_MAIN_ORCHESTRATOR_BRIEF.md` | Cold-readable brief for the main orchestrator session driving Per-Daypart V1 (plan + execution context). |
| `PER_DAYPART_V1_CLAUDE2_HANDOFF.md` | Paste-ready prompt to bootstrap a second Claude session into the Per-Daypart V1 parallel-lane role. |
| `PER_DAYPART_V1_POST_SLICE1_DISPATCH.md` | Pre-staged worker prompts to fire as one parallel wave once the relevant Per-Daypart slice merges. |
| `VARIANCE_COACHING_V2_LEDGER.md` | One row per Variance Coaching V2 lane. Lanes A to F MERGED; Lane G wave-close in review. Audit artifacts: `docs/_audits/variance_coaching_v2/`. |
| `DEBUG_MD_IMPLEMENTATION_STATUS.md` | Source-of-truth mapping every `debug.md` brain-dump ask to done / in-progress / not-done / investigating, with citations. |
| `INFRA_DEFERRALS_INVENTORY.md` | Discovery index (not authority) for deliberate infra deferrals that live only as code comments (GAP B6). |

## Closed / archived ledgers

- `WAVE_2_LEDGER.md` (still in tree, frozen): Wave 2 slice ledger.
  Operator-web + admin lanes CLOSED 2026-05-14; mobile lane closed for
  walkthrough 2026-05-15 and transitioned to Per-Daypart Targets V1.
- `docs/archive/_indices/wave_1_closed_2026_05_13/WAVE_EXECUTION_LEDGER.md`:
  Wave 1 (post-Codex wave) slice state machine.
- `docs/archive/_indices/wave_2_closeout_2026_05_15/`: Wave 2 Claude2-lane
  handoffs + R-2L proposal + help queues.
- `docs/archive/_indices/CLAUDE_LANE_INDEX_2026-05-13.md` +
  `CODEX_LANE_INDEX_2026-05-13.md`: post-Codex wave lane indices.
- The earlier general `CLAUDE_HANDOFF_PROMPT.md` /
  `CODEX_HANDOFF_PROMPT.md` were retired; Per-Daypart V1 handoffs above
  are the current paste-ready prompts.

See `docs/archive/_indices/README.md` for the full archive map.

## Authority + cadence

- Slice state: the active wave/feature ledger is canonical while open;
  once closed it is frozen and the next opens its own.
- Per-slice authority follows `CLAUDE.md` Authority Order.
- Prompt-shape rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.
- Ledger row changes are made by the main orchestrator only.
- `NEXT_WAVE_PLAN.md` updates on operator pivot, phase close, or major
  decision.
- Wave-specific lane-assignment artifacts retire to
  `docs/archive/_indices/` when the wave closes.
