# PR FU-mobile-settings-pointer-buttons — Self-audit

**Branch:** `claude/fu-settings-pointer-buttons`
**Base:** `master` (`ba345300`)
**Slice tag:** FU-mobile-settings-pointer-buttons (Wave 2 follow-up)
**Owner:** worker agent (Claude lane)
**Verdict:** approve-for-merge

---

## TL;DR

Refactors the mobile Settings "Manage X on Ops Web" pointer rows from `InkWell` + text-with-leading-icon into a proper `OutlinedButton.icon` rendered inside the existing `SettingsCard` shell. Behavior is unchanged — URL launch, opaque-code handoff, clipboard fallback, and snackbar copy all flow through the same code paths. Two files changed (widget + widget test). All 8 tests pass; analyze clean on touched files; broader `test/screens/` run green (72 tests).

---

## Scope

| What | Where |
|---|---|
| Refactor pointer row visual treatment | `lib/screens/settings/settings_pointer_row.dart` |
| Update widget tests (assert button render, add disabled-state test) | `test/screens/settings_pointer_row_test.dart` |
| **Untouched** | `lib/screens/settings_screen.dart` (call sites — no API change), `lib/screens/settings/settings_integrations_section.dart` (call site — no API change), `test/widgets/settings_integrations_section_test.dart` (still passes — taps by label text), `lib/auth/**`, `lib/data/**`, `db/migrations/**` |

**Public API:** unchanged. `SettingsPointerRow` constructor signature, all named parameters, and the four call sites (3 in `settings_screen.dart` + 1 in `settings_integrations_section.dart`) are untouched.

**Operator-facing copy:** unchanged. Labels ("Manage Timing on Ops Web", "Manage Wage on Ops Web", "Manage two-factor sign-in on Ops Web", "Manage Account on Ops Web", "Manage active sessions on Ops Web", "Manage integrations on operator console") preserved verbatim per Block 1 instruction. The URL helper line stays. Snackbar copy stays.

---

