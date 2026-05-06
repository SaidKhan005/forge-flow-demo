// Phase 11W.8 — Operator Web Console Vendor Connections screen.
//
// Replaces the V1 placeholder. Mounted at
// `/locations/:location_id/vendor-connections`. Reads
// (operator_id, location_id) from the host context (operator-web
// session + URL param) and mounts the shared
// `VendorConnectionsWidget` from Phase 8 `8.0`. The widget tree is
// host-agnostic by design; this screen is the operator-web mount
// shell for it.
//
// Permission gate (per Phase 8 `8.0` auth catalog edit): the
// `integrations.configure` permission key
// (`PermissionKeys.integrationsConfigure` in
// `lib/auth/permission_keys.dart`; row in
// `docs/contracts/auth_permission_key_catalog.md`) gates this
// surface. Granted to `operator_admin` / `operator_owner`; denied
// to `location_manager`. The operator-web shell admits
// `location_manager` to the console at large for read-only views,
// so this gate is per-screen — a location-manager session reaches
// the side nav, taps "Vendor connections", and lands on the
// friendly forbidden surface explaining who manages connections.
//
// UX writing standard (per
// `docs/phases/phase_8/vendor_connections_admin_surface.md`):
// every operator-facing surface reads as if training the user as
// they use it. Brief inline explainers, plain English, no
// engineering jargon.
//
// INTEGRATOR HANDOFF — wiring the Notify-me capture flow
// ------------------------------------------------------
// 11W.8 ships the standalone `VendorLifecycleNotifyMeDialog` under
// `lib/operator_web/widgets/vendor_lifecycle_notify_me_dialog.dart`
// but does NOT wire it onto vendor rows inside
// `VendorConnectionsWidget`'s picker, because the widget API in
// Phase 8.0 does not expose an `onNotifyMeRequested` callback prop
// (see `docs/_walkthroughs/11W.8.md` "Upstream blockers"). When
// that callback lands, the integrator's checklist is:
//
//   1. Convert this class to `StatefulWidget`, accept
//      `repository: VendorLifecycleNotificationRepository` from
//      the router (default-null preserves V1 demo path).
//   2. Pass `onNotifyMeRequested: _handleNotifyMe` to the
//      `VendorConnectionsWidget(...)` call below.
//   3. Implement `_handleNotifyMe(vendorId, vendorName, lifecycle)`
//      to call `showVendorLifecycleNotifyMeDialog(context,
//      operatorId: session.operatorId, vendorId: vendorId,
//      vendorDisplayName: vendorName, lifecycle: lifecycle,
//      defaultEmail: session.email, repository: repository!)`.
//   4. On `VendorLifecycleNotificationOutcome.inserted` /
//      `alreadySubscribed`, render row chrome reading
//      "We'll email ${result.email} when ${vendorName} is ready"
//      with a `[Cancel]` button that calls
//      `repository.cancelNotification(...)`.
//
// The repository class itself is a Phase 8.0.lifecycle follow-up;
// until it lands the abstract seam in
// `vendor_lifecycle_notify_me_dialog.dart` is the dependency
// target.

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_url_launcher.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_widget.dart';
import '../../theme/app_theme.dart';

/// Roles permitted to configure inbound vendor connections from the
/// operator-web console. Mirrors the `integrations.configure` row
/// in `docs/contracts/auth_permission_key_catalog.md`: granted to
/// `operator_admin` and `operator_owner`; denied to
/// `location_manager` (read-only role, no integration mutate
/// access).
const Set<String> kOperatorWebVendorConnectionsAdmittedRoles = <String>{
  'operator_owner',
  'operator_admin',
};

/// Operator Web Console Vendor Connections screen. Lives behind
/// the `kOperatorWebNavVendorConnections` side-nav item.
class VendorConnectionsScreen extends StatelessWidget {
  const VendorConnectionsScreen({
    super.key,
    required this.session,
    required this.locationId,
    this.gateway,
  });

  /// Authenticated operator-web session — drives operator_id, the
  /// permission gate, and the location label fallback.
  final OperatorWebSession session;

  /// Location id from the URL (`/locations/:location_id/...`).
  /// Defaults to the operator's primary location id when the route
  /// has no explicit param.
  final String locationId;

  /// Optional gateway override. Production wires the HTTP gateway
  /// at the Cloud Run entry point; demo + widget tests pass an
  /// in-memory gateway with seeded vendors.
  final VendorConnectionsGateway? gateway;

  /// True iff the session has `integrations.configure` (i.e. role
  /// is `operator_admin` or `operator_owner`).
  bool get _canConfigureIntegrations =>
      session.roles.any(kOperatorWebVendorConnectionsAdmittedRoles.contains) ||
      session.permissions.contains('integrations.configure');

  @override
  Widget build(BuildContext context) {
    if (!_canConfigureIntegrations) {
      return _ForbiddenSurface(
        key: const Key('operator_web_vendor_connections_forbidden'),
      );
    }
    if (locationId.trim().isEmpty) {
      return _NoLocationSurface(
        key: const Key('operator_web_vendor_connections_no_location'),
      );
    }
    final locationLabel = locationId == session.primaryLocationId
        ? '${session.primaryLocationName} (primary location)'
        : 'location $locationId';
    return SingleChildScrollView(
      key: const Key('operator_web_vendor_connections_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.cable_outlined,
                size: 22,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Vendor connections',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Configuring connections for $locationLabel.',
            key: const Key('operator_web_vendor_connections_subtitle'),
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),
          Container(
            key: const Key('operator_web_vendor_connections_widget_host'),
            decoration: BoxDecoration(
              color: AppColors.backgroundSurface,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: VendorConnectionsWidget(
              operatorId: session.operatorId,
              locationId: locationId,
              gateway: gateway,
              onConnectFlowStarted: gateway == null
                  ? null
                  : (flow) => openOperatorWebRedirect(flow.redirectUrl),
            ),
          ),
        ],
      ),
    );
  }
}

/// Friendly 403 surface shown when a `location_manager` session
/// hits the Vendor connections route. Reads as training: explains
/// who manages connections and what the operator should do next.
class _ForbiddenSurface extends StatelessWidget {
  const _ForbiddenSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 20,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Vendor connections are admin-managed',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Vendor connections are managed by your operator '
                'admin or owner; ask them to set up integrations '
                'for this location.',
                key: const Key(
                  'operator_web_vendor_connections_forbidden_body',
                ),
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: AppColors.cardGlow,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Why you are seeing this',
                      style: AppTextStyles.mono11(color: AppColors.sunsetDark),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Connecting Forge & Flow to your POS, '
                      'reservations, and scheduling systems writes '
                      'authentication tokens for the entire '
                      'business. Only operator admins and owners '
                      'can do that. Location managers can keep '
                      'reading dashboards and shift views in the '
                      'mobile app; most day-to-day actions live '
                      'there.',
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Honest "no location selected" surface shown when the route reaches
/// the screen without a location id (the operator-web shell normally
/// seeds it from `session.primaryLocationId`, but the route can
/// surface here with an empty scope before the location resolves or
/// when a deep link omits the location segment). Reads as training:
/// explains what the screen does and how to land on a real location.
class _NoLocationSurface extends StatelessWidget {
  const _NoLocationSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.place_outlined,
                    size: 20,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No location selected',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Vendor connections are configured per location, so '
                'this screen needs to know which location you are '
                'setting up. Pick a location from the side nav, then '
                'open Vendor connections again.',
                key: const Key(
                  'operator_web_vendor_connections_no_location_body',
                ),
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
