// Phase 8.0 — F&F Ops Console host shell for the shared Vendor
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
    return Scaffold(
      key: const Key('admin_vendor_connections_screen'),
      appBar: AppBar(title: const Text('Vendor integrations')),
      body: VendorConnectionsWidget(
        operatorId: operatorId,
        locationId: locationId,
        locationNameOverride: locationName,
        gateway: gateway,
        canMutate: canMutate,
      ),
    );
  }
}
