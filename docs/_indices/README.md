# Indices

Single canonical entry points for orchestrator + executor coordination.
Executor-agnostic per CLAUDE.md "Workflow" — Claude lanes, Codex lanes,
or both run the same underlying pattern.

## What lives here (active)

| File | Audience | Purpose |
|---|---|---|
| `NEXT_WAVE_PLAN.md` | All | Forward 6-phase pipeline. **Phase 2.5 — Per-Daypart Targets V1 is the active feature work** (output of Phase 2 mobile walkthrough). |
| `WAVE_2_LEDGER.md` | Reference | Wave 2's slice ledger. Operator-web + admin lanes CLOSED 2026-05-14. Mobile lane closed for walkthrough 2026-05-15; mobile work transitions to Per-Daypart Targets V1 implementation (separate plan doc). |
| `DEBUG_MD_IMPLEMENTATION_STATUS.md` | All | Source-of-truth for every brain-dump ask from `debug.md` mapped to ✅ / 🚧 / ❌ / 🔍. Wave 2 ledger cites this. |
| `CLAUDE_HANDOFF_PROMPT.md` | Operator (paste-ready) | General Claude executor handoff. Wave 2 specialization archived 2026-05-15. |
| `CODEX_HANDOFF_PROMPT.md` | Operator (paste-ready) | Same shape for Codex (currently dormant). |

## Active feature plan

**Per-Daypart Targets V1** — `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`.
Self-contained, cold-readable. 14 architectural decisions locked; 9
slices (0 → 1 → 1.5 → 2 → 2.5 → 3 → 4 → 5 → 6); 44 gaps consolidated
post-audit; reusable surface-coverage audit method appended.

4 operator decisions queued before any slice dispatches.

## Workflow is executor-agnostic

The underlying pattern (worktree + agent + audit + PR + merge) is the
same whether the active executor is Claude, Codex, or both running in
parallel.

- Authority: [`CLAUDE.md`](../../CLAUDE.md) "Workflow" section.
- Prompt-shape rules: [`docs/CODEX_PROMPT_GENERATION_STANDARD.md`](../CODEX_PROMPT_GENERATION_STANDARD.md).

## Authority

- Slice state: the current wave's ledger is canonical when active; when
  closed, the ledger is frozen and the next wave opens its own.
- Per-slice scope: `docs/_execution/lane_<x>_<name>/03_execution_slices.md`,
  or inline in `PROJECT_TRACKER.md` per "Phase Doc Hygiene" in CLAUDE.md.
- Per-slice authority: follows `CLAUDE.md` Authority Order.
- Wave-specific lane-assignment artifacts retire to
  `docs/archive/_indices/` when the wave closes.

## When to read

- **Orchestrator** (operator's main chat): read `NEXT_WAVE_PLAN.md` for
  forward plan; the active feature plan in `docs/phases/per_daypart_targets_v1/`
  for slice scope; the wave's ledger for closed state.
- **Fresh Claude executor**: paste `CLAUDE_HANDOFF_PROMPT.md`.
- **Fresh Codex executor**: paste `CODEX_HANDOFF_PROMPT.md`.
- **Operator**: `PROJECT_TRACKER.md` at repo root is the highest-level
  router; this directory is the second hop.

## What does NOT live here

- Slice-level execution details — `docs/_execution/lane_<x>_<name>/`.
- Phase / feature plans — `docs/phases/<phase>/`.
- Audit findings — `docs/_audits/<wave>/`.
- Decision rationale — `docs/_decisions/`.
- Tracker truth — `PROJECT_TRACKER.md` (lifecycle-of-record across phases).

## Update cadence

- Slice state change → main orchestrator updates the active ledger.
- New slice added → main orchestrator adds a row.
- Handoff prompts → updated only when cross-cutting workflow changes (rare).
- `NEXT_WAVE_PLAN.md` → updated on operator pivot, phase close, or major decision.

## Archived

Closed-wave artifacts retired to `docs/archive/_indices/`:

- `docs/archive/_indices/wave_1_closed_2026_05_13/WAVE_EXECUTION_LEDGER.md` — Wave 1 (post-Codex wave) slice state machine.
- `docs/archive/_indices/wave_2_closeout_2026_05_15/` — Wave 2 Claude2-lane handoffs + R-2L proposal + help queues (operator-web + admin lanes closed; mobile transitioned to Per-Daypart Targets V1).
- `docs/archive/_indices/CLAUDE_LANE_INDEX_2026-05-13.md` + `CODEX_LANE_INDEX_2026-05-13.md` — Post-Codex wave lane indices.

See `docs/archive/_indices/README.md` for the full archive map.
