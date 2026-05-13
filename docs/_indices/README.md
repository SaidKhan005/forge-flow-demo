# Indices

Single canonical entry points for orchestrator + executor coordination.
The workflow is executor-agnostic per CLAUDE.md "Workflow" section —
Claude lanes, Codex lanes, or both run the same underlying pattern.

## What lives here

| File | Audience | Purpose |
|---|---|---|
| `NEXT_WAVE_PLAN.md` | All | Forward roadmap — the demo-validate → tag → refactor → re-test → mutate pipeline + cross-references to wave bugs, refactor scope, and runbooks. |
| `WAVE_EXECUTION_LEDGER.md` | Reference (frozen) | The post-Codex wave's slice state machine. CLOSED 2026-05-13. Next wave opens its own ledger when it starts. |
| `CLAUDE_HANDOFF_PROMPT.md` | Operator (paste-ready) | Master prompt to paste into a fresh Claude executor session. Encodes the executor-as-mini-orchestrator pattern. |
| `CODEX_HANDOFF_PROMPT.md` | Operator (paste-ready) | Same shape for Codex. Both handoff prompts encode the SAME workflow (CLAUDE.md "Workflow"); executor-specific scaffolding only. |

## Workflow is executor-agnostic

The underlying pattern (worktree + agent + audit + PR + merge) is the
same whether the active executor is Claude, Codex, or both running in
parallel. The operator may run out of quota on one and switch — workflow
is unaffected.

Authority for the workflow: [`CLAUDE.md`](../../CLAUDE.md) "Workflow"
section.

Prompt-shape rules: [`docs/CODEX_PROMPT_GENERATION_STANDARD.md`](../CODEX_PROMPT_GENERATION_STANDARD.md)
(named for legacy reasons; the rules apply to ALL agent prompts
regardless of executor).

## Authority

- Slice state: the current wave's ledger is canonical (everything else
  is a pointer or context). When closed, the ledger is frozen and the
  next wave opens its own.
- Per-slice scope: `docs/_execution/lane_<x>_<name>/03_execution_slices.md`,
  or inline in `PROJECT_TRACKER.md` per "Phase Doc Hygiene" in CLAUDE.md
  (`slice < 1 week AND < 5 files`).
- Per-slice authority: follows `CLAUDE.md` Authority Order.
- Wave-specific lane-assignment artifacts (e.g., the post-Codex wave's
  `CLAUDE_LANE_INDEX` + `CODEX_LANE_INDEX`) retire to
  `docs/archive/_indices/` when the wave closes.

## When to read

- **Orchestrator** (operator's main chat): read `NEXT_WAVE_PLAN.md` for
  the forward plan; the wave's ledger for closed state; the handoff
  prompts only when bootstrapping a new executor.
- **Fresh Claude executor**: paste `CLAUDE_HANDOFF_PROMPT.md` as your
  first session message.
- **Fresh Codex executor**: paste `CODEX_HANDOFF_PROMPT.md`.
- **Operator**: `PROJECT_TRACKER.md` at repo root is the highest-level
  router; this directory is the second hop.

## What does NOT live here

- Slice-level execution details — `docs/_execution/lane_<x>_<name>/03_execution_slices.md`.
- Audit findings — `docs/_audits/code_health/` (deep-audit per-lane) + `docs/_audits/post_codex_wave/` (12 institutional-knowledge files; closed wave's 84 per-PR audits archived to `docs/archive/_audits/post_codex_wave_2026-05-13/`).
- Decision rationale — `docs/_decisions/`.
- Tracker truth — `PROJECT_TRACKER.md` (lifecycle-of-record across phases).

## Update cadence

- Slice state change (merged, audit-pending, etc.) → orchestrator
  updates the current wave's ledger only.
- New slice added → orchestrator adds a row to the ledger.
- Handoff prompts → updated only when the cross-cutting workflow
  changes (rare).
- `NEXT_WAVE_PLAN.md` → updated when the operator pivots the forward
  sequencing or when a step closes.

## Closed-wave reference

Post-Codex wave's lane-assignment indices archived 2026-05-13:

- `docs/archive/_indices/CLAUDE_LANE_INDEX_2026-05-13.md`
- `docs/archive/_indices/CODEX_LANE_INDEX_2026-05-13.md`

See `docs/archive/_indices/README.md` for the archive map.
