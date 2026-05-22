# PR #1146 Wave 7 Audit - Notifications

Date: 2026-05-21
Auditor: Codex main session
Verdict: approve-for-merge

## Scope Checked

- Operator Web only.
- No Admin Web or mobile files touched.
- Notifications preference behavior remains per signed-in person.
- No new backend notification behavior invented.
- `Coming soon` rows remain disabled until their emitters exist.

## Diff Findings

- Notifications now states that choices apply to the signed-in account, not the whole business or a location.
- Push channel visible copy is clarified from `Phone` to `Mobile`; `Email` and `Inbox` remain visible.
- `Coming soon` and `Always on` visible copy is shorter, with deeper detail moved into shared Operator Web info popovers.
- Notification category panels and error state now reuse the shared Operator Web panel/banner primitives.

## Verification Reviewed

- `flutter test test/operator_web/screens/settings_notifications_screen_test.dart` passed.
- Targeted `dart analyze` passed.
- `dart run tool/ux_em_dash_lint.dart` passed.
- `git diff --check origin/master...HEAD` passed.
- Operator Web production build passed.
- Browser QA rendered `/notifications` from the built Operator Web bundle and confirmed the personal preferences banner, Mobile/Email/Inbox channel labels, and shared panel styling.
