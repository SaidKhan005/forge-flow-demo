# Indices

Single canonical entry points for orchestrator + executor coordination on the post-Codex wave.

## What lives here

| File | Audience | Purpose |
|---|---|---|
| `WAVE_EXECUTION_LEDGER.md` | All — single source of truth | Per-slice state machine (assigned → in-progress → audit-pending → merged). Every state change writes here. |
| `CLAUDE_HANDOFF_PROMPT.md` | Operator (paste-ready) | Master prompt to paste into a fresh Claude lane executor session. Encodes the executor-as-mini-orchestrator loop. |
| `CODEX_HANDOFF_PROMPT.md` | Operator (paste-ready) | Master prompt to paste into a fresh Codex executor session. Same shape as the Claude side. |
| `CLAUDE_LANE_INDEX.md` | Reference only | Lane-level scope + cross-lane consumption matrix. Slice-level truth lives in the ledger. |
| `CODEX_LANE_INDEX.md` | Reference only | Same for Codex. |

These docs ROUTE, they do NOT duplicate per-slice state. The ledger is canonical for state; the lane indices give the lane-level scope context.

## Authority

- Slice state: `WAVE_EXECUTION_LEDGER.md` is canonical (everything else is a pointer or context).
- Per-slice scope: `docs/_execution/lane_<x>_<name>/03_execution_slices.md`.
- Per-slice authority: follows `CLAUDE.md` Authority Order.
- Wave bundle origin: PR #497 (Step 3 + Step 4 wave) — locked 2026-05-12, then evolved per merges.

## When to read

- **Orchestrator (Claude main chat)**: read the ledger first to find what's audit-pending or merged. Lane indices are reference.
- **Fresh Claude lane executor**: paste `CLAUDE_HANDOFF_PROMPT.md` as your first session message. It tells you to read the ledger and pick the first slice.
- **Fresh Codex executor**: paste `CODEX_HANDOFF_PROMPT.md`.
- **Operator**: open the ledger to see what's where. Use the lane indices only when you need the lane's scope at-a-glance.

## What does NOT live here

- Slice-level execution details — `docs/_execution/lane_<x>_<name>/03_execution_slices.md`.
- Audit findings — `docs/_audits/code_health/` (deep-audit per-lane) + `docs/_audits/post_codex_wave/` (per-PR audits + the audit doc index README).
- Decision rationale — `docs/_decisions/`.
- Tracker truth — `PROJECT_TRACKER.md` (lifecycle-of-record across phases; the wave ledger is a sub-tracker of this).
- Per-PR audit verdicts — `docs/_audits/post_codex_wave/`.

## Update cadence

- Slice state change (merged, audit-pending, etc.) → orchestrator updates `WAVE_EXECUTION_LEDGER.md` only. Lane indices are not touched per-slice.
- New slice added → orchestrator adds a row to the ledger AND a one-line entry in the relevant lane index "Lane assignments" table if the slice opens a new lane.
- Handoff prompts → updated only when the cross-cutting workflow changes (e.g., today's salvage discipline + 3-block worker brief refinements).
