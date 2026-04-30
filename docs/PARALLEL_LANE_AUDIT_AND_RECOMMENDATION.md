# Parallel Lane Audit & Recommendation

Use this between parallel-execution batches. Run on master (read-only
across worktrees) after a batch of worktree ships completes, before
dispatching the next batch.

Purpose:

1. Confirm the just-completed batch landed cleanly.
2. Surface anything that needs your manual attention.
3. Recommend which slices from the upcoming queue can run as the next
   parallel batch — based on actual file-touch analysis, not vibes.

## When To Run This

- After 2+ worktree ship prompts have reported "Shipped:" or stopped
  on a sensitive-path gate.
- Before opening the next set of worktrees.
- Not in the middle of a single batch — let in-flight ships finish or
  fail first.

## Inputs

Provide only these. If any are missing, inspect repo truth first; ask
only when a decision actually requires it.

- `Just-completed batch:` the worktree branch names that were
  shipping (e.g. `claude/foo-abc123`, `claude/bar-def456`).
- `Next candidate slices:` the slice IDs from `PROJECT_TRACKER.md`
  Current Slice Queue you're considering for the next batch.
- `Max parallel lanes:` how many worktrees you're willing to run
  concurrently (typical: 2–4).

## What The Audit Step Does

For each branch in the just-completed batch:

1. Confirm a merge commit landed on `origin/master` referencing the
   PR (or confirm the PR is open and waiting on manual review for
   sensitive-path slices).
2. Confirm `dart analyze` is clean on `origin/master` after the
   batch.
3. Confirm no orphan branches: every shipped feature branch is
   deleted or scheduled for cleanup; every backup branch is still
   present (those are mine to clean up).
4. Surface any ship that stopped on an anomaly (failing tests,
   conflicts, sensitive paths). List each with: branch name, stop
   reason, recovery command, PR link if applicable.
5. Note any tracker / contract / migration changes that landed in
   the batch. Those expand the "sensitive surface" for the next
   batch's recommendation.

## What The Recommendation Step Does

Goal: pick a subset of `Next candidate slices` that are safe to run
in parallel. Safety = lane-level file disjointness.

Method:

1. For each candidate slice, read its phase doc / tracker entry and
   identify the **expected file-touch set**. Be specific: paths, not
   directories, where possible. If a slice's touch set is genuinely
   uncertain, mark it `unknown-scope` and exclude from any parallel
   batch — run it solo.
2. Build the conflict graph: any pair of slices whose touch sets
   intersect on a file is a conflict edge. Shared-seam files
   (anything in `lib/services/`, `lib/state/`, `lib/domain/`,
   `lib/infrastructure/persistence/sqlite/`) count as conflict edges
   even on near-miss overlaps — better safe than rebase-conflicted.
3. From the conflict graph, pick a maximum independent set up to
   `Max parallel lanes`. Prefer slices that have been blocked
   longest, then lowest-risk surfaces.
4. Flag any selected slice that touches sensitive paths
   (`db/migrations/**`, `docs/contracts/**`, `lib/auth/**`,
   `lib/infrastructure/persistence/postgres/**`). Those will stop at
   PR-open during ship; the user merges them manually.
5. For any candidate excluded from the batch, state why in one
   line: "conflicts with X on lib/services/foo.dart", or
   "unknown-scope, run solo", or "blocked by Y not yet shipped".

## Output Shape

The recommendation should be one short report. No essay. Sections:

```
## Audit
- Branch <name>: shipped / stopped (<reason>) — link / recovery cmd
- Branch <name>: ...
- Master state: clean / dirty (<details>)
- Sensitive surface added this batch: <files or "none">

## Recommended Next Batch (parallel)
1. Slice <id> — touches: <paths>
2. Slice <id> — touches: <paths>
3. Slice <id> — touches: <paths>

## Excluded (run solo or later)
- Slice <id> — <one-line reason>
- Slice <id> — <one-line reason>

## Sensitive-Path Flags
- Slice <id> touches db/migrations/** — will stop at PR-open
- (or "none")
```

## Hard Rules

- Never recommend two slices that share a file in their touch set.
  Shared-seam files are an automatic exclude even on near-misses.
- Never run more parallel lanes than the user gave as the cap.
- If the upcoming queue is unclear or stale, stop and ask the user
  to refresh `PROJECT_TRACKER.md` Current Slice Queue rather than
  recommending against guesses.
- Don't recommend a sensitive-path slice as part of a parallel batch
  if another batch slice depends on its merge landing first — those
  serialize.
- Don't edit trackers, contracts, or docs as part of running this.
  Recommendation only; Codex on master owns tracker advancement.
- Run from master (read-only across worktrees). Do not modify any
  worktree's state.

## Where This Sits In The Loop

End of phase → post-commit hook refreshes graph → **Claude plans**
the phase's slices off the fresh graph → Codex reviews + drafts
prompts → parallel worktrees implement and ship → **this doc** runs
to audit the batch and recommend the next parallel set → loop.

## Relationship To Other Docs

- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`: prompt shape +
  generator + parallel-lane rules. This doc decides which of those
  slice prompts get dispatched in parallel.
- `CLAUDE.md` "Workflow > Parallel lanes": the durable rules. This
  doc is the operational procedure that produces lane assignments
  compatible with those rules.
