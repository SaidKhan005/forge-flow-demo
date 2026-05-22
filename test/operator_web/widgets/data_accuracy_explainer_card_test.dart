import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/operator_web/widgets/data_accuracy_explainer_card.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  VendorConnectionRow row({
    required String vendorId,
    required String displayName,
    required VendorCategory category,
  }) => VendorConnectionRow(
    connectionId: '$vendorId-conn',
    vendorId: vendorId,
    displayName: displayName,
    category: category,
    status: VendorConnectionStatus.connected,
    metadata: const <String, Object?>{},
  );

  VendorConnectionsBundle bundle({
    VendorConnectionRow? pos,
    VendorConnectionRow? labor,
    VendorConnectionRow? reservation,
  }) => VendorConnectionsBundle(
    operatorId: 'op-1',
    locationId: 'loc-1',
    locationName: '95 Water Street',
    posConnection: pos,
    laborConnection: labor,
    reservationConnection: reservation,
    demoFlags: const <VendorCategory, bool>{},
  );

  const customPeriods = <ServicePeriodDefinition>[
    ServicePeriodDefinition(
      id: 'breakfast_service',
      label: 'Breakfast service',
      shortLabel: 'B',
      sortOrder: 1,
      startLocalTime: '08:00',
      endLocalTime: '11:00',
      rollsPastMidnight: false,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    ),
    ServicePeriodDefinition(
      id: 'supper',
      label: 'Supper',
      shortLabel: 'S',
      sortOrder: 2,
      startLocalTime: '17:00',
      endLocalTime: '21:00',
      rollsPastMidnight: false,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    ),
  ];

  group('DataAccuracyExplainerCard', () {
    testWidgets('renders a visual map from the connected vendors', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          DataAccuracyExplainerCard(
            locationLabel: '95 Water Street',
            bundle: bundle(
              pos: row(
                vendorId: 'square',
                displayName: 'Square',
                category: VendorCategory.pos,
              ),
              labor: row(
                vendorId: 'quickbooks_time',
                displayName: 'QuickBooks Time',
                category: VendorCategory.labor,
              ),
              reservation: row(
                vendorId: 'opentable',
                displayName: 'OpenTable',
                category: VendorCategory.reservation,
              ),
            ),
            dataFreshnessApplies: true,
            servicePeriods: customPeriods,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('data_accuracy_explainer_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('data_accuracy_explainer_labor')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('data_accuracy_explainer_covers')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('data_accuracy_explainer_freshness')),
        findsOneWidget,
      );
      expect(find.text('QuickBooks Time'), findsWidgets);
      expect(find.text('Square'), findsWidgets);
      expect(find.text('OpenTable'), findsWidgets);
      expect(
        find.textContaining('Square does not supply POS guest counts'),
        findsOneWidget,
      );
      expect(find.textContaining('Breakfast service'), findsOneWidget);
      expect(
        find.textContaining('checks QuickBooks Time for new data'),
        findsOneWidget,
      );
    });

    testWidgets('keeps real-time integrations compact on freshness', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          DataAccuracyExplainerCard(
            locationLabel: '95 Water Street',
            bundle: bundle(
              pos: row(
                vendorId: 'toast',
                displayName: 'Toast',
                category: VendorCategory.pos,
              ),
              labor: row(
                vendorId: 'seven_shifts',
                displayName: '7shifts',
                category: VendorCategory.labor,
              ),
            ),
            dataFreshnessApplies: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('receives updates when vendors push them'),
        findsOneWidget,
      );
      expect(find.text('Toast'), findsWidgets);
      expect(find.text('7shifts'), findsWidgets);
    });

    testWidgets('keeps the no-vendor map compact', (tester) async {
      await tester.pumpWidget(
        wrap(
          DataAccuracyExplainerCard(
            locationLabel: '95 Water Street',
            bundle: bundle(),
            dataFreshnessApplies: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('data_accuracy_no_vendors_notice')),
        findsNothing,
      );
      expect(
        find.textContaining('receives updates when vendors push them'),
        findsOneWidget,
      );
      expect(
        find.textContaining('turns labor hours into labor dollars'),
        findsOneWidget,
      );
      expect(
        find.textContaining('guest-count source for each service period'),
        findsOneWidget,
      );
    });
  });
}
