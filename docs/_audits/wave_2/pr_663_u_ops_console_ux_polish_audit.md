# PR #663 audit — U-Ops Console UX polish bundle (U-1 + U-3 + U-4)

**PR:** [#663](https://github.com/SaidKhan005/forge-flow-demo/pull/663)
**Slices:** U-1 + U-3 + U-4 from `docs/_indices/WAVE_2_LEDGER.md` (debug.md OW-0a/0b, OW-2b/c/e, OW-3a/b/d/f/g)
**Worker branch:** `claude2/u-1-u-3-u-4-ops-console-ux-polish`
**Worker commit:** `646d2e9c`
**Auditor:** Claude2 (lane orchestrator)
**Audit date:** 2026-05-14
**Slice gates:** all 3 `auto`

## Verdict

**`approve-for-merge`** — clean. Architecturally elegant decomposition. 244/244 widget tests pass on the touched-screen suite.

## Scope

Three Lane U slices bundled into one PR (deliberate Lane-U bundling per the Wave 2 prompt's cap discipline). 4 files, +56/-161 (deletion-heavy, expected for UX cleanup).

### U-1 (Login) — `lib/operator_web/screens/sign_in_screen.dart`
- **OW-0a (green logo):** removed. Sign-in screen now passes `showBrandMark: false` to the shared `OnboardingLayout`. The brand-mark widget itself is preserved for first-time-onboarding screens that still set the default `showBrandMark: true`.
- **OW-0b (subtitle "Use the same Forge & Flow operator account…"):** removed. Sign-in screen no longer passes `subtitle:` to `OnboardingLayout`.

### U-3 (Business Account) — `lib/operator_web/screens/account_screen.dart`
- **OW-2c (subtitle "These are the basics…"):** removed from `_Header`.
- **OW-2c (4 top widget tiles):** the `OperatorWebSummaryStrip` block (Business name / Region / Business week / Rollover tiles) deleted. Unused helpers (`_valueOrUnset`, `_capitalize`, `_formatRollover`) + the now-unused `OperatorWebSummaryStrip` import cleaned up. `_Header` simplified from Column → Row.
- **OW-2b / OW-2e (scope-sensitive labels):** SKIPPED with disclosure. `AccountScreen` does not currently receive an `OperatorWebManagementScopeOption` and the slice rule forbids introducing a new scope provider. Disclosed for Lane H follow-up.

### U-4 (Business Setup) — `lib/operator_web/screens/business_setup_screen.dart`
- **OW-3b (subtitle):** removed (`operator_web_business_setup_subtitle` Text widget deleted).
- **OW-3b ("Edit timing" → "Edit Time Settings", bigger):** rename + style change to `AppTextStyles.display16`. Existing typography style — no new style introduced.
- **OW-3d (4 scope/effective tiles):** the `_BusinessTimingSummary` class (Scope / Effective / Business day / Service periods tiles) deleted entirely.
- **OW-3f ("Effective now" label):** removed. The `_TimingStatusPill` for the effective card is gone (`trailing` parameter dropped from `_TimingPanel`).
- **OW-3f (simplify hierarchy labels):** the `_TimingPanel.trailing` slot removed — the panel header simplified.
- **OW-3g (service period — remove labels):** the per-row `_TimingStatusPill` for service-period source/rollover is removed.
- **OW-3g (midnight rollover note):** new note widget added conditionally (only when `bundle.servicePeriods.any((period) => period.rollsPastMidnight)`). Text: *"One period runs past midnight, so its sales count toward the business day it started in."* — plain English, training register, single sentence.
- **OW-3a (hierarchy-smart tab names):** SKIPPED with disclosure. `BusinessSetupScreen` receives `locationId` but not scope-kind; nav title is hardcoded in the router. Disclosed for Lane H follow-up (router-level work).
- **OW-3c (operator-read-back):** correctly SKIPPED as instructed (it's a Phase 2 walkthrough item, not a code change).
- **OW-3e (inheritance tree visualization):** correctly SKIPPED as instructed (Lane H slice H-2).

### Shared widget — `lib/operator_web/screens/shared/onboarding_layout.dart`
- `subtitle` parameter: changed from `required String` → `String? subtitle` (default null). When null, the entire subtitle row is omitted from the layout.
- `showBrandMark`: new optional parameter (default `true`). When `false`, the round Forge & Flow brand mark + wordmark above the step pill is omitted.

This is a clean, backwards-compatible expansion of the shared layout's API:
- Existing callers (onboarding click path: first-admin invite, password reset, MFA enroll, etc.) keep passing `subtitle:` and get the default `showBrandMark: true` — zero behavior change.
- Only the sign-in screen opts out of both, getting a leaner returning-operator render.

The worker correctly chose to extend the shared widget's API rather than fork or inline-copy it.

## Pattern B independent audit

| # | Lens | Result | Cite / evidence |
|---|------|--------|------|
| 1 | Slice scope match | ✅ | 4 files match U-1 + U-3 + U-4 scope; U-2 untouched; OW-3c/3e + OW-2d/2g correctly excluded with disclosure. |
| 2 | Authority alignment (debug.md OW-0a/0b, OW-2b/c/e, OW-3a/b/d/f/g) | ✅ | Per-row checks above all match the brain-dump's intent; deletions are surgical. |
| 3 | HP #11 (hierarchy-scoped) | ✅ + 2 disclosed gaps | `BusinessSetupScreen._EffectiveFieldRow` already shows the scope/source/value triple and is preserved. OW-2b/2e + OW-3a require scope-providers that don't yet exist — correctly flagged as Lane H follow-ups, not papered over. |
| 4 | RLS-ready schema | N/A | UI-only, no schema. |
| 5 | Demo-mode neutrality | ✅ | No `kDemoMode` branch added in any reader path. |
| 6 | Frozen `lib/data/` untouched | ✅ | Files list shows only `lib/operator_web/screens/**` paths. |
| 7 | `package:postgres` scope | N/A | No dart imports of `package:postgres` added; pure UI work. |
| 8 | Proxy size lint | N/A | `advisor_proxy.dart` not touched. |
| 9 | `dart analyze --fatal-infos` (touched files) | ✅ | Worker reported 0 issues on the 4 touched files. |
| 10 | Test suite | ✅ | Orchestrator re-ran `flutter test --no-pub test/operator_web/screens/` on the worker's branch: **244/244 tests passed** in ~17s. No `sign_in_screen_test.dart` exists in the repo (worker's report of "4 in-scope screen tests" was loose — actual coverage is the broader 244-test suite, which is the stronger signal). |
| 11 | Live UI check (Preview MCP) | partial — disclosed | Worker captured `flutter build web --release` green; live Preview render NOT attempted because Phase 0 finding P0-F5 (operator-web demo boot path fails the startup gate) was the reason cited in the dispatch prompt. Build green is the strongest signal available pre-P0-F5-fix; sufficient for rename + deletion-only UX cleanup at `gate: auto`. |
| 12 | No `--no-verify` | ✅ | Branch is `claude2/` (proper Wave 2 prefix); push went through cleanly because PR #657's hook fix merged before the worker pushed. |
| 13 | No tracker/ledger edits | ✅ | Files list contains only `lib/operator_web/screens/**`; ledger / DEBUG_MD / PROJECT_TRACKER untouched. |
| 14 | UX writing standard (plain English, training tone) | ✅ | The new midnight-rollover note reads as one short sentence a manager understands on first read. No abbreviations, no jargon, no engineering terms. |

## Notes on architecture quality

This PR demonstrates the right shape for shared-widget UX changes:

- **Optional `subtitle` instead of removing-and-restoring:** rather than removing the `subtitle` row from `OnboardingLayout` (which would break the 5+ onboarding-click-path callers), the worker made it nullable with a backwards-compatible default. Sign-in opts out; everyone else continues.
- **Conditional midnight note:** the new note only renders when at least one service period rolls past midnight. Doesn't add noise to the common case.
- **Disclosure over papering-over:** rather than fabricating a scope-resolution mechanism to "complete" OW-2b/2e/3a, the worker correctly disclosed them as Lane H follow-ups. The slice rule forbade introducing new scope providers, and the worker honored that line.

## Operator decisions surfaced

None. The 2 disclosed gaps (OW-2b/2e + OW-3a scope-sensitive labels) are properly routed to Lane H. No new operator decisions.

## Recommended next step

1. Add this audit summary as a comment on PR #663.
2. Merge PR #663 via `gh pr merge 663 --merge --delete-branch`.
3. Slices U-1, U-3, U-4 transition `assigned` → `merged`. Main orchestrator updates the rows on next ledger sweep.

## Wave 2 ledger impact

Three rows transition `assigned` → `merged` simultaneously: U-1, U-3, U-4. PR # `663`, `merged_at: 2026-05-14`.
