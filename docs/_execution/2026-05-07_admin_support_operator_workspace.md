# Admin Support Operator Workspace

Date: 2026-05-07
Worktree: `.codex_worktrees/admin-support-operator-view`
Branch: `codex/admin-support-operator-view`
Source commit: `c5521a23` (`origin/master`)

## Objective

Consolidate the admin-side support flow into the operator-support shape:

1. F&F staff signs in to Admin Console.
2. Staff chooses a business account and location scope.
3. Staff opens a scoped support workspace.
4. Staff works across People, Access, Security/Audit, and Vendors.
5. Existing admin gateways remain authoritative for reads and mutations.

## Implementation

- Added `support-operator-view` admin route and kept the operator/location scope in the existing `AdminRouteHandoff`.
- Added `SupportOperatorViewAdminScreen`, a tabbed workspace that composes the existing admin-backed:
  - People: `MembersAdminScreen`
  - Access: `RolesHierarchySessionsAdminScreen`
  - Security & audit: `AuditedSupportActionsAdminScreen`
  - Vendors: `VendorConnectionsAdminMount`
- Added a primary `Support view` action on Business accounts and each location row.
- Simplified side-nav labels from `Team & roles`, `Access & hierarchy`, and `Audit & support` to `People`, `Access`, and `Security & audit`.
- Kept mutations behind existing `super_admin` edit gates, admin reason prompts, idempotency keys, and gateway-side authorization.
- Left per-location vendor lifecycle actions intentionally not wired when no live gateway is present; the workspace shows the existing read-only "not routed" state instead of demoing fake lifecycle data.

## Browser Evidence

Local server:

```powershell
flutter run -d web-server --web-port=8210 --web-hostname=127.0.0.1 -t lib/main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true
```

Browser Use smoke:

- Signed in as `super.admin@forgeflow.test` in demo auth.
- Business accounts rendered `Demo Diner Co.` with a primary `Support view` action.
- `Support view` opened `Support workspace` scoped to `Demo Diner Co. / Toronto Yorkville`.
- People tab rendered member filters, summary, and mutation actions.
- Access tab rendered role policy, hierarchy, and sessions sub-tabs.
- Security & audit tab rendered audit filters and support action summary.
- Vendors tab rendered the intentionally read-only "Lifecycle actions are not live" state.
- Console logs: only Flutter's normal viewport meta replacement warning from `dart_sdk.js`.

## Verification

Passed:

```powershell
flutter analyze
flutter test test/admin_shell_widget_test.dart test/admin_operator_location_screen_test.dart test/admin/screens/support_operator_view_admin_screen_test.dart test/admin/screens/members_admin_screen_test.dart test/admin/screens/roles_hierarchy_sessions_admin_screen_test.dart test/admin/screens/audited_support_actions_admin_screen_test.dart test/admin/vendor_connections_admin_mount_test.dart
flutter test test/services/auth/password_change_service_test.dart test/services/auth/proxy_refresh_token_revoker_test.dart test/services/auth/recaptcha_v3_verifier_test.dart test/services/auth/recovery_code_attempt_limiter_test.dart test/services/auth/recovery_code_consumer_test.dart test/org_units_repository_live_binding_test.dart
flutter build web --release --target=lib/main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true
```

Runner-sensitive:

```powershell
flutter test test/services/advisor/advisor_model_config_service_test.dart test/tool/advisor_proxy/admin_idempotency_reclaim_test.dart
```

Those two HTTP-server tests fail under `flutter test` because Flutter's test binding forces `HttpClient` responses to HTTP 400. The failure is runner/environment behavior, not from this support workspace change.

GitHub Actions:

- PR checks were rerun after push and failed before any runner steps started.
- Check-run annotations report: "The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings".
- No GitHub-hosted job logs are available because runner allocation never began.

## Residual Risks

- Vendor lifecycle actions remain unsurfaced in this support workspace until an admin-side live `VendorConnectionsGateway` binding exists.
- MFA-required admin permission claims are still not plumbed through `AdminAuthSession`; seeded-role edit, MFA reset, paired erasure, and audit export remain false by default in production route shells.
