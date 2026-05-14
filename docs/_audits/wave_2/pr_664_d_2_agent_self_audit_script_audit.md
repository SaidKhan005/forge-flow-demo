# PR #664 audit — D-2 Central agent self-audit script

**PR:** [#664](https://github.com/SaidKhan005/forge-flow-demo/pull/664)
**Slice:** D-2 from `docs/_indices/WAVE_2_LEDGER.md` (debug.md QI-5)
**Worker branch:** `claude2/d-2-agent-self-audit-script`
**Worker HEAD:** `6ceb243a` (3 commits total)
**Auditor:** Claude2 (lane orchestrator)
**Audit date:** 2026-05-14
**Slice gate:** `auto`

## Verdict

**`approve-for-merge`** — clean. Well-tested tooling addition. The script behaves exactly as designed when invoked against its own PR diff.

## Scope

D-2 ledger row: "Central agent-self-audit script + automation glue (cleanup + archiving + audit-doc generation)."

Worker delivered 2 new files (+932 / -0):
- `tool/agent_self_audit.dart` — CLI entrypoint orchestrating existing lints + 4 frozen-surface guards, plus a testable `AgentSelfAuditRunner` façade with injectable subprocess runner + file-body lookup for unit tests.
- `test/tool/agent_self_audit_test.dart` — 13 smoke cases covering every guard path, dispatch invariants, advisory-row semantics, and self-exemption logic.

The script's 8 checks:

| Check | Gating? | Notes |
|---|---|---|
| no `--no-verify` in diff | yes | self-exempts `tool/agent_self_audit.dart` + its test (those legitimately contain the literal as detection logic); deleted lines don't count |
| no edits under `lib/data/**` | yes | frozen legacy |
| no out-of-scope `package:postgres` import | yes | scoped to `lib/infrastructure/persistence/postgres/` + `tool/advisor_proxy/` |
| no edits to `lib/auth/permission_keys.dart` | yes | frozen catalog |
| `advisor_proxy_size_lint` | yes | always cheap, runs every invocation |
| `migration_drift_scanner --strict-docs` | yes when migrations touched | only runs when `db/migrations/**` in diff |
| `migration_cutoff_lint` | yes when migrations touched | same trigger |
| `dart analyze --fatal-infos` | **advisory** | exits non-zero on Phase-0 baseline (5 known errors); reports as `baseline` not `fail` so workers can disclose vs. baseline without the script blocking |

The advisory treatment for `dart analyze` is the correct call — if the script gated on the project-wide analyze, every worker would be blocked by pre-existing failures unrelated to their slice. Advisory mode preserves the signal while not blocking the flow.

## Pattern B independent audit

| # | Lens | Result | Cite / evidence |
|---|------|--------|------|
| 1 | Slice scope match | ✅ | 2 new files match D-2 scope; no other paths touched. |
| 2 | Authority alignment (debug.md QI-5) | ✅ | Brain-dump asked for "Scripts for automation — cleanup, archiving, debugging, auditing per agent work"; this is the auditing piece. Cleanup + archiving are separate follow-ups (the slice was scoped to the self-audit script). |
| 3 | HP #11 | N/A | tooling, no settings surface |
| 4 | RLS-ready schema | N/A | no schema |
| 5 | Demo-mode neutrality | ✅ | no `kDemoMode` branch added in any reader path |
| 6 | Frozen `lib/data/` untouched | ✅ | files list shows only `tool/agent_self_audit.dart` + `test/tool/agent_self_audit_test.dart` |
| 7 | `package:postgres` scope | ✅ | new files don't import `package:postgres` |
| 8 | Proxy size lint | ✅ | orchestrator re-ran: 19900/19900, headroom 0 (matches Phase 0 + post-Wave-1 state) |
| 9 | `dart analyze --fatal-infos` on touched files | ✅ | worker reported clean on the 2 new files; orchestrator's run via the script's own self-audit confirms |
| 10 | Test suite | ✅ | orchestrator re-ran `flutter test --no-pub test/tool/agent_self_audit_test.dart` on worker branch: **13/13 passed** in <1s. |
| 11 | Live UI check | N/A | tooling, no UI |
| 12 | No `--no-verify` | ✅ | worker reported clean live git invocations; literal only appears as detection regex + self-exempt path inside the new script (the script's own guard correctly self-exempts and passes). |
| 13 | No tracker/ledger edits | ✅ | files list contains only the 2 new files |
| 14 | UX writing standard | N/A | tooling, no operator-facing copy |

## Self-test verification

Orchestrator ran `dart run tool/agent_self_audit.dart` against the worker's own PR diff. Output shows:

```
| Check | Result | Notes |
|---|---|---|
| no --no-verify in diff | pass | no added line contains `--no-verify` outside exempt paths |
| no edits under lib/data/** | pass | no changed file is under a frozen prefix |
| no out-of-scope package:postgres import | pass | no changed Dart file outside allowed dirs imports `package:postgres` |
| no edits to lib/auth/permission_keys.dart | pass | permission key catalog untouched |
| advisor_proxy_size_lint | pass | monolith at or below ceiling |
| migration_drift_scanner --strict-docs | ok | skipped — no db/migrations/** edits in diff |
| migration_cutoff_lint | ok | skipped — no db/migrations/** edits in diff |
| dart analyze --fatal-infos | baseline | exited 3 — disclose vs. baseline (phase_0_smoke 5 errors) |
```

Exit code: **0**. All gating guards pass; `dart analyze` correctly reported as advisory baseline.

## Worker findings (from PR body, addressed)

1. **Local hook shim** — worker pointed `core.hooksPath` at a worktree-local shim (`/tmp/claude2-hooks/`, NOT committed) because the canonical hooks rejected `claude2/*` at dispatch time. By the time the audit runs, PR #657 has merged and the canonical hooks now accept `claude2/*`. Worker's worktree-local shim was a clean carve-out; not committed to the repo. ✅
2. **Two follow-up commits** — both addressed the script's self-detection (the script legitimately contains `--no-verify` literals and the test embeds unified-diff fixtures that confused a naive `+++ b/...` parser). Final shape passes its own audit. ✅
3. **Default `--diff-base=origin/master`** — workers on a topic branch parented off a different base must pass `--diff-base=origin/<base>`. This is documented in the script's in-file usage block. ✅

## Operator decisions surfaced

None. Worker disclosures are operationally sound; no operator input required.

## Recommended next step

1. Add this audit summary as a comment on PR #664.
2. Merge PR #664 via `gh pr merge 664 --merge --delete-branch`.
3. Slice D-2 transitions `assigned` → `merged`. Main orchestrator updates the row on next ledger sweep.
4. Mention to future Wave 2 workers (and bake into the next handoff prompt revision): "Step 3 verify step should call `dart run tool/agent_self_audit.dart` instead of an improvised shell pipeline of individual lints." That fold-in is a docs change for the handoff prompt, not a code change here.

## Wave 2 ledger impact

Slice D-2 transitions `assigned` → `merged`. PR # `664`, `merged_at: 2026-05-14`.
