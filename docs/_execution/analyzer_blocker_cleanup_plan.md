# Analyzer Blocker Cleanup Plan

Status: ready for commit
Created: 2026-05-18
Owner: Codex orchestrator

## Goal

Remove the analyzer and test blockers left after the per-daypart/admin parity
slices, then pin the one behavioral drift that surfaced while proving the
repo-wide gates.

## Plain English Summary

- The integration harness imports `widgets/demo_mode_banner.dart`, but that
  widget file is missing.
- The app shell also needs to mount the banner so the existing integration
  helper remains truthful.
- One weekly-plan Postgres test uses `PackagePostgresPool` but does not import
  the file that defines it.
- Several legacy tests and tools had analyzer-only cleanup from Dart fix /
  formatter output.
- Schedule, Shift, and Full Week were still close to drifting because Schedule
  rounded locked daypart hours on its own. Schedule now uses the shared locked
  daypart reconciliation helper.
- One provider-credential fake did not mirror the production refresh-success
  contract, so the test was proving stale behavior.

## Scope

- Restore a mobile `DemoModeBanner` widget driven by
  `DemoModeStateNotifier`.
- Mount it once in `AppShell`, above the tab stack.
- Add the missing `PackagePostgresPool` import in the weekly-plan repository
  test.
- Keep Dart analyzer cleanup mechanical unless a failing test proves a real
  behavior gap.
- Route locked Schedule daypart subrows through
  `reconcileLockedDaypartIntHours`, matching Shift and Full Week.
- Update stale tests so they assert current product truth instead of old
  assumptions.
- Run targeted analyzer/tests.

## Out Of Scope

- No live provider, Firebase, Postgres, staging, or cloud action.
- No demo-mode state schema changes.
- No broad lint cleanup beyond the compile blockers.
- No migration, schema, or production data mutation.

## Execution Notes

- `flutter analyze` is clean.
- Targeted Flutter test batches passed for auth, provider credentials, proxy
  route coverage, Schedule/Shift alignment, demo-mode app wiring, integration
  routes, and advisor proxy utilities.
- Postgres repository tests were attempted with the repo's local Postgres URL,
  but the local database `forgeflow_test` is not present on this machine. That
  gate is environment-blocked, not a code failure.
