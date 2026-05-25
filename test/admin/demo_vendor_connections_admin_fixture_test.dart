import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_vendor_connections_admin_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';

void main() {
  group('AdminDemoVendorConnectionsFixture', () {
    test('seeds every admin demo location with shared demo-state fixture', () {
      final seed = AdminDemoVendorConnectionsFixture.seed();

      expect(seed.keys.toSet(), <String>{
        '$kDemoDinerOperatorId/$kDemoDinerLocationToronto',
        '$kDemoDinerOperatorId/$kDemoDinerLocationVancouver',
        '$kDemoSunsetOperatorId/$kDemoSunsetLocationBrooklyn',
      });

      final yorkville =
          seed['$kDemoDinerOperatorId/$kDemoDinerLocationToronto']!;
      expect(yorkville.locationName, 'Toronto Yorkville');
      expect(yorkville.posConnection?.displayName, 'Toast');
      expect(yorkville.laborConnection?.displayName, 'Humanity');
      expect(yorkville.reservationConnection?.displayName, 'OpenTable');
      expect(
        yorkville.reservationConnection?.status,
        VendorConnectionStatus.error,
      );
      expect(yorkville.demoFlags[VendorCategory.pos], isTrue);

      final vancouver =
          seed['$kDemoDinerOperatorId/$kDemoDinerLocationVancouver']!;
      expect(vancouver.locationName, 'Vancouver Robson');
      expect(vancouver.posConnection?.status, VendorConnectionStatus.connected);
      expect(
        vancouver.laborConnection?.status,
        VendorConnectionStatus.connected,
      );
      expect(
        vancouver.reservationConnection?.status,
        VendorConnectionStatus.connected,
      );
      expect(vancouver.demoFlags.values.every((flag) => !flag), isTrue);

      final brooklyn =
          seed['$kDemoSunsetOperatorId/$kDemoSunsetLocationBrooklyn']!;
      expect(brooklyn.locationName, 'Brooklyn Williamsburg');
      expect(brooklyn.posConnection, isNull);
      expect(brooklyn.laborConnection, isNull);
      expect(brooklyn.reservationConnection, isNull);
      expect(brooklyn.demoFlags.values.every((flag) => flag), isTrue);
    });

    test('gateway loads the seeded admin location bundle', () async {
      final gateway = AdminDemoVendorConnectionsFixture.gateway();

      final bundle = await gateway.loadBundle(
        operatorId: kDemoDinerOperatorId,
        locationId: kDemoDinerLocationToronto,
      );

      expect(bundle.locationName, 'Toronto Yorkville');
      expect(bundle.posConnection, isNotNull);
      expect(bundle.laborConnection, isNotNull);
      expect(
        bundle.reservationConnection?.status,
        VendorConnectionStatus.error,
      );
    });
  });
}
