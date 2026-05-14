# PR #673 audit — U-6 Ops Console UX polish (rebased on H-1 + test cast fix)

**PR:** [#673](https://github.com/SaidKhan005/forge-flow-demo/pull/673)
**Slice:** U-6 from `docs/_indices/WAVE_2_LEDGER.md` (debug.md OW-10..OW-14)
**Supersedes:** [PR #668](https://github.com/SaidKhan005/forge-flow-demo/pull/668)
**Worker branch:** `claude2/u-6-rebase-on-h-1`
**Worker commits:** `d546bc72` (cherry-pick with conflict resolution) + `c84faa61` (test cast fix)
**Auditor:** Claude2 (lane orchestrator)
**Audit date:** 2026-05-14
**Slice gate:** `auto`

## Verdict

**`approve-for-merge`** — clean. The rebase worker delivered exactly what was asked: U-6's commit cherry-picked, the single `wage_authority_screen.dart` conflict resolved by preserving H-1's `HierarchyScopeNotice` block + applying U-6's `_Header` simplification, and the `polling_tier_status_card_test.dart:174` cast updated from `OutlinedButton` to `FilledButton`. 26/26 tests pass on the touched-screen suites.

## What this PR is

The same 13-file UX cleanup the original U-6 worker shipped in [PR #668](https://github.com/SaidKhan005/forge-flow-demo/pull/668), now layered on top of master's H-1 (`6e14bbf5` — HP #11 scope notice on Schedule + Wage Authority) and carrying the test cast fix the original worker couldn't catch (their `flutter test` never ran due to the Flutter 3.35.4 Windows tool crash).

For the substantive U-6 audit (per-sub-screen change list, VERIFY-FIRST verdicts, disclosed skips, etc.), see the prior PR #668 audit content embedded in PR #668's superseded comment. This audit doc focuses on the rebase-specific deltas.

## Rebase deltas

### Conflict resolution: `lib/operator_web/screens/wage_authority_screen.dart`

The only conflict between U-6 and master. Worker's resolution:

- **Master's H-1 (PR #659 / `6e14bbf5`) brought:** `_Header(locationName: widget.locationName)` widget invocation + a `HierarchyScopeNotice` block (lines 315-347 in the merged file).
- **U-6 brought:** simplified `_Header()` constructor call (the parameter became unnecessary after subtitle removal).
- **Merged result:** H-1's `HierarchyScopeNotice` block preserved verbatim at its master position (lines 315-347); U-6's `_Header` simplification applied at the call site (line 313). Both intents preserved, no behavior change to H-1's HP #11 logic.

Worker also verified `schedule_screen.dart` is NOT in U-6's scope (H-1 also touched that file, but U-6 didn't — so no second conflict).

### Test cast fix: `test/operator_web/widgets/polling_tier_status_card_test.dart:174`

```dart
- final OutlinedButton button = tester.widget<OutlinedButton>(buttonFinder);
+ final FilledButton button = tester.widget<FilledButton>(buttonFinder);
```

Worker committed this separately (`c84faa61`) so the audit diff is clean. The `button.onPressed, isNotNull` assertion on the next line works unchanged on `FilledButton`'s API.

This fix addresses the regression the original PR #668 introduced when U-6 promoted the tier-change button from `OutlinedButton` to `FilledButton.icon` (per OW-12h "tier-change button better") without updating the test cast.

## Pattern B independent audit

| # | Lens | Result | Cite / evidence |
|---|------|--------|------|
| 1 | Slice scope match | ✅ | 13 files match U-6 scope (same as PR #668); rebase work strictly inside scope |
| 2 | Authority alignment (debug.md OW-10..OW-14 minus carve-outs) | ✅ | per-row check from PR #668 audit still holds |
| 3 | HP #11 (hierarchy-scoped) | ✅ | H-1's `HierarchyScopeNotice` block preserved at the right place on `wage_authority_screen.dart` |
| 4 | RLS-ready schema | N/A | UI-only |
| 5 | Demo-mode neutrality | ✅ | no `kDemoMode` branch |
| 6 | Frozen `lib/data/` untouched | ✅ | confirmed |
| 7 | `package:postgres` scope | ✅ | no postgres imports |
| 8 | Proxy size lint | N/A | advisor_proxy untouched |
| 9 | `dart analyze --fatal-infos` (touched files) | ✅ | rebase worker reported clean on all 13 touched files |
| 10 | Test suite | ✅ | rebase worker re-ran `flutter test --no-pub test/operator_web/widgets/polling_tier_status_card_test.dart test/services/email/notification_event_fanout_test.dart`: **26/26 passed**. The previously failing button cast test now passes. |
| 11 | Live UI check (Preview MCP) | partial — disclosed | P0-F5 boot-gate-blocked + Developer Mode constraint. Deletion-heavy UX cleanup is low-risk for visual regression. |
| 12 | No `--no-verify` | ✅ | canonical hooks ran |
| 13 | No tracker/ledger edits | ✅ | clean |
| 14 | UX writing standard | ✅ | from PR #668: plain English, training register, "Request faster data freshness" + notification copy rewrites all read like operator-friendly explanations |

## Why the original worker missed the cast

Honest disclosure (not a failure): the original U-6 worker ran into a Flutter 3.35.4 Windows tool crash (`StateError: Bad state: No element in testCompilerBuildNativeAssets`) that prevented `flutter test` from running at all. They correctly disclosed this in PR #668's body and provided source-line evidence in lieu. They couldn't have caught the cast error because no test executed.

The rebase worker resolved the tool crash by running `flutter pub get` before `flutter test` (a hint the rebase prompt included). This is the lesson worth folding into future agent prompts: **always run `flutter pub get` first on a fresh worktree before `flutter test`**.

## Operator decisions surfaced

None. Same as PR #668's audit — no findings that would block merge.

## Recommended next step

1. Add this audit summary as a comment on PR #673.
2. Merge PR #673 via `gh pr merge 673 --merge --delete-branch`.
3. Close PR #668 with a final supersession comment pointing at #673's merge.
4. Main orchestrator updates `WAVE_2_LEDGER.md` row U-6 to `merged` on next sweep.

## Wave 2 ledger impact

Slice U-6 transitions `assigned` → `merged`. PR # `673`, `merged_at: 2026-05-14`. PR #668 closed as superseded.