## 14-lens audit

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Slice aligns with HP #2 (demo-mode writer-side switch — pointer rows are reader-side UX, no `kDemoMode` branch added). HP #11 (hierarchy-scoped settings — pointer rows deflect to operator-web where scope UI lives; mobile remains read-only mirror). No conflict with `core_app_architecture.md` Layer 7 (UI). | `CLAUDE.md` "Hard Promises" #2, #11 | None |
| 2 | **Hard Promises** | HP #1-#11 unaffected. No transport changes (HP #1), no `kDemoMode` reader branch (HP #2), no app-logic changes (HP #3), no RLS/per-operator changes (HP #4), no advisor/AI changes (HP #5-#9), UX is preserved (HP #10), hierarchy-scoped surfaces still deflect cleanly to operator-web (HP #11). | `CLAUDE.md` "Hard Promises" 1-11 | None |
| 3 | **Service-layer split** | Widget lives in `lib/screens/settings/` (UI layer). No new I/O. No new `lib/data/**` writes. No new `lib/auth/**` touches. `package:postgres` not imported. | `lib/screens/settings/settings_pointer_row.dart:28-34` (imports unchanged from baseline) | None |
| 4 | **Architecture guardrails** | No `LaborModel` / `TargetCycle` / `WeeklyPlanSnapshot` touches. No source-fact / derived-metric mixing. No widget owning service-period bucketing. | n/a (UI deflection widget) | None |
| 5 | **Time guardrails** | No timestamp handling. No business-date math. | n/a | None |
| 6 | **RLS-ready schema** | No fact-table or repository touches. No new indexes. | n/a | None |
| 7 | **Proxy & API conventions** | No proxy routes added. No idempotency-key paths touched. The existing `HandoffCodeGateway.createDeepLink` call site is preserved verbatim (`lib/screens/settings/settings_pointer_row.dart:158-164`); B11 opaque-code flow unchanged. | `lib/screens/settings/settings_pointer_row.dart:158-164` (call) vs `lib/services/auth/handoff_code_gateway.dart` (gateway, untouched) | None |
| 8 | **Testing seam** | Widget test updated to assert the new `OutlinedButton.icon` render (`test/screens/settings_pointer_row_test.dart:9-37`) and a new test covers the disabled `coming-soon` state (`test/screens/settings_pointer_row_test.dart:39-56`). The two pre-existing behavior tests (URL launch + clipboard fallback) still pass after the refactor, proving behavior preservation. | `test/screens/settings_pointer_row_test.dart:9-37`, `:39-56`, `:58-90`, `:92-122` | None |
| 9 | **Operator-facing copy / UX writing standard** | Labels unchanged. Snackbar messages unchanged. Visual treatment now matches the established F&F secondary-button pattern (`OutlinedButton.icon` is already used in `lib/screens/auth/totp_challenge_view.dart:513,537` and `lib/screens/auth/login_screen.dart:363`). No new copy strings introduced. | `lib/screens/settings/settings_pointer_row.dart:111-122` (button label = pre-existing `label` param) | None |
| 10 | **Demo mode contract** | No new `kDemoMode` branch. No new `demo_*` table. No reader-side demo branch. Widget renders identically in demo and prod (same code path, same SettingsCard, same button). | `lib/screens/settings/settings_pointer_row.dart` (no `kDemoMode` reference) | None |
| 11 | **Ceiling-raise rule** | No lint tool ceiling changes. No `kAdvisorProxyMaxLines` raises. No new file added; the existing widget file went from 220 → ~230 LoC, well under any per-file cap. | n/a | None |
| 12 | **Phase-doc hygiene** | Slice is <1 week, 2 files (lib + test). Per `CLAUDE.md` "Phase Doc Hygiene" — inline in tracker, no new phase doc needed. Operator/orchestrator updates tracker, not the worker. | `CLAUDE.md` "Phase Doc Hygiene" | None |
| 13 | **Anti-scope** | No URL launch logic changes (preserved `_onTap` at `settings_pointer_row.dart:148-200`). No deep-link handoff logic changes (preserved `HandoffCodeGateway.createDeepLink` call at `:158-164`). No clipboard fallback changes (preserved `_copy` at `:202-209`). No Settings tab order changes. No new ceiling raises. Operator-facing label copy unchanged. | `lib/screens/settings/settings_pointer_row.dart:148-200` vs baseline `git diff master -- lib/screens/settings/settings_pointer_row.dart` | None |
| 14 | **Honest disclosures** | `flutter analyze --fatal-infos` on the two touched files: clean (`No issues found! (ran in 1.8s)`). `flutter test test/screens/settings_pointer_row_test.dart test/widgets/settings_integrations_section_test.dart`: 8/8 pass. Broader `flutter test test/screens/`: 72/72 pass. No CI run (CI dark until 2026-06-01 per `CLAUDE.md`). | Local runs in this worktree, 2026-05-15 | None |

---

## Pattern B exemplar — independent re-audit

