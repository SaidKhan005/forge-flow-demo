# Verification And Evidence Plan

## Targeted Local Gates

Run targeted tests per slice first. Use broader gates after shared seams change.

Suggested commands:

```powershell
flutter test test/admin/admin_hierarchy_scope_intent_test.dart
flutter test test/admin/admin_shell_widget_test.dart
flutter test test/admin/data_accuracy_polling_hierarchy_scope_screen_test.dart
flutter test test/admin/data_accuracy_ux_framework_polish_test.dart
flutter test test/admin/screens/roles_hierarchy_sessions_admin_screen_test.dart
flutter test test/admin/services/roles_hierarchy_sessions_admin_gateway_test.dart
flutter test test/admin/screens/audited_support_actions_admin_screen_test.dart
flutter test test/admin/vendor_connections_admin_mount_test.dart
flutter test test/admin/admin_vendor_connections_gateway_test.dart
flutter analyze
```

Add or update tests as slices land:

- setup tile no-popup routing
- shared split/tab workspace desktop/mobile
- business/org-unit/location scope expansion
- all businesses collapsed default state
- descendant location filtering
- scoped business/org-unit/location mutations
- hierarchy move controls
- hierarchy suspend/delete controls
- actor name + role + email log rendering
- polling calculator math and override behavior
- connected service API reachability status and unlock state
- plain-English launch/system/knowledge labels

## Browser Use Acceptance

Use fresh cache-bust URLs after each UI slice and again after all merges.

Screens to inspect:

- Business Accounts
- Business profile and setup launcher
- Hierarchy add/move controls
- Covers and Wage Data Accuracy
- Polling Setup
- People, Access, Roles
- Security, Audit, Sessions
- Support Logs
- Connected Services
- Per-location Vendor Integrations
- Timing
- System Health
- AI Metrics
- Plans and Limits
- Launch Controls
- Knowledge Base

Browser checks:

- Desktop viewport.
- Mobile/narrow viewport.
- Fresh cache-bust URL after rebuild.
- Route switching preserves or intentionally clears selected scope.
- Browser back returns to Business Accounts where expected.
- No setup tile opens a scope popup.
- No hidden route handoff silently falls back to Business Accounts.
- No visible text overlap.
- Buttons look clickable and have working disabled states.
- Empty/loading/error states are understandable.
- Safe mutations require confirmation/reason where applicable.

## Safe Mutation Matrix

Only run mutations on local/demo or approved preview data.

| Surface | Safe mutation checks |
|---|---|
| Business Accounts | Create business in demo/local, edit profile, add child org unit, add location, edit location, set primary, move location, move org unit, suspend/delete location, suspend/delete org unit. |
| Covers and Wage Data Accuracy | Business/org-unit/location covers source edit, wage source edit, walk-in handling edit, service-period edit, inherited value override, audit row display. |
| Polling Setup | Business/org-unit/location tier assignment, calculator value, manual override, default Regular tier behavior, change request status update, audit row display. |
| People/Access/Roles | Invite, role grant override, seeded role edit when allowed, custom role create/delete, member status changes. |
| Security/Audit/Sessions | Password reset initiation, reset MFA only with fresh permission, force logout non-current session, export audit when allowed. |
| Connected Services | Rotate key with one-time reveal, vendor connect/test/disconnect in demo/local, API reachability status refresh, unlock-state verification. |
| Support Logs | Filter requests, Relationship help, and Account help by business/org-unit/location, including multi-location org-unit branches, search, live tail toggle. |
| Launch Controls | Toggle non-destructive flag in demo/local; high-impact flag requires typed confirmation. |

## Performance Framework

Run the repo performance framework after shared workspace and final merge.

Minimum checks:

- Business Accounts initial load.
- Shared setup workspace route switch.
- Scope search with all businesses.
- Data Accuracy row filter with business/org-unit/location.
- Polling Setup row filter and calculator.
- Connected Services live status refresh.

Capture:

- command
- commit SHA
- environment
- timing summary
- JSON output path
- screenshot path if visual performance is checked

## UX Framework

Run the UX framework after each visible slice and at final closeout.

Checklist:

- plain-English copy
- no raw code IDs in primary UI
- consistent filters
- hierarchy selection is obvious
- disabled states say why
- buttons look clickable
- no nested cards inside cards
- responsive layout at mobile and desktop
- no text overflow or incoherent overlap
- visual hierarchy supports repeated operations, not a landing page

## Evidence Bundle

Create evidence under a dated execution folder, for example:

```text
docs/_execution/admin_hierarchy_ux_cleanup/evidence/2026-05-08/
  browser-use/
  tests/
  performance/
  ux/
  final_audit.json
  final_audit.md
  full_surface_inventory_results.json
```

`final_audit.json` should include:

- source commit
- deployed or local URL
- cache-bust value
- branches/PRs merged
- lens checklist status
- tests run
- Browser Use pages checked
- safe mutations run
- full surface inventory status
- skipped checks with reason
- residual product decisions

## Final Audit Checklist

- Old setup scope popup is not reachable from Business Setup buttons.
- Business Accounts is the hierarchy command center.
- Selected hierarchy row controls setup function scope.
- No selected hierarchy row defaults to business scope.
- All setup screens with filters use shared split/tab scope layout.
- Data Accuracy is renamed, reorganized, and editable at business, org-unit,
  and location scope with inherited/effective values.
- Polling is renamed and has calculator-first cost handling plus editable
  business/org-unit/location scoped assignments.
- People/Access/Roles remove visible members stat and humanize permissions.
- Actors in log screens show name, role, and email.
- Connected Services separates POS, Labor, Reservation and uses API reachability
  for live status and unlock state.
- Relationship help and Account help are wired.
- System Metrics is moved to AI Metrics.
- System/Launch/Knowledge surfaces avoid raw code language in primary UI.
- Plans and Limits follows shared hierarchy behavior.
- All safe/approved mutations work and are audit-logged.
- Performance and UX framework evidence is attached.
- Every route in `06_full_surface_inventory.md` has evidence.
