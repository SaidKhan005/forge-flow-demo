# Between-Sprint Audit & Next-Batch Prompt

**When to use:** between parallel-execution batches, after worktree
ships have merged to master and before you spawn the next batch.

**Workflow:** copy the fenced block below, fill in the four input
slots at the top, paste into a fresh Claude main-chat session on
`master`. Claude returns audit verdicts, lean tracker/phase-doc updates,
archive verdict, a parallel-safety matrix, and next-batch prompts that follow
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

---

````
# Between-Sprint Audit & Next-Batch Prompt

You are running on master in main chat. Per
`~/.claude/projects/<project>/memory/feedback_worktree_observer_role.md`,
you are read-only across all worktrees in `.claude/worktrees/` —
inspect freely, do not edit any worktree's project code. Tracker /
phase doc / coordination edits on master from main chat are still
allowed (those are not project-code edits).

## Inputs (I'm filling these in)

- Just-completed batch:
  [e.g. claude/gracious-yalow-da6aeb , claude/vibrant-dubinsky-ca47af , claude/bold-dewdney-d3c4d9, ]
- Next-batch candidates 
  [ > 11A.3 Corpus admin (without Graphify review)
        > 11A.4 Integration management
        > 7.58 Primary Driver audit]
- Max parallel lanes (4):
- Current master pulled.

## What to do

Authority docs to follow throughout:
- `CLAUDE.md` — Hard Promises, hygiene rule, parallel-lane rules
- `PROJECT_TRACKER.md` — Active Lanes, Phase Board, queue
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md` — prompt shape,
  Parallel Worktrees, Codex Review, Docs After Approval

### 1. Discovery
- `git log --oneline -20` and identify the merge commits matching
  the just-completed batch
- `ls docs/_walkthroughs/` to inventory acceptance evidence
- `git worktree list` to see live worktrees and flag any merged
  branches that are stale (do not auto-remove)

### 2. Code-vs-walkthrough audit (per just-completed slice)
For each slice that just merged:
- Read its walkthrough at `docs/_walkthroughs/<slice>.md`
- Spot-check the walkthrough's file:line claims against actual
  code (Read or Grep the cited files)
- Verdict per slice: **ACCEPT** / **ACCEPT (partial — name the
  follow-up slice + what it needs to do)** / **REJECT (name the
  issue)**

If any slice touched contract-bound seams (auth permission keys,
audit attribution, event_outbox envelope, RLS policies, migrations
listed in `docs/contracts/migrations_summary.md`), also cross-check
the relevant doc in `docs/contracts/**`.

### 3. Tracker + phase doc refresh (LEAN)
- `PROJECT_TRACKER.md`:
  - Update Active Lanes block: move newly-accepted slices from
    "owed" to "accepted"; add any new follow-up slices to "owed"
  - Update Phase Board rows the same way
  - Compress the "Now" / "Done in this session" block to a tight
    "Recent acceptances" pointer (max ~10 lines; do not let it
    bloat across sessions)
  - Update the date stamp at the top
- For each affected phase doc, update the Frontend Exposure
  section: mark accepted slices with commit SHA + walkthrough
  ref + 1-2 line scope summary
- Honor the lean authority law: PROJECT_TRACKER.md and CLAUDE.md
  are pointers, not full plans. Detail lives in linked phase docs.

### 4. Lean pass (trim repetition; report before/after line counts)
- Scan PROJECT_TRACKER.md and CLAUDE.md for content duplicated in
  CODEX_PROMPT_GENERATION_STANDARD.md, decision register, phase
  docs, or each other
- Remove duplicates; replace with a single pointer to the
  authoritative location
- Report `wc -l` before vs after for each touched doc

### 5. Archive check
- Apply CLAUDE.md hygiene rule: only **fully-closed phases**
  retire to `docs/archive/phases/<phase>/`. A phase is fully
  closed when every sub-slice + every operational gate is
  accepted; partial families do NOT retire
- If nothing is eligible, say so explicitly
- Walkthroughs in `docs/_walkthroughs/` stay where they are
  (acceptance evidence; cutover.0 reads them)
- Stale worktrees (merged branches still in `.claude/worktrees/`):
  flag for user cleanup with the exact `git worktree remove`
  command; do NOT auto-remove

### 6. Next-batch parallel-safety analysis
For each candidate slice:
- Identify its `Files to modify` from the queued phase-doc scope
- Build a file-overlap matrix (rows = files; columns = candidate
  lanes)
- Classify each overlap: **disjoint** / **additive-safe shared
  seam** (both lanes append disjoint methods/DTOs/routes) /
  **conflict** (must serialize)
- Identify any logical dependencies (lane B consumes lane A's
  output) — sequence those, do not parallelize
- Recommend a sustainable parallel set (typically 3-4 lanes; max
  parallel from inputs)

### 7. Prompts for the recommended next batch
Per slice in the recommended set, produce a full prompt in the
standard's format (`docs/CODEX_PROMPT_GENERATION_STANDARD.md`
"Prompt Shape"):
- **Block 1 (Markdown, visible to user):** Plain English, Lane
  line (`Lane: <slice-id> — worktree
  .claude/worktrees/<lane-name> on branch codex/<lane-name> off
  master @ <sha>, to be created`), Important context (call out
  parallel-safety with sibling lanes), Current issue, Human
  prerequisites (Setup/access + Decision needed)
- **Block 2 (single fenced `text` block, paste-ready
  for Claude):** Authority files (3 max), Hard constraints — must
  include explicit **additive-safe carve-outs** naming each
  sibling lane's surface that this lane must NOT modify; Files to
  modify; Implementation tasks; Required tests; Operator (or
  Admin) walkthrough in `kDemoMode = true`; Acceptance criteria
  including walkthrough evidence at
  `docs/_walkthroughs/<slice>.md`, brand styling, permission
  gating, no-tracker-update + no-commit
- Block 2 target ≤50 lines per the standard

### 8. Spawn commands
End with `git worktree add` commands for each recommended lane,
off the same master sha.

## Output format

Plain English summary first (one paragraph), then the structured
deliverables in this order:

1. Audit verdicts (compact table; one row per just-completed slice)
2. Tracker + phase doc edit summary (bullet list of what changed,
   with `before -> after` line counts for any leaned docs)
3. Archive verdict + stale-worktree cleanup commands (if any)
4. Parallel-safety matrix (file-overlap table for the next batch)
5. Next-batch prompts (one section per recommended lane: Block 1 in
   plain Markdown + Block 2 in a fenced `text` block)
6. Spawn commands (one fenced shell block)
7. After-batch outlook (one paragraph: what closes after this
   batch merges, what remains queued)

Keep prose tight. Cite file:line where it adds clarity. Do not
restate well-known authority-doc content; reference it.
````

## How to fill the input slots

- **Just-completed batch:** worktree branches whose commits just
  landed on master. Find via `git log --oneline -20` and look for
  `Merge pull request #N from <branch>` lines since your last audit.
- **Next-batch candidates:** either name them explicitly (slice IDs
  like `9.UX.3, 9.UX.6, 9.UX.7`), or leave blank to let the Claude
  session pick from `PROJECT_TRACKER.md` Active Lanes "owed" rows.
- **Max parallel lanes:** stay at 3 by default. Bump to 4 only when
  one of the lanes is on a fully separate code surface (e.g.,
  `lib/admin/` vs operator app, or backend-only data path vs UI).
- **Master sha:** capture `git rev-parse --short HEAD` at the moment
  you intend to spawn the new worktrees so all lanes branch off the
  same base.
