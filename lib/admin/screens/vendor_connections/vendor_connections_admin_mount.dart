// Phase 8.0 - F&F Ops Console host shell for the shared Vendor
// Connections widget tree.
//
// Hosts `VendorConnectionsWidget` (lib/integrations/ui/vendor_connections/)
// inside the F&F Operations Console route tree. Reads
// (operator_id, location_id) from constructor args resolved by the
// existing operator picker; the Operator Web Console mount lands
// later in 11W.8.

import 'package:flutter/material.dart';

import '../../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../../integrations/ui/vendor_connections/vendor_connections_widget.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/admin_responsive_layout.dart';

/// F&F Ops Console host shell for the shared Vendor Connections
/// widget tree.
class VendorConnectionsAdminMount extends StatelessWidget {
  const VendorConnectionsAdminMount({
    super.key,
    required this.operatorId,
    required this.locationId,
    required this.locationName,
    this.gateway,
    this.canMutate = true,
  });

  final String operatorId;
  final String locationId;
  final String locationName;

  /// Production wires the HTTP gateway above the auth gate; demo +
  /// widget tests inject a seeded in-memory gateway.
  final VendorConnectionsGateway? gateway;

  /// `false` for `ff_support` (read-only). Hides connect / test /
  /// disconnect buttons but still renders status.
  final bool canMutate;

  @override
  Widget build(BuildContext context) {
    final resolvedGateway = gateway;
    return Scaffold(
      key: const Key('admin_vendor_connections_screen'),
      appBar: AppBar(title: const Text('Vendor integrations')),
      body: resolvedGateway == null
          ? _VendorLifecycleUnavailablePanel(locationName: locationName)
          : VendorConnectionsWidget(
              operatorId: operatorId,
              locationId: locationId,
              locationNameOverride: locationName,
              gateway: resolvedGateway,
              canMutate: canMutate,
            ),
    );
  }
}

class _VendorLifecycleUnavailablePanel extends StatelessWidget {
  const _VendorLifecycleUnavailablePanel({required this.locationName});

  final String locationName;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.backgroundDeep,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AdminPageHeader(
                  title: 'Vendor integrations',
                  subtitle:
                      'Live provider summary is available in Connected services. Per-location lifecycle actions stay disabled here until the proxy route has production bindings.',
                ),
                const SizedBox(height: 14),
                AdminCard(
                  key: const Key('admin_vendor_connections_not_wired'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Icon(
                            Icons.lock_outline,
                            size: 20,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Lifecycle actions are not live for $locationName',
                                  style: AppTextStyles.sectionTitle(
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Connect, test, disconnect, and sync-log actions are not exposed from this admin route in preview. This page is intentionally read-only rather than showing demo vendor data.',
                                  style: AppTextStyles.body13(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const AdminDetailRow(
                        label: 'Current admin status',
                        value: 'Not routed',
                      ),
                      const AdminDetailRow(
                        label: 'Safe live view',
                        value: 'Connected services',
                      ),
                      const AdminDetailRow(
                        label: 'Mutation state',
                        value: 'Disabled until backend bindings exist',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
