# Claude Lane Handoff Prompt — Post-Codex Wave Execution (Pattern B)

Paste-ready prompt for a fresh Claude lane executor session in a NEW worktree (NOT the orchestrator worktree). The operator pastes this verbatim to start the executor loop.

Pattern: **executor as mini-orchestrator**. You spawn worker sub-agents in parallel for independent slices, audit each one's diff yourself before opening PRs, send back for fixes if needed. Only clean, twice-audited diffs become PRs. The orchestrator (separate Claude session) does the final audit + merge.

---

## BEGIN PROMPT TO COPY-PASTE TO A FRESH CLAUDE SESSION

You are the Claude lane executor for the Forge & Flow post-Codex wave. You are NOT a worker — you are a mini-orchestrator. Your job is to:

1. Read the wave ledger
2. Pick a batch of independent slices
3. Spawn worker sub-agents (parallel, worktree-isolated) for each slice
4. Audit each sub-agent's returned diff yourself
5. Send back failing diffs for fixes (max 2 cycles)
6. Open PRs only for clean, twice-audited diffs
7. Move to the next batch

You are NOT the orchestrator session. The orchestrator runs in a separate Claude session (path `.claude/worktrees/nifty-clarke-d3ec25` or wherever the orchestrator is currently). That session does the FINAL audit + merge. You stop at PR-open.

### Setup (once per session)

1. Confirm you are running in a dedicated Claude lane executor worktree (NOT the orchestrator worktree). If you cannot confirm, ask the operator.
2. `git fetch origin && git checkout master && git pull` — start from current master.

### Read order (every batch)

1. `docs/_indices/WAVE_EXECUTION_LEDGER.md` — find the next `assigned` slices where `Owner = Claude` and `Dependency = merged` (or `—`). Pick 1-3 that have **no file overlap** with each other. These become your next batch.
2. `docs/_indices/CLAUDE_LANE_INDEX.md` — confirm each lane's scope, audit anchor, decision authority.
3. The lane's `03_execution_slices.md` — slice-level depth.
4. `CLAUDE.md` — durable repo rules. Read once per session.

### Batch contract

For each batch (1-3 slices in parallel):

**Step 1 — Spawn one worker sub-agent per slice via the `Agent` tool with `isolation: "worktree"` and `subagent_type: "general-purpose"`.** Brief each sub-agent in the **3-block format** (per `~/.claude/projects/.../memory/feedback_codex_prompt_format.md`):

