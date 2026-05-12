# Audit Chunking + Merge-Conflict Playbook

Status: Active
Owner: orchestrator (main chat) — used when auditing any agent or Codex worktree PR.
Authority: Tier-2; subordinate to `docs/contracts/**` and the slice's stated contract anchors.

## When to invoke this playbook

Any of:

- The PR under audit changes **> 20 files** OR **> 5,000 LoC**.
- The PR touches **multiple contract surfaces** (proxy + auth + schema + admin lib, etc.).
- The PR rebases onto a master that has moved since the PR's base commit, and **conflict files include shared seams** (`advisor_proxy.dart`, auth gateways, RLS-touched repositories, schema migrations).
- The PR is the consolidation of more than one in-flight worktree (Codex's `admin-ux-slice2-hierarchy-management` is the canonical example).

For small slices (≤ 5 files, single surface), do a normal single-pass audit — the playbook is overkill.

## Phase 1 — Pre-rebase setup

Before any rebase begins:

1. **Snapshot every conflict-likely file.** For each file in the PR's diff that the orchestrator's prior PRs (or another in-flight Codex worktree) also changed, write the baseline:
   ```
   git diff <last-shared-base>..origin/master -- <file> > .claude/audit_workspace/<lane>/baseline_<file>.diff
   ```
   This is the "what Claude/Codex already shipped" record. Audit verifies it's preserved post-rebase.

2. **Backup branches.** `git branch backup/<lane>-pre-rebase <branch>` for every branch being rebased. If a rebase corrupts intent, diff post-rebase vs. backup to spot the loss.

3. **Rebase order (lowest overlap first).** When multiple branches need to land:
   - Branches with **no overlap** with already-merged work → rebase + push first. Smallest blast radius.
   - Branches with **adjacent-file overlap** (same directory, different file) → second.
   - Branches with **same-file overlap on shared seams** (advisor_proxy.dart, auth gateways, RLS repos) → last. Hardest conflicts.

4. **Enable `git rerere`** for the rebase: `git config rerere.enabled true`. Records resolutions so re-rebase replays them automatically.

## Phase 2 — Audit chunking (7 chunks by contract surface)

A large PR is too big for a single pass. Split by **contract surface**, not by file count. Each chunk gets its own anchor contract, its own audit section, and its own independent sign-off.

The canonical 7-chunk split (adjust if the PR's surface footprint differs):

| Chunk | Files | Contract anchor | Audit checks |
|---|---|---|---|
| **1. Schema migrations** | `db/migrations/*.sql` + `docs/contracts/migrations_summary.md` + migration runbooks | `hardening_rls_and_repository_pattern_contract.md` · `phase_7_55_time_boundary_contract.md` · leading-column lint | RLS policy stub present; `(operator_id, ...)` leads every fact-table B-tree index; `TIMESTAMPTZ` + denormalized `business_date DATE` on operator-scoped tables; expand-contract pattern for non-empty tables; `tool/migration_drift_scanner.dart --strict-docs` + `tool/migration_cutoff_lint.dart` pass |
| **2. Repository layer** | `lib/infrastructure/persistence/postgres/repositories/*.dart` | `hardening_rls_and_repository_pattern_contract.md` · `OperatorScopedRepository<T>` pattern | `operator_id` is the first WHERE filter on every read/write; no bare `current_setting()`; service-principal `actor_kind` handled in audit-write paths; `SET LOCAL` (transaction-scoped) GUCs only; four `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions used (not bare reads) |
| **3. Proxy + auth gateways** | `tool/advisor_proxy/advisor_proxy.dart` · `tool/advisor_proxy/proxy_bootstrap.dart` · `lib/services/auth/*_gateway.dart` · `lib/services/mfa/*.dart` | `phase_11a_decision_register.md` · proxy section of `CLAUDE.md` · `phase_9_scalability_decisions_2026-04-27.md` | `requireOperatorContext` shape · idempotency key handling on writes · JWT role handling (HP #4) · `/v1/...` route stability · idempotency table writes go to `proxy_requests` · service-principal JWT prefix `sp:` · hash-chained audit log · `runZonedGuarded` wrap intact · **diff vs prior orchestrator PRs to the same file must be preserved** |
| **4. Admin lib** | `lib/admin/**/*.dart` (routes/shell/handoff, screens, gateways, widgets, models) | `team_roles_hierarchy_console_parity_contract.md` · `CLAUDE.md` HP #11 (hierarchy-scoped settings) | Scope-aware filters · inheritance visualization · "effective value + inherited source" UI rule · operator/location pickers respect scope · seeded roles protected, custom roles operator-editable |
| **5. Tests** | `test/**/*.dart` (per-surface coverage) | Per-surface contracts (whichever contract chunk owns the code being tested) | Each new/changed test maps to a code-side change; no orphan tests; **prior orchestrator test fixes preserved** (run failing tests against pre-PR base commit to distinguish PR-introduced regressions from latent failures — see `~/.claude/projects/.../memory/feedback_audit_baseline_test_snapshot.md`); pre-existing failures from `docs/KNOWN_FAILING_TESTS.md` treated as expected |
| **6. Docs + runbooks** | `docs/**/*.md` · `runbooks/**/*.md` | `CLAUDE.md` authority order | Doc says what code does (drift check); `PROJECT_TRACKER.md` and `CLAUDE.md` stay pointer-only; detail lives in phase docs, contracts, runbooks, or `docs/_execution/**`; closed-phase docs retire to `docs/archive/**` |
| **7. Integration test harness + scripts** | `integration_test/**` · `scripts/**` · `tool/**` (non-proxy) | `docs/_walkthroughs/` standard · `slice_runtime_acceptance_contract.md` | Harness changes don't mask regressions (e.g., a relaxed assertion or a new skip); walkthroughs at click-path bar; runtime acceptance gates satisfied where applicable |

**Rules for each chunk:**

- Read the anchor contract **first**, before reading any code in the chunk.
- Read every file in the chunk yourself; do not infer content from filename.
- Cite `file:line` for every finding; verify the line by reading it.
- Verify named symbols still exist with `grep` before recommending checks against them.
- Write the chunk's audit section as a standalone block: it must make sense without reading the other 6 sections.
- Sign off the chunk before moving on. No "I'll come back to this" — finish, move, repeat.

## Phase 3 — Anti-hallucination disciplines (non-negotiable)

1. **Run the diff again before claiming what it says.** Long audit sessions degrade earlier summaries. Re-read the diff for each chunk; don't trust your own prior paragraph.
2. **Baseline test snapshot for any failing test.** Run the test against the pre-PR base commit. If it fails there too, it is latent — do not attribute to the PR under audit. (See `feedback_audit_baseline_test_snapshot.md` — lesson from the wrongly-blamed B3 attribution on the May-7 hardening pack's session-cap regression.)
3. **Cite line numbers.** Every finding has a `path/to/file.dart:NNN` anchor. The anchor is verified by reading line NNN.
4. **Don't summarize the whole PR in your head.** Use `Read` with `offset` + `limit` on big files. Never claim content you haven't read this session.
5. **Spawn sub-agents for chunks too big to hold.** A single file with > 500 lines of diff (Codex's `advisor_proxy.dart` at +988 is the canonical case) gets split further: dispatch one sub-agent per method or per route handler with a focused brief — "audit Codex's changes to X against prior PR #N changes to X; return ≤ 300 words; list preserved invariants and missing invariants." Sub-agents can't pollute main context.
6. **One chunk = one audit section.** Do not write "based on chunks 1-3, conclude X" until each chunk's finding is on paper. Each section is independent.
7. **Partial merge is OK. Send-back is OK. Bundled big-bang merge is NOT OK.** If chunk 3 (proxy) has a real conflict and chunk 1 (migrations) is clean, the migrations land first as a separate PR or commit; the proxy gets a follow-up agent.
8. **Pause and ask when ambiguous.** If a chunk feels unclear against the contract, stop and ask the operator a focused question rather than guessing. (The kind of question that nearly bit us with PR #477's wrong attribution — saved by Path C in the dispatch prompt.)
9. **Verify, don't recall.** If a memory or earlier audit doc cites `file:line`, re-grep before citing it forward. Memories can be stale; the code is the truth.

## Phase 4 — Conflict resolution discipline

When a conflict actually fires during rebase:

1. **Neither side wins by default.** Both prior intents must survive. If a conflict marker appears in `advisor_proxy.dart` between Codex's `+988` and the orchestrator's `+237` from PR #476, both semantics carry forward.
2. **`git rerere`** is on. Resolutions replay on re-rebase.
3. **Test gate before commit:** every conflicting file's test suite runs and passes. For the proxy: `flutter test test/advisor_proxy_test.dart` (218+ tests), `flutter test test/advisor_proxy_bootstrap_test.dart`, `flutter test test/auth_live_binding_test.dart`, `flutter test test/proxy_auth_session_ledger_writer_test.dart` (22+).
4. **HP re-verification post-merge.** HP #1, #2, #4, #11 from `CLAUDE.md` get a grep-based spot-check on the merged code, not just on the merger's intent.
5. **Audit doc cross-references both diffs:** `git diff <pre-rebase>..<post-rebase>` AND `git diff <prior-merged-PR>..<post-rebase>` for every conflicting file. A clean verdict requires the diff to show both intents survived.

## Phase 5 — Audit doc shape

Per PR under audit, create `docs/_audits/<wave>/pr_<N>_<topic>_audit.md` with this skeleton:

```markdown
# PR #<N> — <topic> — Audit

Auditor: orchestrator on <branch> (worktree path).
Diff: <files>, +<add> / -<del> vs origin/master at <sha>.

## Verdict

<approve-for-merge | material-gaps-send-back | reject>

## Per-chunk findings

### Chunk 1 — Schema migrations
<findings or "CLEAN">

### Chunk 2 — Repository layer
<findings or "CLEAN">

### Chunk 3 — Proxy + auth gateways
<findings — include both diffs cross-ref if conflict file>

### Chunk 4 — Admin lib
<findings or "CLEAN">

### Chunk 5 — Tests
<findings or "CLEAN">

### Chunk 6 — Docs + runbooks
<findings or "CLEAN">

### Chunk 7 — Integration test harness + scripts
<findings or "CLEAN">

## Conflict resolution log (only if rebase had conflicts)

| File | Pre-rebase base | Conflict resolved by | Post-merge HP re-verify |

## Follow-up items

| Item | Blocking? | Owner |

## Citations
```

**Verdict flips to `approve-for-merge` only when every chunk independently signs off and every conflict shows both intents preserved.**

## Phase 6 — Operator approval gates

Per `docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Agent-Led Slices," these surfaces require explicit operator approval (in chat) before merge regardless of audit verdict:

- Auth, RLS, BYPASSRLS, audit-log hash-chain, session ledger
- Schema (`db/migrations/**`), expand-contract migration steps
- Proxy contract changes (`/v1/*`, `/v2/*`, idempotency keys, JWT shape)
- Vendor connector live-rollout slices (`*.live.sandbox`, `*.live.prod`)
- Demo-mode reader-side carve-outs (HP #2)
- Billing, KMS, Cloud Run config, production secrets

For big slices that span multiple gated surfaces, get operator approval **per chunk**, not per PR.

## Anti-patterns this playbook prevents

- Auditing a 67-file PR in one pass; missing invariants because context filled up.
- Attributing a latent test failure to the PR under audit (PR #477's near-miss).
- Letting a rebase silently drop one side's changes because nobody compared post-merge to backup.
- Treating "Codex says it's done" as audit-clean.
- Bundling a multi-surface big-bang merge instead of chunked landings.
- Trusting your own earlier summary half-way through a long audit; not re-reading the diff.
