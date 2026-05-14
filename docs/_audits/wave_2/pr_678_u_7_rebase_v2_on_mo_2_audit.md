# PR #678 audit — U-7 Mobile UX polish bundle (rebased v2 on MO-2)

**PR:** [#678](https://github.com/SaidKhan005/forge-flow-demo/pull/678)
**Slice:** U-7 from `docs/_indices/WAVE_2_LEDGER.md` (debug.md MO-3a/b, MO-4, MO-5a/d, MO-6, MO-7c/d, MO-S)
**Supersedes:** [PR #674](https://github.com/SaidKhan005/forge-flow-demo/pull/674) (which itself superseded [PR #666](https://github.com/SaidKhan005/forge-flow-demo/pull/666))
**Worker branch:** `claude2/u-7-rebase-v2-on-mo-2`
**Worker commit:** `ddaf9409`
**Auditor:** Claude2 (lane orchestrator)
**Audit date:** 2026-05-14
**Slice gate:** `auto`

## Verdict

**`approve-for-merge`** — clean. Second rebase delivered surgically. 38/38 tests pass.

## What this PR is

The U-7 mobile UX cleanup, layered on top of master's MO-1 + MO-1-FU + MO-2. The substantive audit (per-sub-section change list, VERIFY-FIRST verdicts, disclosed skips, scope discipline) was already done in `docs/_audits/wave_2/pr_674_u_7_rebase_on_mo_1_audit.md`; that content carries forward unchanged. This audit doc focuses on the second-rebase deltas.

## Rebase v2 delta

**Single conflict region:** `lib/screens/settings_screen.dart`, head of the Setup tab body.

- **Master's MO-2 (PR #676 / `e16dff45`) brought:** Covers Setup section as the FIRST item in the Setup tab body. Adds a `SettingsCoversSetupSection` mount at the top.
- **U-7 brought:** the MO-3a/MO-3b Business-timing comment block + the subtitle removal on Business timing.

**Resolution:** MO-2's Covers Setup section preserved verbatim at the top (lines 296-306); U-7's MO-3a/MO-3b comment + Business timing subtitle removal applied AFTER (lines 311+). Final Setup tab body order:

1. **Covers Setup** (MO-2, lines 296-306) — first item
2. **Business timing** (U-7 description dropped, lines 311-316)
3. **Wage setup** (U-7 description dropped, lines 331-337)
4. **Demo vs live data** (MO-1-FU's Demo→Live switch placement preserved, lines 364-369)

Tab list order from U-7's first rebase preserved: `[Setup, Data (MO-1 gated), Account]`. The 3 other U-7 files (`settings_active_sessions_section.dart`, `settings_data_sections.dart`, `settings_timing_authority_section.dart`) cherry-picked cleanly — MO-2 didn't touch them.

## Pattern B independent audit

| # | Lens | Result | Cite / evidence |
|---|------|--------|------|
| 1 | Slice scope match | ✅ | 4 files match U-7 scope (same as PR #674); rebase added no out-of-scope changes |
| 2 | Authority alignment (debug.md MO-3..MO-7) | ✅ | per-line debug.md citations preserved from PR #674's content |
| 3 | HP #11 | N/A | UX cleanup |
| 4 | RLS-ready schema | N/A | UI-only |
| 5 | Demo-mode neutrality | ✅ | MO-1-FU's Demo→Live switch placement preserved bit-identical |
| 6 | Frozen `lib/data/` untouched | ✅ | confirmed |
| 7 | `package:postgres` scope | N/A | no postgres imports |
| 8 | Proxy size lint | N/A | advisor_proxy untouched |
| 9 | `dart analyze --fatal-infos` (touched files) | ✅ | worker reported "No issues found" on all 4 touched files |
| 10 | Test suite | ✅ | rebase worker re-ran `flutter test --no-pub`: **38/38 passed** (13 settings_screen_collapse + 18 active_sessions+mfa + 7 covers_setup). MO-2's own test suite (`settings_covers_setup_section_test.dart`) not regressed. |
| 11 | Live UI check (adb on Samsung A54) | partial — disclosed | adb empty in worker env; deletion-heavy UX + 38/38 tests are strongest signal |
| 12 | No `--no-verify` | ✅ | canonical hooks ran |
| 13 | No tracker/ledger edits | ✅ | clean |
| 14 | UX writing standard | ✅ | inherited from PR #674 — "Last active …" meta line + section comments read as training register |

## Notable

- **No drift across the U-7 cascade:** the original [PR #666](https://github.com/SaidKhan005/forge-flow-demo/pull/666)'s 25/25 test count → [PR #674](https://github.com/SaidKhan005/forge-flow-demo/pull/674)'s 31/31 test count → [PR #678](https://github.com/SaidKhan005/forge-flow-demo/pull/678)'s 38/38 test count, each rebase adding the next master commit's tests (MO-1 / MO-1-FU collapse tests → MO-2 covers setup tests). No tests were dropped or muted across the cascade.
- **Worker also caught a prompt typo:** "the prompt mentioned `settings_screen_covers_manual_entry_test.dart`, which does not exist; the actual MO-2 test is `settings_covers_setup_section_test.dart`." The worker correctly ran the right test file rather than skipping silently.
- **MP-1 follow-up rebase still pending:** PR #671 (MP-1, operator-gated) also modifies `lib/screens/settings_screen.dart`. Once U-7 merges, MP-1 will need a follow-up rebase before its eventual merge. Mechanical, will dispatch on operator approval.

## Operator decisions surfaced

None.

## Recommended next step

1. Add this audit summary as a comment on PR #678.
2. Merge PR #678 via `gh pr merge 678 --merge --delete-branch`.
3. Close PR #674 with a supersession comment pointing at #678's merge.
4. Main orchestrator updates `WAVE_2_LEDGER.md` row U-7 to `merged` on next sweep.

## Wave 2 ledger impact

Slice U-7 transitions `assigned` → `merged`. PR # `678`, `merged_at: 2026-05-14`. PR #674 closed as superseded.
