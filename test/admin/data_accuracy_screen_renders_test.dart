// Phase 8 spine-bridge Lane .C — acceptance item A.
//
// Tab 1 (Data Accuracy) screen renders multi-operator multi-location
// rows from the in-memory gateway after the initial async refresh.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  group('8.spine-bridge.C — Tab 1 data accuracy table renders multi-operator '
      'multi-location', () {
    testWidgets('renders all 3 seeded operator-locations', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[
          OperatorLocationRef(
            operatorId: 'op-1',
            businessName: 'Demo Diner Co.',
            locationId: 'loc-1a',
            locationName: 'Toronto Yorkville',
          ),
          OperatorLocationRef(
            operatorId: 'op-1',
            businessName: 'Demo Diner Co.',
            locationId: 'loc-1b',
            locationName: 'Vancouver Robson',
          ),
          OperatorLocationRef(
            operatorId: 'op-2',
            businessName: 'Sunset Cafe Group',
            locationId: 'loc-2a',
            locationName: 'Brooklyn Williamsburg',
          ),
        ],
      );

      await tester.pumpWidget(
        wrap(
          PerLocationDataAccuracyScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_data_accuracy_table')),
        findsOneWidget,
      );

      // Two operators (Demo Diner Co. appears twice, but we just assert
      // presence — `findsWidgets` matches >= 1).
      expect(find.text('Demo Diner Co.'), findsWidgets);
      expect(find.text('Sunset Cafe Group'), findsOneWidget);

      // Three distinct locations.
      expect(find.text('Toronto Yorkville'), findsOneWidget);
      expect(find.text('Vancouver Robson'), findsOneWidget);
      expect(find.text('Brooklyn Williamsburg'), findsOneWidget);
    });

    testWidgets('renders configured and keyed service-period rows together', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[
          OperatorLocationRef(
            operatorId: 'op-1',
            businessName: 'Demo Diner Co.',
            locationId: 'loc-1a',
            locationName: 'Toronto Yorkville',
          ),
        ],
      );
      await gateway.overrideDataAccuracyServicePeriod(
        operatorId: 'op-1',
        locationId: 'loc-1a',
        servicePeriodKey: 'breakfast',
        coversSource: ServicePeriodCoversSource.manual,
        wageSource: ServicePeriodWageSource.targetSubstitution,
        effectiveAtBusinessDateIso: '2026-06-01',
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'Breakfast goes manual for launch week',
      );

      await tester.pumpWidget(
        wrap(
          PerLocationDataAccuracyScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Breakfast'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);
      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('Dinner'), findsOneWidget);
      expect(find.text('Late Night'), findsOneWidget);
      expect(find.text('Vendor default'), findsWidgets);

      await tester.tap(
        find.byKey(const Key('admin_data_accuracy_vendor_source_filter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Covers from vendor').last);
      await tester.pumpAndSettle();

      expect(find.text('Demo Diner Co.'), findsOneWidget);
      expect(find.text('Toronto Yorkville'), findsOneWidget);
      expect(find.text('No locations match this view.'), findsNothing);
    });
  });
}
