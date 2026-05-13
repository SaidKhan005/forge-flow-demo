# Final Housekeeping Sweep — 2026-05-13 (Bundle 26)

**Scope:** Stage the repo for the Claude lane restart + general doc hygiene before the wave's back half. Lean docs, indexed trackers, no repetition, no missing pieces going forward.

**Verdict:** approve-for-merge (orchestrator-authored, no behavior change, no slice impact).

## Changes applied

### 1. `docs/_indices/README.md` — rewritten

Previously didn't mention the active artifacts (the wave ledger + handoff prompts). Now lists all 5 docs in `docs/_indices/` with audience + purpose, clarifies that the ledger is canonical for slice state (lane indices are reference only).

### 2. `docs/_indices/CLAUDE_LANE_INDEX.md` — trimmed + refreshed

- Removed per-slice "State" column from lane-assignments table (state lives in the ledger; this index was rotting because it duplicated).
- Updated "all 43 slices" stale claim → ledger is canonical for the live count (49 as of bundle 25).
- Refreshed lane-scope summaries to reflect today's evolution (A3.x cluster chunks, A11.1.b, B1.c, B11.2.b row additions).
- Expanded cross-references for newly-merged Codex lanes (A9.1, A11, B5, B9 — Claude now consumes from these).
- Added change-log entry for 2026-05-13.

### 3. `docs/_indices/CODEX_LANE_INDEX.md` — trimmed + refreshed

Same treatment as the Claude side. Lane-assignments table now lane-level only; per-slice state defers to the ledger. Cross-references expanded for newly-merged Claude lanes (A3.x, A4.x, A11.x, B1.x, B11.x). B5.b row addition reflected.

### 4. `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` — refinements added

- **3-block worker brief shape** per `feedback_codex_prompt_format.md` (Block 1 human / Block 2 tech / Block 3 tasks).
- **Canonical hooks step** (`pwsh scripts/install_git_hooks.ps1`) as Step 0 for fresh worktrees — fixes the heavy pre-push stall.
- **Banned items list** explicit (KMS, parse_warnings, parse_partial, etc.) per `project_v1_lean_cut_2_2026_05_03.md`.
- **Banned imports** rule (`package:postgres` outside lib/infrastructure/persistence/postgres + tool/advisor_proxy).
- **Sensitive-path flag** discipline (db/migrations, lib/auth, docs/contracts, lib/infra/postgres).
- **Salvage discipline section** (NEW) for relaunch recovery with the disclosed "Salvage note" pattern. Cites PR #561 + #563 exemplars.
- **Pattern B drift discipline section** (NEW) — explicit reference to the 4/4 drift observed today + the 3-PR-restart fix.
- **Pattern B exemplars** (PRs #547, #556, #557) cited inline so workers know exactly what shape to mirror.

### 5. `docs/_indices/CODEX_HANDOFF_PROMPT.md` — light refinements

Same 3-block format + banned items + banned imports + sensitive-path flag for consistency. Salvage discipline section added (lighter than Claude side since Codex doesn't have the drift problem). Pattern B exemplars cited.

### 6. `docs/_audits/post_codex_wave/README.md` — NEW (audit doc index)

Table of contents for all 41 audit docs grouped by:
- Cross-cutting audits (wave-completion deep audit + followups doc-drift cleanup)
- Pre-wave retroactive audits (PRs #473-495)
- Lane A code-health PR audits (#498-563)
- Lane B feature PR audits (#499-561)
- Lane C parity PR audits (#499, #556)

Verdict legend included. Convention notes for future entries.

## What this does NOT touch

- `WAVE_EXECUTION_LEDGER.md` — already current after bundle 25.
- `docs/POST_HARDENING_FOLLOWUPS.md` — current after PR #558 doc-drift cleanup.
- `docs/_execution/lane_<x>_<name>/03_execution_slices.md` — slice spec files unchanged (no scope drift).
- `CLAUDE.md` — no edits (durable doctrine intact).
- Memory files — separately updated outside this PR (`handoff_prompt_claude_lane_loop_mode.md` now points at the in-repo canonical version).
- Production code — zero edits.

## Authority anchors

- `~/.claude/projects/.../memory/feedback_codex_prompt_format.md` — 3-block brief shape.
- `~/.claude/projects/.../memory/feedback_parallel_claude_lane_executor.md` — durable doctrine on Claude lane behavior (Pattern B + loop mode + salvage discipline).
- `~/.claude/projects/.../memory/feedback_agent_worktree_hooks_first.md` — canonical hooks first step.
- `~/.claude/projects/.../memory/project_v1_lean_cut_2_2026_05_03.md` — banned items list.
- `CLAUDE.md` "Agent-Led Slices" — executor contract.
- PRs #547, #556, #557 — Pattern B exemplars.

## Status

Ready for orchestrator merge. After merge: paste `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` into the fresh Claude lane session and watch for B11.2.b to be the first pickup.
