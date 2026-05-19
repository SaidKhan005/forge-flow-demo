# Post-1021 Deeper Gap Fix Execution Plan

Status: active execution plan for the deeper audit pass after PR #1021.
Base: `origin/master` at `e7e58190` (`fix: close post-1020 parity gaps (#1021)`).

## Plain-English Goal

Close the remaining real gaps found by the post-1021 graph-led audit without
reopening the surfaces that were just fixed.

## Fix Now

- Keep active target profiles pinned to their exact target cycle and profile
  version everywhere they are loaded, synced, or rebuilt.
- Make mobile sync reject partial active profile rows that have a target cycle
  but no target profile version.
- Make Learn labels and order use the closed timing identity for historical
  rows instead of today's active timing labels.
- Fix Data Accuracy provenance so keyed service-period values win over older
  scoped JSON fallback values.
- Mount the SendGrid key-rotation route in the proxy because Admin already
  exposes that action.
- Add the missing Operator Web Data Accuracy scope/effective-value banner
  before mutation controls.
- Add the missing mobile scope chips for timing and wage authority settings.
- Make closed-shift rollups use the closed-truth eligibility gate instead of
  trusting `status == closed` alone.
- Add focused regression tests, including old-DB upgrade coverage for the new
  Data Accuracy cache metadata columns.

## Document Or Defer

- Legacy `ShiftService.getWeekToDate` and the close-shift week-record gate
  still have older tests that count same-day app-local closes immediately.
  The live locked WTD path, distribution weights, History, and Learn are gated
  here; migrating the legacy helper needs a separate test/product cleanup.
- Archive/lean-out of older closed execution docs is lower-risk doc hygiene.
  It can happen in this wave only if it does not collide with runtime fixes.
- Broader mobile UX parity outside timing/wage authority remains outside this
  scoped pass unless a missing chip blocks the settings mutation promise.

## Worker Split

- Worker A owns Star Shifts and Learn identity:
  `wage_standard_context_service`, target profile projection/sync, Learn label
  resolver, and focused tests.
- Worker B owns Data Accuracy, proxy route, and settings scope UX:
  provenance migration/test, SendGrid proxy matcher, Operator Web banner, mobile
  timing/wage chips, and focused tests.
- Worker C owns closed-truth eligibility, migration proof, and doc cleanup:
  closed-shift DAO/builder path, upgrade test, active execution-doc status
  cleanup, and focused tests.

Workers are not alone in the codebase. They must keep edits inside their owned
files, avoid tracker changes, avoid `docs/ARCHITECTURE.md`, avoid graphify
updates, and report changed files plus tests.

## Verification Plan

- Run focused Flutter/Dart tests for each touched runtime surface.
- Run `dart analyze` on changed Dart files.
- Run `dart run tool/ux_em_dash_lint.dart`.
- Run `git diff --check`.
- Because this touches `lib/**`, `db/migrations/**`, and proxy code, run
  `tool/pre_merge_gate.sh` before merge and `tool/verify_pr_landed.sh` after
  merge from the main checkout using Git Bash.
