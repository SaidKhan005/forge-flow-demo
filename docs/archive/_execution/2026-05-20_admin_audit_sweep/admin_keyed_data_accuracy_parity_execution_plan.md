# Admin Keyed Data Accuracy Parity Plan

Status: active execution plan
Created: 2026-05-18
Owner: Codex orchestrator

## Goal

Close the next highest-risk gap after per-daypart server parity:
F&F Admin must read and write the same keyed service-period data accuracy rows
that Operator Web already uses.

## Plain English Summary

- Admin currently still summarizes covers as Lunch / Dinner / Late Night.
- Admin has a service-period override dialog, but the live proxy route is not
  wired, so the button is not release-ready on the real backend.
- Operator Web already has the keyed service-period card and gateway path.
- This slice makes Admin match that model without changing migrations or live
  databases.

## Scope

- Add admin proxy route support for:
  - `GET /v1/admin/data-accuracy/service-period-settings/{operator}/{location}`
  - `PATCH /v1/admin/data-accuracy/service-period-settings/{operator}/{location}`
- Extend the admin proxy gateway interface and repository gateway.
- Make the Admin table show keyed service-period rows when present.
- Make Admin refresh include service-period rows for visible locations.
- Add route, gateway, and widget tests.

## Out Of Scope

- No live Firebase, Cloud Run, provider, billing, production database, or
  staging mutation.
- No schema migration changes.
- No tracker completion claim.
- No removal of legacy Lunch / Dinner / Late Night compatibility.

## Acceptance

- Super-admin can read keyed service-period rows through the admin proxy.
- Super-admin can write a keyed service-period override through the admin proxy.
- F&F support can still read but cannot write.
- Admin UI displays arbitrary service-period keys such as `breakfast`.
- Existing three-period fallback still renders when no keyed rows exist.
- Targeted admin/proxy tests pass.

## Execution Evidence

- Added admin proxy GET/PATCH service-period settings routes.
- Added repository gateway read/write support for
  `public.data_accuracy_service_period_settings`.
- Hydrated Admin data-accuracy rows with keyed service-period settings.
- Updated the Admin table to display arbitrary keyed service periods when rows
  exist, while preserving the legacy three-period fallback.
- Added route tests for read/write/ff_support denial.
- Added widget coverage for a `breakfast` service-period row.

Verification:

- `flutter test test\proxy\data_accuracy_admin_routes_test.dart test\admin\data_accuracy_screen_renders_test.dart test\admin\data_accuracy_admin_override_writes_audit_test.dart --reporter expanded`
- `flutter test test\admin\data_accuracy_live_wiring_test.dart test\admin\data_accuracy_ux_framework_polish_test.dart test\admin\data_accuracy_polling_hierarchy_scope_screen_test.dart test\admin\data_accuracy_admin_gateway_initial_audit_log_test.dart --reporter expanded`
- `flutter analyze` on the changed admin/proxy files
- `git diff --check`

Remaining gaps after this slice:

- Forge/Flow/operator-web holistic UX parity still needs a broader walkthrough.
- No live/staging DB, proxy, Firebase, or cloud validation was run.
- Full repo analyzer still has known unrelated baseline failures outside this
  work.
