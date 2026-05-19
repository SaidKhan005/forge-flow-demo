# Admin Rollover Retirement Plan

Date: 2026-05-19

## Plain English Summary

- Gap: Operator Web Account no longer edits rollover hour, but F&F Admin still
  lets admins edit and PATCH the same legacy location rollover field.
- Risk: Business Timing is supposed to own business-day start, but admin edits
  can still move the old integer field and create split authority.
- Fix: remove admin rollover edit controls, omit retired rollover keys from
  location PATCH payloads, and make the admin proxy reject old PATCH rollover
  writes.
- Compatibility bridge: onboarding and add-location still pass the existing
  default value because the current admin proxy create contract requires it.
  Removing that create-time default needs a later backend slice that seeds
  Business Timing during operator/location creation.

## Scope

- `lib/admin/screens/operator_location_admin_screen.dart`
- `lib/admin/models/operator_location_admin_models.dart`
- `lib/admin/services/operator_location_admin_gateway.dart`
- `tool/advisor_proxy/advisor_proxy.dart`
- focused admin/proxy tests

## Non-Goals

- No schema changes.
- No Business Timing authoring changes.
- No Operator Web Account changes.
- No projection retry changes.
- No onboarding contract rewrite until create routes can seed Business Timing.

## Verification

- Focused admin widget/gateway tests.
- Focused proxy route tests.
- Focused analyzer.
- UX em dash lint.
- `git diff --check`.