```
You are a worker sub-agent for the Forge & Flow wave executor. Your
job is to implement ONE slice and return a diff for review. Do NOT
push. Do NOT open a PR. Do NOT commit to master.

==== Block 1 — Human-readable context ====

Slice: <slice-id> from docs/_indices/WAVE_EXECUTION_LEDGER.md
Why: <1-3 sentence rationale; cite the deep-audit row or plan-anchor finding>
Current issue / gap: <what this slice closes>

==== Block 2 — Tech context ====

Step 0 (REQUIRED for fresh worktrees): pwsh scripts/install_git_hooks.ps1
       (canonical hooks; pre-push hook from parent worktree is stale)

Authority files (read in order):
- docs/_execution/<lane>/03_execution_slices.md — find your slice and read it in full
- CLAUDE.md (Authority Order + Hard Promises)
- Any contract docs the slice cites under docs/contracts/

Worktree: you are running in an isolated worktree off master. Create a
new branch off origin/master: claude/<slice-id-lowercased>-<topic>.

Hard constraints:
- Banned items per ~/.claude/projects/.../memory/project_v1_lean_cut_2_2026_05_03.md
  MUST be absent from every new file: KMS rollout, parse_warnings, parse_partial,
  kStrictReplayFiveMinute, pg_advisory_lock, sigtermDrainHandler, inboundWebhookDLQTile,
  raw_payload_partition, pg_partman_raw — ALL REJECT.
- Banned imports: `package:postgres` outside lib/infrastructure/persistence/postgres/
  and tool/advisor_proxy/ (enforced by postgres_import_lint).
- Sensitive paths: if you touch db/migrations/**, docs/contracts/**, lib/auth/**,
  or lib/infrastructure/persistence/postgres/**, flag it in your return summary so
  the executor can confirm the slice's ledger Gate column is `operator`.
- Files to LEAVE ALONE: explicit list from your slice's plan-anchor "Files NEW" /
  "Files MODIFY" / "Files to LEAVE ALONE" sections. Frozen `lib/auth/**` +
  `lib/data/**` unless the slice explicitly touches them.

==== Block 3 — Tasks ====

Implement the slice. Stay strictly inside scope. No drive-by fixes.

Run:
- dart analyze --fatal-infos on every touched file (must be clean)
- targeted tests for the slice's surface (must pass)

Then run the Feature Implementation Lens Audit Framework
(docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md) deep pass against
your own change. Produce the 14-lens **worker self-audit table** with file:line
citations for every finding. Same shape as the worker tables in PRs #547, #556,
#557 of this repo — read those PR bodies for the exact format.

Commit your work to the branch (one commit). Do NOT push.

Return to me (the executor):
- the git log of your branch + branch name + commit SHA
- the git diff vs origin/master (full)
- the 14-lens worker self-audit table
- a 1-paragraph execution-report summary (what built, what tested, what's clean)
- the dart analyze + test command outputs (last lines confirming pass)
- a flag if you touched any sensitive path (db/migrations, lib/auth, etc.)

Hard rules:
- Do NOT push.
- Do NOT open a PR.
- Do NOT touch master.
- Do NOT cross lanes (no fixing bugs in other lanes' files).
- Do NOT use --no-verify or skip CI gates.
- Do NOT redeploy / push to Production1 / touch live KMS or billing.
- Do NOT update the wave ledger or lane indices.
- Do NOT run graphify or the full Flutter test suite.
```

**Step 2 — Wait for all sub-agents to return.** They run in parallel with `run_in_background: true`. You receive notifications when each completes.

**Step 3 — Run YOUR independent audit pass on each returned diff.** Do not trust the sub-agent's self-audit. Re-run the 14-lens framework against the diff. Specifically verify:

- Schema/UI mismatch (UI exposes a value the schema can't store)
- Route contract drift (admin gateway path vs proxy path differ)
- Missing audit log on a mutation
- Missing idempotency key on a write
- Operator-approval gate skipped (cross-check against ledger `Gate` column)
- Test coverage gap on the new surface
- Hash chain risk (any direct mutation of `audit_logs` without an allowlist entry)
- Scope creep (files outside the slice's stated scope)
- Demo carve-out violations (per CLAUDE.md HP #2)
- Frozen-surface violations (`lib/auth/**` permission key catalog, `lib/data/**` legacy)
- **For B11 redemption-code work specifically**: any handoff that puts a token in URL parameters (forbidden per addendum A1)

For each finding, cite an authority anchor (CLAUDE.md, contracts, decision docs, framework docs). No-anchor findings are not findings.

**Step 4 — Decide per slice**:

- **Clean audit (no findings)**: proceed to Step 5.
- **Cited findings, fixable**: send the slice back to its sub-agent with the specific findings + authority anchors. Sub-agent fixes, re-runs analyze + tests + 14-lens, returns updated diff. **Cap: 2 send-back cycles per slice.** Third failure → escalate to operator (post a message describing the failure pattern + cited findings; pause that slice; continue with other slices in batch). Use `SendMessage` to the same sub-agent's ID to continue its session with the fix request.
- **Uncited issue (your judgment call)**: escalate to operator immediately. Do not auto-fix.

**Step 5 — Open PR for clean slices.** For each twice-audited clean diff:

1. The sub-agent's branch is already committed in its worktree. Push the branch from the sub-agent's worktree path (or have the sub-agent push as a final step before returning — check sub-agent return for the worktree path).
2. Open PR via `gh pr create --base master`. PR title: `<type>(<scope>): <subject> (<slice-id>)`. If the slice's `Gate` column = `operator`, prefix title with `[operator-approval-required]`.
3. PR body must include:
   - 1-paragraph "what changed and why"
   - Slice ID + authority anchor cited
   - **Both audit tables**: sub-agent's self-audit table + your executor audit table
   - Operator-approval-required flag if applicable
   - Cross-lane note if the slice surfaced a bug in Codex-owned files (just describe — do NOT fix)

**Step 6 — Concurrency cap.** Maintain at most 3 open PRs from your session at any moment. If you have 3 open and want to start a new batch, wait until at least one merges (or is closed by the orchestrator). Use `gh pr list --author "@me"` to check.

**Step 7 — Move to next batch.** Re-read the ledger (state may have changed — orchestrator updates merged slices). Pick the next 1-3 independent slices for the next batch.

### Salvage discipline (relaunch recovery)

If a Claude Code relaunch kills one of your worker sub-agents mid-task:

1. The worker's local commit (if any) survives on disk in its worktree.
2. After the relaunch, salvage what's on disk:
   - `cd` to the dead worker's worktree.
   - Run `git status` + `git log -1` to confirm what landed.
   - Run `git diff origin/master..HEAD` to see the partial state.
3. Decide:
   - **If the commit is substantively complete** (production code + tests + worker self-audit table written): salvage. Run your executor audit pass on the partial diff. Note in the PR body's "Salvage note" section: (a) what the worker completed before dying, (b) what you salvaged (audit doc, push, etc.), (c) what's missing from the spec.
   - **If the commit is too partial** (no tests, no audit table, stub work): close out, log inline, and re-spawn the worker as a fresh attempt.
4. Examples of clean salvage: PRs #561 (B1.c) + #563 (A3.2) on 2026-05-13.

The orchestrator inspects the salvage path for drift artifacts before merge. Honest disclosure in the "Salvage note" section is the discipline — silent gap-filling is not.

### Pattern B drift discipline

The worker self-audit table + your executor independent audit table are BOTH non-negotiable in every PR body. If a Claude lane session ships 3+ consecutive PRs missing one or both tables (e.g., PRs #550 + #552 + #561 + #563 on 2026-05-13), it indicates prompt drift — the cheapest fix is to start a fresh session with this handoff prompt rather than retrofit the drifting session.

The exemplars to mirror in every PR body are at:
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_547_b9_2_my_account_active_sessions_audit.md`
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_556_c10_admin_parity_copy_audit.md`
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_557_b5_admin_access_control_audit.md`

These are the orchestrator-side audit docs for those PRs, but they cite the worker + executor tables present in the PR bodies themselves. View the PR bodies via `gh pr view <number> --json body` for the exact shape.

### Batch sizing rules

- **File-isolation check before spawning**: for each candidate slice, list its files-touched (from `03_execution_slices.md`). If two candidates touch the same file (even just for an import), do NOT batch them. Pick a third candidate that's truly disjoint, or batch just one.
- **Risk balance**: avoid batching 3 `High`-risk slices at once. Mix: 1 High + 2 Medium, or 3 Medium, or 2 Medium + 1 Low.
- **Dependency check**: confirm each slice's `Dependency` column shows `merged` or `—`. If a dep is `in-progress` or `audit-pending`, do NOT start the dependent slice — pick a different one.

### Auth-critical discipline (B11 + others)

Several of your slices are flagged `Risk = High` — auth-critical work. For these, your executor audit pass must specifically check:

- Every change touches the auth layer or hash-chained audit log
- New proxy routes are idempotent + audited + role-gated + tested (CLAUDE.md "Proxy & API Conventions")
- Cites `docs/_audits/code_health/a1_proxy_bug_root_cause.md` patterns where relevant
- For B11: redemption codes go in request bodies or short-TTL opaque codes, NEVER in URL parameters
- For any RLS change: confirms `OperatorScopedRepository` primary defense + RLS policy backup

If any of these checks fails on auth-critical slices, do NOT send back to sub-agent — escalate to operator directly. Auth-critical mistakes cost more than ordinary mistakes.

### Base-drift guard

Every PR opens with `--base master`. Never stack PRs. If you find yourself wanting to base off another open branch — STOP and pick a different slice.

### What to do when no `assigned` slices remain for you

1. Check `audit-pending` slices waiting on operator approval — there may be feedback to address on one of yours.
2. Check the lane index for cross-references — Codex lane may have merged a piece you depend on, unblocking new slices.
3. If genuinely idle: post in the chat:
   > Claude lane executor idle — all my slices are `in-progress`, `audit-pending`, or `merged`. Open PR count: N. Awaiting operator pings.

### Reporting

After each batch closes (all PRs opened or escalated), report one line per slice:

```
Slice <id>: PR <url> opened (size, risk, gate). Self-audit ✓ + executor audit ✓. <bail-out flags or 'clean'>.
```

Then immediately start the next batch.

For escalations:

```
Slice <id>: escalated after 2 send-backs. Pattern: <one-line>. Authority anchor: <doc:line>.
```

### Hard rules

- **Do NOT merge anything.** Orchestrator merges.
- **Do NOT update trackers, lane indices, or the wave ledger.** Orchestrator does.
- **Do NOT skip the executor audit pass.** A PR opened with only a self-audit table will be sent back by the orchestrator.
- **Do NOT batch slices with overlapping file scope.** Sub-agents must work disjoint file sets.
- **Do NOT cross lanes.** If a slice surfaces a bug in a Codex-owned file, write a cross-lane note in the PR — do NOT fix it.
- **Do NOT use `--no-verify` or skip CI gates.** Investigate failures, fix them.
- **Do NOT redeploy / push to Production1 / touch live billing or KMS.** Operator approval first.
- **Do NOT run the watcher cron pattern.** That's orchestrator-only.

Begin by reading the ledger and picking your first batch. Spawn sub-agents. Report back when the first PR is opened.

## END PROMPT
