# Account Rollover Retirement Plan

Date: 2026-05-19

## Goal

Retire Account-screen rollover editing because Business Timing is now the source of truth for business-day start.

## Scope

- Hide the Account UI control that lets operators edit rollover hour.
- Keep legacy rollover values readable where Account still needs to display compatibility state.
- Stop Account saves from sending `rolloverHour` on operator account writes.
- Stop Account saves from sending `businessDayRolloverHour` on location account override writes.
- Update focused Account screen and web-account gateway tests under `test/operator_web/**`.

## Non-Goals

- Do not edit the Business Timing editor or org-unit authoring flows.
- Do not touch projection retry code, Data Accuracy, migrations, or schema.
- Do not drop or stop reading legacy rollover columns.

## Implementation Notes

- `lib/operator_web/screens/account_screen.dart` should keep read-only legacy display copy in the business-day card and direct operators to Business Timing for business-day start edits.
- `lib/operator_web/services/web_account_gateway.dart` should preserve response parsing for legacy fields, but Account write payloads should omit rollover fields.
- Tests should pin absence of retired rollover write keys while retaining compatibility reads.

## Verification

- Run focused Account screen and web-account gateway tests.
- Run focused `dart analyze` on changed Dart files.
- Run `dart run tool/ux_em_dash_lint.dart`.
- Run `git diff --check`.
