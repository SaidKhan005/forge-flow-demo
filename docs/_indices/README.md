# Indices

Single canonical entry points for each agent's work-track.

## What lives here

| File | Audience | Purpose |
|---|---|---|
| `CLAUDE_LANE_INDEX.md` | Claude (orchestrator + Claude lane agents) | Routes every Claude-assigned lane to its plan, audit, and live-state |
| `CODEX_LANE_INDEX.md` | Codex (Codex lane agents) | Routes every Codex-assigned lane to its plan, audit, and live-state |

These indices ROUTE, they do NOT duplicate. Every lane row points at the lane plan in `docs/_execution/lane_<x>_<name>/`, the relevant code-health audit in `docs/_audits/code_health/`, and the decision authority in `docs/_decisions/`.

## Authority

- Lane assignments locked in `~/.claude/projects/.../memory/project_parked_post_codex_plan.md` (parked plan Step 6) and confirmed by operator during 2026-05-12 unpark.
- Wave content (slices, sequencing, scope) locked in PR #497 (Step 3 + Step 4 wave bundle).
- Per-slice authority follows `CLAUDE.md` Authority Order.

## When to read

- **Orchestrator (Claude main chat)**: before dispatching any work, open the relevant lane index to find the slice's plan + audit pointers.
- **Lane agent (Claude or Codex)**: open your lane index FIRST, then follow its pointers into the wave bundle.
- **Operator**: open either lane index to see what's assigned, what's live, what's blocked.

## What does NOT live here

- Slice-level execution details — those live in `docs/_execution/lane_<x>_<name>/03_execution_slices.md`.
- Audit findings — those live in `docs/_audits/code_health/`.
- Decision rationale — that lives in `docs/_decisions/`.
- Tracker truth — that's `PROJECT_TRACKER.md`.
- Per-PR audit verdicts — those live in `docs/_audits/post_codex_wave/`.

## Update cadence

- Lane assignment changes → update the relevant index.
- Slice completion → update the lane index "live state" column (assigned → in-progress → complete).
- New lane added → add a row to both indices (one as "owned", one as "cross-reference").
