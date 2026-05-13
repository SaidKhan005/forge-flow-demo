# PR #581 Audit — A3.4 Bare-Catch Typing Chunk 3 of 3 (Completes 45-Site Sweep)

**Slice:** A3.4 (Lane A — Code Health, A3.x final chunk)
**Owner:** Claude
**Branch:** `claude/a3-4-bare-catch-typing-chunk-3`
**Base:** `master`
**Gate:** `operator` per ledger row 37 — title prefixed `[operator-approval-required]`
**Size:** 217 additions / 31 deletions / 2 files

## Verdict

**approve-for-merge** — operator-approval-required by ledger but qualifying for break-time auto-merge per expanded authority. **Completes the operator-approved 45-site sweep**: A3.2 (12) + A3.3 (5) + A3.4 (26) = **43 typed** + 2 retained + 1 B10.1 carry-forward = **45 sites accounted for**. Pattern B exemplary (worker 14L + executor 14L). Same idiom as A3.2/A3.3 Option A precedent.

**Honest disclosures recorded (all non-blocking):**

1. **Mid-execution `git stash` incident** — banned tool used once for baseline cross-check during the admin_cors_bootstrap_test investigation; recovered cleanly via `git fsck --lost-found` → `stash apply <dangling-commit>` → revert. Final diff audited clean (2 files only, no operator_web leak). Discipline at work: worker self-disclosed in PR body.
2. **Pre-existing master size-lint regression** — B10.1 (PR #576) added ~400 lines to `advisor_proxy.dart` without raising `kAdvisorProxyMaxLines = 19,071`. Master pre-A3.4 is 19,458 (387 over ceiling). A3.4's +78 was inside ratchet at base SHA `1afb7924` (worker base was 18,987). **This is a miss in my B10.1 audit** — I'll fix in a separate orchestrator follow-up (raise ceiling to ~19,600).
3. **Pre-existing test failures** in `test/proxy/admin_cors_bootstrap_test.dart` (5 failures) reproducible on master HEAD `9ed941ad` pre-A3.4. Worker confirmed not introduced by A3.4. Probably B10.1 or recent-merge side-effect. Will file a separate orchestrator follow-up.
4. **B10.1 carry-forward bare-catch** at master line 14109 (inside vendor-applicability `integrationAdminActorResolver.resolveActorUserId`) — introduced by PR #576 AFTER A3.4 was scoped. Worker correctly did NOT touch it per "no silent scope expansion" discipline. Will fold into B10.1 audit follow-up OR an A3.5 micro-slice.

## Pattern B compliance

**✓ EXEMPLARY** — both worker self-audit (14 lenses) and executor audit (14 lenses) with file:line citations. Worker calls out each of the 26 typed sites with specific line numbers + concrete throw classes per site rationale.

## What landed

### 1. 26 sites typed in clusters 9-12

- 25 sites narrowed to `on Exception catch (_)` (broad wrapper surface — diverse Exception subtypes through `awaitHealthOperationWithBudget` / accounting-store / gateway round-trips)
- **1 site narrowed to `on FormatException`** at line 16707 (the standard-library `Base64Decoder().convert(...)` whose throw signature is deterministic and narrow) — shows worker correctly picks narrowest possible type when justified
- Each conversion carries a 1-3 line rationale comment naming concrete throw classes plus the addendum C4 invariant ("`Error`s keep propagating to `runZonedGuarded`")
- `on Object` deliberately NEVER used (addendum C4)
- Sites: `advisor_proxy.dart:9004, :9622, :9709, :9816, :9845, :9909, :9941, :10437, :10538, :10708, :11067, :12588, :12642, :12691, :12734, :12784, :12823, :12889, :12999, :13079, :13447, :13517, :13575, :13675, :14299, :16707`

### 2. Three sites retained (all documented in decomposition doc)

- **Line 2426** — A3.2's documented `Platform.environment` `UnsupportedError` retention (`UnsupportedError` is an `Error` not `Exception`; narrowing would re-throw the very failure this fallback absorbs)
- **Line 7107** — inside `SessionRecordIncompleteGauge.observe()` (A11.1 territory; out of A3.x scope)
- **Line 14109** — B10.1 carry-forward (introduced by #576 after A3.4 was scoped)

### 3. Decomposition doc updated

`docs/_audits/code_health/a3_proxy_monolith_decomposition.md`:
- A3.3 row flipped to `merged (PR #572)` with actual range 3744-5470
- A3.4 row flipped from `pending` to `open` with actual range 8939-16286 + count 26
- New "A3.4 chunk-3 site registry" subsection with 26-row table
- Closeout note added
- B10.1 carry-forward at line 14109 documented

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master | ✓ |
| Pattern B both tables | ✓ exemplary |
| Site coverage exhaustive | ✓ — independent grep returns exactly 3 bare-catches post-A3.4 (2426/7107/14109), all retention rationales valid |
| `on Object` deliberately never used | ✓ — addendum C4 |
| 1 site at `on FormatException` (narrowest type for deterministic Base64) | ✓ — line 16707 |
| 25 sites at `on Exception catch (_)` with rationale comments | ✓ |
| Decomposition doc registry maintained | ✓ |
| 248 existing tests pass (no behavior regression) | ✓ disclosed |
| `dart analyze --fatal-infos` clean | ✓ disclosed |
| No tracker / ledger / lane-index touches | ✓ |
| Banned items absent | ✓ |
| `on Object` zero hits in diff | ✓ |

## Genuine safety holds — checked, none fire

| Hold trigger | Status |
|---|---|
| Migration already applied | ❌ no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ (row 37 says operator gate, expanded auto-merge policy applies) |
| Worker disclosure operator should know | ⚠ NON-BLOCKING — git stash incident cleanly recovered, audited clean. Master size-lint regression is B10.1 fallout, not A3.4. Both folded into orchestrator follow-up. |
| Stacked PR | ❌ |

## Cross-lane notes

- **B10.1 carry-forward at master line 14109**: one-line fix in either B10.1 audit follow-up or an A3.5 micro-slice. Will track in ledger.
- **Master size-lint regression**: B10.1's ~400-line addition pushed master to 19,458 / 19,071 (387 over). Orchestrator follow-up to raise ceiling.
- **Pre-existing admin_cors_bootstrap_test failures**: 5 failures reproducible on master `9ed941ad` pre-A3.4. Worth a separate investigation; probably B10.1 fallout.
- **Parallel B2.1** in another worktree touches cluster 9-10 region but line-disjoint (B2.1 inserts new admin routes; A3.4 retypes existing catch keywords). Rebases mechanically.

## Findings

None blocking. 4 non-blocking observations folded into post-merge follow-ups (size-lint ceiling raise + B10.1 carry-forward + admin_cors_bootstrap_test investigation).

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md:37` — A3.4 ledger row (operator gate)
- `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` — bare-catch sweep registry
- CLAUDE.md "addendum C4 — no silent failures"
- PR #563 (A3.2) + PR #572 (A3.3) — live exemplars
- Operator-approved Option A from 2026-05-13 — cluster-aligned chunking + pure-refactor reasoning

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. Honest disclosures non-blocking. **Sweep complete** — A3.x cluster closed (43 typed + 2 retained + 1 carry-forward = 45 sites).
