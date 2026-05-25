// Admin Console seeded vendor-connections demo gateway.
//
// This is the Admin-side source swap for local demo/share-preview builds.
// It reuses DemoVendorIntegrationStateFixture so Admin, Operator Web, and
// Mobile tell the same per-location vendor-state story.

import '../../dev/demo_vendor_integration_state_fixture.dart';
import '../../integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'demo_members_admin_gateway.dart';

/// Demo Vendor Connections fixture for the Admin Console.
class AdminDemoVendorConnectionsFixture {
  const AdminDemoVendorConnectionsFixture._();

  static const Map<String, _AdminDemoLocationRef> _locations =
      <String, _AdminDemoLocationRef>{
        kDemoDinerLocationToronto: _AdminDemoLocationRef(
          operatorId: kDemoDinerOperatorId,
          name: 'Toronto Yorkville',
        ),
        kDemoDinerLocationVancouver: _AdminDemoLocationRef(
          operatorId: kDemoDinerOperatorId,
          name: 'Vancouver Robson',
        ),
        kDemoSunsetLocationBrooklyn: _AdminDemoLocationRef(
          operatorId: kDemoSunsetOperatorId,
          name: 'Brooklyn Williamsburg',
        ),
      };

  /// Seed map for `InMemoryVendorConnectionsGateway`, keyed
  /// `operatorId/locationId`, covering every Admin demo location.
  static Map<String, VendorConnectionsBundle> seed() {
    return <String, VendorConnectionsBundle>{
      for (final entry in _locations.entries)
        '${entry.value.operatorId}/${entry.key}':
            DemoVendorIntegrationStateFixture.vendorConnectionsBundle(
              operatorId: entry.value.operatorId,
              locationId: entry.key,
              locationName: entry.value.name,
            ),
    };
  }

  /// A fresh seeded gateway for Admin demo/share-preview entrypoints.
  static InMemoryVendorConnectionsGateway gateway() {
    return InMemoryVendorConnectionsGateway(seed: seed());
  }
}

class _AdminDemoLocationRef {
  const _AdminDemoLocationRef({required this.operatorId, required this.name});

  final String operatorId;
  final String name;
}
