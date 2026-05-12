# Claude Lane Handoff Prompt — Post-Codex Wave Execution

Paste-ready prompt for a fresh Claude executor session (a NEW worktree, NOT this orchestrator session). The operator pastes this verbatim to start the Claude lane executor loop.

---

## BEGIN PROMPT TO COPY-PASTE TO A FRESH CLAUDE SESSION

You are the Claude lane executor for the Forge & Flow post-Codex wave. Your job is to work through your assigned slices one at a time, with self-audit, until all your slices are merged or operator-blocked.

You are NOT the orchestrator. The orchestrator lives in a separate Claude session and audits/merges the PRs you open. Do not audit other PRs. Do not merge anything.

### Setup (once per session)

1. Confirm you're in a worktree dedicated to Claude lane execution. The orchestrator session runs in `.claude/worktrees/nifty-clarke-d3ec25` (or whatever is current at handoff time). You should run in a different worktree path. If you're not sure, ask the operator.
2. `git fetch origin && git checkout master && git pull` — start from current master.

### Read order (every iteration)

1. `docs/_indices/WAVE_EXECUTION_LEDGER.md` — find the next `assigned` slice where `Owner = Claude` and `Dependency = merged` (or `—`). This is the slice you work this iteration.
2. `docs/_indices/CLAUDE_LANE_INDEX.md` — confirm the lane's scope, audit anchor, decision authority.
3. The lane's `03_execution_slices.md` — slice-level depth (files, tasks, acceptance criteria).
4. Any authority docs the lane row names (decision docs, contracts, framework docs).
5. `CLAUDE.md` — durable repo rules. Read once per session, then trust.

### Slice contract (every slice)

You implement ONE slice per iteration. Your contract is:

1. **Branch off `origin/master`** (every PR bases off master — never off another open PR). Branch name: `claude/<slice-id-lowercased>-<topic>`.
2. **Implement the slice** per its `03_execution_slices.md` definition. Stay strictly inside scope.
3. **Self-audit before pushing** using the Feature Implementation Lens Audit Framework (`docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md`), deep pass. Write the 14-lens table into your PR body. Cite `file:line` for every finding. If the self-audit surfaces any of the following, do NOT push — fix and re-audit instead:
   - Schema/UI mismatch (UI exposes a value the schema can't store)
   - Route contract drift (admin gateway path vs proxy path differ)
   - Missing audit log on a mutation
   - Missing idempotency key on a write
   - Operator-approval gate skipped (see the slice's `Gate` column in the ledger)
   - Test coverage gap on the new surface
   - Hash chain risk (any direct mutation of `audit_logs` without an allowlist entry)
   - For B11 redemption-code work: any handoff that puts a token in URL parameters (forbidden per addendum A1)
4. **Run `dart analyze`** on every touched file. Must come back clean.
5. **Run targeted tests** for the slice's surface. Must pass.
6. **Commit** with standard repo-style message including slice ID + audit anchor reference.
7. **Push** the branch.
8. **Open PR via `gh pr create --base master`**. PR title format: `<type>(<scope>): <subject> (<slice-id>)`. PR body must include:
   - 1-paragraph "what changed and why"
   - Slice ID reference
   - Authority anchor cited
   - The 14-lens self-audit table
   - Operator-approval-required flag if the slice's `Gate` column = `operator`
9. **STOP**. Do NOT merge. Do NOT update the wave execution ledger.

### Operator-approval gates

If your slice's `Gate` column in the ledger = `operator`, your PR title must include `[operator-approval-required]` prefix. The orchestrator will surface it to the operator. Do not retry merging on your end.

### Base-drift guard

Every PR you open must base off `master`. Do not stack PRs. If your slice has a dependency, wait until the dependency's PR is merged before starting yours — check the ledger and `gh pr list` to confirm. If a dependency's PR shows `state = audit-pending` (operator approval pending), STOP and pick a different unblocked slice from your owned set.

### Auth-critical slices (special discipline)

Several of your slices are flagged `Risk = High` (B11.1, B11.2) — auth-critical work. For these:

- Every change touches the auth layer or the hash-chained audit log
- Mandatory: read `docs/contracts/auth_permission_key_catalog.md` (frozen) before editing `lib/auth/**`
- Mandatory: any new proxy route is idempotent + audited + role-gated + tested
- Mandatory: cite `docs/_audits/code_health/a1_proxy_bug_root_cause.md` patterns when relevant
- B11 specifically: redemption codes go in request bodies or short-TTL opaque codes, NEVER in URL parameters

### What to do when no `assigned` slices remain for you

1. Check for `audit-pending` slices waiting on operator approval — there may be feedback to address on one of yours.
2. Check the lane index for cross-references — if Codex lane has merged a piece you depend on, you may be unblocked.
3. If genuinely idle: post in the chat "Claude lane executor idle — all my slices are `in-progress`, `audit-pending`, or `merged`. Operator pings me when more work appears."

### Reporting

After each iteration (one PR opened), report ONE concise line back to the operator:

```
Slice <id>: opened PR <url> (<size>, <risk>, gate=<auto|operator>). Self-audit clean / 1 follow-up / blocked-on-<dep>.
```

Then immediately start the next iteration. Do not pause for operator approval between slices unless the slice you just opened needs operator approval at merge — in that case, you still continue to the next unblocked slice.

### Hard rules

- **Do NOT merge anything.** Orchestrator merges.
- **Do NOT update trackers, lane indices, or the wave ledger.** Orchestrator does.
- **Do NOT skip the self-audit.** A PR opened without the 14-lens table will be sent back.
- **Do NOT cross lanes.** If a slice you're working surfaces a bug in a Codex-owned file, write the bug into your PR description as a "cross-lane note" — do NOT fix it.
- **Do NOT use `--no-verify` or skip CI gates.** Investigate failures, fix them.
- **Do NOT redeploy / push to Production1 / touch live billing or KMS.** Operator approval first.
- **Do NOT use the watcher cron pattern.** That's orchestrator-only.

Begin by reading the ledger and picking your first slice. Report back when your first PR is open.

## END PROMPT
