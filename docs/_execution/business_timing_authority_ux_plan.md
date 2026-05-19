# Business Timing Authority UX Plan

## Goal

Fix the timing-authority copy gaps without touching server create,
onboarding, proxy routes, migrations, or repository create flows.

## Scope

- Keep location timezone provenance separate from Business Timing profile
  provenance. The timezone comes from the location record; Business Timing
  profile source labels apply to business-day start, week start, and service
  periods.
- Stop Account from editing or submitting `weekStartDay`. Account should show
  the current value as read-only and hand operators to Business Timing for
  changes.
- Update the Business Timing editor hierarchy explainer so it no longer says
  the tree only shows business and location when an org-unit rung is present.

## Verification

- Update focused widget/service tests for the changed labels and read-only
  Account behavior.
- Run the focused tests, changed-file analyzer, and `git diff --check`.
- Commit, push, and open a ready pull request.
