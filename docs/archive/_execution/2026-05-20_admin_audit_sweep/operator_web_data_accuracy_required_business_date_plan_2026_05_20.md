# Operator Web Data Accuracy Required Business Date Plan

Status: complete
Date: 2026-05-20
Branch: `codex/operator-web-data-accuracy-date-required`
Worktree: `.codex_worktrees/keyed-wire-doc-alignment-2`
Base: `origin/master` at `332b126d`

## Plain English Summary

- Operator Web now resolves the current business date before opening Data
  Accuracy.
- The Data Accuracy screen still has a fallback default of `2026-05-05`.
- That fallback is safe in many tests, but risky in app code because a future
  direct mount could save manual covers or service-period overrides to the old
  fixture date.
- This pass makes the date required so every caller must provide a real or
  test-explicit business date.

## Scope

- In scope:
  - `lib/operator_web/screens/data_accuracy_screen.dart`
  - Focused Operator Web Data Accuracy tests.
- Out of scope:
  - Business Timing route logic.
  - Data Accuracy server writes.
  - Mobile Covers Setup.
  - Legacy lunch/dinner/late-night API compatibility.

## Execution

- Remove the `2026-05-05` default from `DataAccuracyScreen.businessDateIso`.
- Update tests to pass explicit dates instead of relying on a hidden fallback.
- Keep the router-owned Business Timing resolution unchanged.

## Verification

- `flutter test test\operator_web\screens\data_accuracy_screen_test.dart`
  passed.
- `dart analyze lib\operator_web\screens\data_accuracy_screen.dart lib\operator_web\router\operator_web_router.dart test\operator_web\screens\data_accuracy_screen_test.dart`
  passed.
- `dart run tool\ux_em_dash_lint.dart` passed.
- `git diff --check` passed.
