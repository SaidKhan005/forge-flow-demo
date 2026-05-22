# PR #1148 Wave 6 Audit - Data Accuracy

Date: 2026-05-21
Auditor: Codex main session
Verdict: approve-for-merge

## Scope Checked

- Operator Web only.
- Data Accuracy remains location-focused.
- Vendor Integrations, Business Timing, Account, Roles, Audit Log, Notifications, Locations, Admin Web, and mobile are untouched.
- Existing wage role save/delete/idempotency behavior is preserved.

## Diff Findings

- Data Accuracy now reads in the requested order: Labor, Covers, Data Freshness.
- Wage authority is embedded under Labor instead of appearing after Data Freshness.
- Wage role add/edit moved from inline row expansion to the shared Operator Web dialog shell.
- The wage authority section keeps the existing location, hierarchy, vendor applicability, blended wage preview, and gateway behavior.

## Verification Reviewed

- Worker reported focused Data Accuracy, Wage Authority, wage source, and covers source tests passing.
- Worker reported targeted `dart analyze` passing.
- Worker reported `dart run tool/ux_em_dash_lint.dart` passing.
- Worker reported `git diff --check origin/master...HEAD` passing.
- Worker reported Operator Web production build passing.
- Main session will run the repo pre-merge gate before merge.