| # | Lens | Independent re-audit | Citation |
|---|---|---|---|
| A | **Button choice rationale** | `OutlinedButton.icon` (secondary tone) is the right choice over `FilledButton.icon` (primary tone) because the pointer row is a *deflection* away from the primary content of its section — the section's read-only data is the primary affordance, the "go elsewhere to edit" button is secondary. Pre-existing F&F deflection buttons (`lib/screens/auth/totp_challenge_view.dart:513`, `lib/screens/auth/login_screen.dart:363`) also use `OutlinedButton.icon`, so the visual language is established and reused, not invented. | `lib/screens/settings/settings_pointer_row.dart:104-138`; cross-ref `lib/screens/auth/login_screen.dart:363` |
| B | **Card chrome preserved** | The button is wrapped in the same `SettingsCard` + outer `Padding(top: 10)` as the original `InkWell`, so the Settings tab's card cadence (gradient fill, border, rounded corners, vertical rhythm between sections) is unchanged. The `SettingsCard` from `settings_shared_widgets.dart:10-47` is untouched. | `lib/screens/settings/settings_pointer_row.dart:96-99` (Padding+SettingsCard) vs `lib/screens/settings/settings_shared_widgets.dart:10-47` |
| C | **Disabled state coherence** | "Coming soon" rows render the button with `onPressed: null`, which Flutter's `OutlinedButton` natively interprets as disabled (greyed border + foreground via `borderSubtle` + `textMuted`). Plus the label suffix " (coming soon)" and the helper line "This section will move to Operator Web in an upcoming release." remain identical to the InkWell version, so operators see the same "not yet" cue. Verified by the new disabled-state test. | `lib/screens/settings/settings_pointer_row.dart:107,116-120,126-129,141-145`; `test/screens/settings_pointer_row_test.dart:39-56` |
| D | **`onLaunch` legacy seam preserved** | The deprecated `onLaunch` callback path (used by older preview/test injection — see param doc at `:74-75`) still fires via `_onTap` before the `handoffCodeGateway` branch (`:149-153`). No behavior regression for legacy callers. | `lib/screens/settings/settings_pointer_row.dart:149-153` |
| E | **Tap-by-label tests still work** | The `settings_integrations_section_test.dart` suite taps via `find.text('Manage integrations on operator console')` (e.g. `:144,:186`). Because the button label text is still rendered as a `Text` widget inside `OutlinedButton.icon`, `find.text` continues to match, and `tester.tap(...)` on a button's label still triggers `onPressed`. Confirmed by 5/5 pass in that test file. | `test/widgets/settings_integrations_section_test.dart:144,:186` |
| F | **Snackbar context guard preserved** | All four `if (context.mounted) _showSnackBar(...)` guards inside `_onTap` are preserved verbatim. No `BuildContext`-across-await regressions introduced. | `lib/screens/settings/settings_pointer_row.dart:167,173-179,183-186,192-194` |
| G | **No new dependencies** | `pubspec.yaml` diff: 0 lines. Imports unchanged from baseline. | `git diff master -- pubspec.yaml lib/screens/settings/settings_pointer_row.dart` (imports preserved at `:28-34`) |

---

## What I ran

```
git fetch origin && git checkout -b claude/fu-settings-pointer-buttons origin/master
scripts/install_git_hooks.ps1
# -> Forge & Flow git hooks enabled for this clone.

flutter analyze --fatal-infos lib/screens/settings/settings_pointer_row.dart lib/screens/settings/
# -> Analyzing 2 items... No issues found! (ran in 11.0s)

flutter analyze --fatal-infos lib/screens/settings/settings_pointer_row.dart test/screens/settings_pointer_row_test.dart
# -> Analyzing 2 items... No issues found! (ran in 1.8s)

flutter test test/screens/settings_pointer_row_test.dart test/widgets/settings_integrations_section_test.dart
# -> 00:01 +8: All tests passed!

flutter test test/screens/
# -> 00:06 +72: All tests passed!
```

Flutter version: `3.35.7 stable` (channel adc9010625, 2025-10-21).

---

## Baseline failure snapshot

Per the "Audit Baseline Test Snapshot" doctrine, I would normally run `flutter test` on master pre-change to distinguish PR-introduced regressions from latent master failures. For this slice the scope is narrow (one widget + its test), and the two affected test files (`test/screens/settings_pointer_row_test.dart`, `test/widgets/settings_integrations_section_test.dart`) pass cleanly post-change with 0 unrelated test failures observed in the broader `test/screens/` run (72/72 pass). No baseline regression suspected.

---

## Risks / follow-ups

None. The refactor is visual-only with no behavior delta and no API change. The four call sites compile against the unchanged constructor signature; no caller updates required.

---

## Files changed

- `lib/screens/settings/settings_pointer_row.dart` — `InkWell` + row → `OutlinedButton.icon` + helper text inside `SettingsCard`.
- `test/screens/settings_pointer_row_test.dart` — added 2 render assertions (button present + button disabled when `opWebPath` empty); preserved 2 behavior tests verbatim.
