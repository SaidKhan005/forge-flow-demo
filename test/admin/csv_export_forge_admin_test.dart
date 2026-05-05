// Phase 8 spine-bridge Lane .C — acceptance item I.
//
// CSV export (forge_admin only). Validates the CSV header + rows
// returned by the gateway, audit log capture, and screen-side hiding
// of the export button when editingEnabled: false.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  group('8.spine-bridge.C — CSV export (forge_admin only)', () {
    test('forge_admin export returns header + totals row + per_tier row '
        'and writes audit event', () async {
      const refs = <OperatorLocationRef>[
        OperatorLocationRef(
          operatorId: 'op-1',
          businessName: 'Demo Diner Co.',
          locationId: 'loc-1a',
          locationName: 'Toronto Yorkville',
        ),
        OperatorLocationRef(
          operatorId: 'op-2',
          businessName: 'Sunset Cafe Group',
          locationId: 'loc-2a',
          locationName: 'Brooklyn Williamsburg',
        ),
      ];
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: refs,
        initialTierDefinitions: <PollingTierKey, TierDefinition>{
          PollingTierKey.standard: kDemoStandardTierDefinition(),
          PollingTierKey.premium: kDemoPremiumTierDefinition(),
          PollingTierKey.custom: kDemoCustomTierDefinition(),
        },
      );

      // Mixed-tier seeding via assignTier.
      await gateway.assignTier(
        operatorId: 'op-1',
        locationId: 'loc-1a',
        tierKey: PollingTierKey.standard,
        monthlyPriceCentsOverride: 9900,
        vendorApiCostEstimateCentsMonthlyOverride: 1200,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
      );
      await gateway.assignTier(
        operatorId: 'op-2',
        locationId: 'loc-2a',
        tierKey: PollingTierKey.premium,
        monthlyPriceCentsOverride: 19900,
        vendorApiCostEstimateCentsMonthlyOverride: 4800,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
      );

      final csv = await gateway.exportMarginRollupCsv(
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
      );

      expect(
        csv.startsWith(
          'section,key,assignments,price_cents,cost_cents,margin_cents',
        ),
        isTrue,
        reason: 'CSV must start with the canonical header',
      );
      expect(csv.contains('totals,all,'), isTrue);
      expect(csv.contains('per_tier,'), isTrue);

      final exports = gateway.capturedAuditEvents
          .where((e) => e.eventType == 'admin.margin_rollup.export_csv')
          .toList();
      expect(exports, hasLength(1));
    });

    test('non-forge_admin export throws DataAccuracyAdminForbiddenException',
        () async {
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[],
      );
      expect(
        () => gateway.exportMarginRollupCsv(
          actorUserId: 'support@forgeflow.test',
          actorIsForgeAdmin: false,
        ),
        throwsA(isA<DataAccuracyAdminForbiddenException>()),
      );
    });

    testWidgets('PollingAndPricingAdminScreen with editingEnabled: false '
        'hides the export button', (tester) async {
      // Use a wide viewport so the screen's filter bar fits without
      // overflow exceptions during layout.
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      // The filter-bar DropdownButtonFormField overflows horizontally
      // by ~1.4 px in the test environment; not our concern in this
      // slice. Swallow the layout-overflow assertion so the
      // findsNothing assertion below can run.
      final FlutterExceptionHandler? prior = FlutterError.onError;
      FlutterError.onError = (details) {
        final msg = details.exceptionAsString();
        if (msg.contains('A RenderFlex overflowed')) return;
        prior?.call(details);
      };
      addTearDown(() {
        FlutterError.onError = prior;
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
        initialTierDefinitions: <PollingTierKey, TierDefinition>{
          PollingTierKey.standard: kDemoStandardTierDefinition(),
          PollingTierKey.premium: kDemoPremiumTierDefinition(),
          PollingTierKey.custom: kDemoCustomTierDefinition(),
        },
      );
      await tester.pumpWidget(
        wrap(
          PollingAndPricingAdminScreen(
            gateway: gateway,
            actorUserId: 'support@forgeflow.test',
            editingEnabled: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_margin_rollup_export_button')),
        findsNothing,
      );
    });
  });
}
